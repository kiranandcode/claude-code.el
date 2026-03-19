;;; claude-code-emacs-tools.el --- Emacs-side helpers for Claude tools -*- lexical-binding: t -*-

;;; Commentary:
;; Provides Emacs Lisp functions that the Python backend's custom MCP tools
;; (EvalEmacs, EmacsGetMessages, EmacsGetBuffer, etc.) invoke via
;; `emacsclient --eval'.
;;
;; These functions return structured, human-readable strings that Claude
;; can consume as tool results.  They are intentionally self-contained so
;; they survive being called from the emacsclient RPC channel without
;; depending on the full claude-code session state.
;;
;; All public symbols use the prefix `claude-code-tools-'.

;;; Code:

(require 'cl-lib)

;;;; Elisp evaluation with feedback

(defun claude-code-tools-eval (code-string)
  "Evaluate CODE-STRING as Emacs Lisp and return a structured result string.
Unlike a bare `eval-expression', this function:
  - Reports unbalanced parentheses before attempting evaluation
  - Captures all error conditions and formats them clearly
  - Truncates oversized output to avoid flooding the tool result

Returns a string beginning with \"ok: \" on success or \"error: \" on failure."
  (let ((paren-error (claude-code-tools--check-parens code-string)))
    (if paren-error
        (format "error: syntax — %s\n\ncode:\n%s" paren-error code-string)
      (condition-case err
          (let* ((form (car (read-from-string code-string)))
                 (result (eval form t))
                 (printed (claude-code-tools--safe-print result)))
            (format "ok: %s" printed))
        (error
         (format "error: %s\n\ncaused by evaluating:\n%s"
                 (error-message-string err)
                 code-string))))))

(defun claude-code-tools--check-parens (code)
  "Return an error string if CODE has unbalanced parentheses, else nil.
Handles strings, characters, and line comments correctly."
  (let ((depth 0)
        (pos 0)
        (len (length code)))
    (catch 'done
      (while (< pos len)
        (let ((ch (aref code pos)))
          (cond
           ;; Line comment: skip to end of line
           ((eq ch ?\;)
            (while (and (< pos len) (not (eq (aref code pos) ?\n)))
              (cl-incf pos)))
           ;; String literal: skip until closing unescaped double-quote
           ((eq ch ?\")
            (cl-incf pos)
            (let ((closed nil))
              (while (and (< pos len) (not closed))
                (let ((sc (aref code pos)))
                  (cond
                   ((eq sc ?\\) (cl-incf pos 2)) ; skip escape + next char
                   ((eq sc ?\") (setq closed t) (cl-incf pos))
                   (t (cl-incf pos)))))
              (unless closed
                (throw 'done "unclosed string literal"))))
           ;; Character literal: skip next char
           ((and (eq ch ?\\) (< (1+ pos) len) )
            (cl-incf pos 2))
           ((eq ch ?\()
            (cl-incf depth)
            (cl-incf pos))
           ((eq ch ?\))
            (cl-decf depth)
            (when (< depth 0)
              (throw 'done
                     (format "extra closing ')' at position %d" pos)))
            (cl-incf pos))
           (t (cl-incf pos)))))
      (when (> depth 0)
        (throw 'done
               (format "%d unclosed '(' — add %d more ')'" depth depth)))
      nil)))

(defun claude-code-tools--safe-print (value &optional max-chars)
  "Print VALUE to a string, truncating if longer than MAX-CHARS (default 4000)."
  (let* ((max (or max-chars 4000))
         (s (condition-case _
                (with-output-to-string (prin1 value))
              (error (format "%S" value)))))
    (if (> (length s) max)
        (concat (substring s 0 max) "\n…[truncated]")
      s)))

;;;; Messages log

(defun claude-code-tools-get-messages (&optional n-chars)
  "Return the last N-CHARS characters from the *Messages* buffer.
Defaults to 3000 characters.  Returns a plain string."
  (let ((n (or n-chars 3000)))
    (if (get-buffer "*Messages*")
        (with-current-buffer "*Messages*"
          (let* ((end (point-max))
                 (start (max (point-min) (- end n))))
            (buffer-substring-no-properties start end)))
      "(no *Messages* buffer)")))

;;;; Debug info (backtrace + messages)

(defun claude-code-tools-get-debug-info ()
  "Return a combined debug snapshot: *Backtrace* (if present) + *Messages* tail.
Useful for diagnosing errors after a failed operation."
  (let ((backtrace
         (if (get-buffer "*Backtrace*")
             (with-current-buffer "*Backtrace*"
               (buffer-substring-no-properties (point-min)
                                               (min (point-max) (+ (point-min) 3000))))
           nil))
        (messages (claude-code-tools-get-messages 2000)))
    (concat
     (if backtrace
         (format "=== *Backtrace* ===\n%s\n\n" backtrace)
       "=== *Backtrace* === (not present)\n\n")
     "=== *Messages* (last 2000 chars) ===\n"
     messages)))

;;;; Buffer inspection

(defun claude-code-tools-get-buffer (buffer-name &optional with-line-numbers)
  "Return the contents of the buffer named BUFFER-NAME as a string.
If WITH-LINE-NUMBERS is non-nil, prefix each line with its line number.
Returns an error string if the buffer does not exist."
  (let ((buf (get-buffer buffer-name)))
    (if (not buf)
        (format "error: no buffer named %S" buffer-name)
      (with-current-buffer buf
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (if with-line-numbers
              (let ((lines (split-string text "\n"))
                    (n 1)
                    result)
                (dolist (line lines)
                  (push (format "%4d  %s" n line) result)
                  (cl-incf n))
                (mapconcat #'identity (nreverse result) "\n"))
            text))))))

(defun claude-code-tools-get-buffer-region (buffer-name start-line end-line)
  "Return lines START-LINE through END-LINE (1-indexed) from BUFFER-NAME.
Includes line numbers in the output.  Returns an error string if the
buffer does not exist or the range is invalid."
  (let ((buf (get-buffer buffer-name)))
    (if (not buf)
        (format "error: no buffer named %S" buffer-name)
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-min))
          (let ((lines (split-string (buffer-substring-no-properties
                                      (point-min) (point-max))
                                     "\n"))
                result)
            (let ((total (length lines)))
              (when (> end-line total) (setq end-line total))
              (when (< start-line 1) (setq start-line 1))
              (if (> start-line end-line)
                  (format "error: start-line %d > end-line %d" start-line end-line)
                (cl-loop for line in (nthcdr (1- start-line) lines)
                         for n from start-line to end-line
                         do (push (format "%4d  %s" n line) result))
                (mapconcat #'identity (nreverse result) "\n")))))))))

(defun claude-code-tools-list-buffers ()
  "Return a formatted string listing all live buffers with key information.
Each line: <buffer-name>  <mode>  <file-or-dir>"
  (let (lines)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (let* ((name (buffer-name))
               (mode (symbol-name major-mode))
               (file (or (buffer-file-name) default-directory "—"))
               (modified (if (and (buffer-file-name) (buffer-modified-p)) " *" "")))
          (push (format "%-40s  %-24s  %s%s" name mode file modified) lines))))
    (concat
     (format "%-40s  %-24s  %s\n" "BUFFER" "MODE" "FILE/DIR")
     (make-string 80 ?─) "\n"
     (mapconcat #'identity (nreverse lines) "\n"))))

;;;; Cursor navigation

(defun claude-code-tools-switch-buffer (buffer-name)
  "Switch to the buffer named BUFFER-NAME and return a status string.
If the buffer is visible in a window, selects that window.  Otherwise
switches the selected window's buffer."
  (let ((buf (get-buffer buffer-name)))
    (if (not buf)
        (format "error: no buffer named %S" buffer-name)
      (let ((win (get-buffer-window buf)))
        (if win
            (progn
              (select-window win)
              (format "ok: selected window showing %S" buffer-name))
          (switch-to-buffer buf)
          (format "ok: switched to %S" buffer-name))))))

(defun claude-code-tools-get-point-info (&optional buffer-name)
  "Return a string describing point position in BUFFER-NAME (or current buffer).
Includes: buffer name, line number, column, character at point, and
a 3-line context snippet centered on point."
  (with-current-buffer (or (and buffer-name (get-buffer buffer-name))
                            (current-buffer))
    (let* ((pt   (point))
           (line (line-number-at-pos pt))
           (col  (current-column))
           (ch   (if (eobp) "EOF" (string (char-after pt))))
           ;; context: current line ± 1
           (ctx-start (save-excursion
                        (goto-char pt)
                        (forward-line -1)
                        (line-beginning-position)))
           (ctx-end   (save-excursion
                        (goto-char pt)
                        (forward-line 2)
                        (line-end-position)))
           (context (buffer-substring-no-properties ctx-start ctx-end)))
      (format "buffer: %s\nline: %d  col: %d  char: %S\ncontext:\n%s"
              (buffer-name) line col ch context))))

(defun claude-code-tools-search-forward (pattern &optional buffer-name no-error)
  "Search forward for PATTERN in BUFFER-NAME (default: current buffer).
Moves point to end of the first match after the current position.
Returns a description of the match location, or an error string.
When NO-ERROR is non-nil, returns a \"not found\" message instead of error."
  (with-current-buffer (or (and buffer-name (get-buffer buffer-name))
                            (current-buffer))
    (condition-case err
        (if (re-search-forward pattern nil (if no-error t nil))
            (let ((line (line-number-at-pos (match-beginning 0)))
                  (col  (save-excursion
                          (goto-char (match-beginning 0))
                          (current-column)))
                  (match (match-string 0)))
              (format "ok: found %S at line %d col %d (moved point there)"
                      match line col))
          (format "not found: %S" pattern))
      (error
       (format "error: %s" (error-message-string err))))))

(defun claude-code-tools-search-backward (pattern &optional buffer-name no-error)
  "Search backward for PATTERN in BUFFER-NAME (default: current buffer).
Moves point to the beginning of the first match before the current position.
Returns a description of the match location, or an error string.
When NO-ERROR is non-nil, returns a \"not found\" message instead of error."
  (with-current-buffer (or (and buffer-name (get-buffer buffer-name))
                            (current-buffer))
    (condition-case err
        (if (re-search-backward pattern nil (if no-error t nil))
            (let ((line (line-number-at-pos (match-beginning 0)))
                  (col  (save-excursion
                          (goto-char (match-beginning 0))
                          (current-column)))
                  (match (match-string 0)))
              (format "ok: found %S at line %d col %d (moved point there)"
                      match line col))
          (format "not found: %S" pattern))
      (error
       (format "error: %s" (error-message-string err))))))

(defun claude-code-tools-goto-line (line-number &optional buffer-name)
  "Move point to the beginning of LINE-NUMBER in BUFFER-NAME (or current buffer).
Returns a status string with the new position context."
  (with-current-buffer (or (and buffer-name (get-buffer buffer-name))
                            (current-buffer))
    (goto-char (point-min))
    (forward-line (1- line-number))
    (claude-code-tools-get-point-info buffer-name)))

;;;; Frame rendering (thin wrapper around claude-code-frame-render)

(defun claude-code-tools-render-frame ()
  "Render the current Emacs frame and return the ANSI-decorated string.
Requires `claude-code-frame-render' to be loaded."
  (if (fboundp 'claude-code-frame-render)
      (claude-code-frame-render)
    "error: claude-code-frame-render not loaded"))

(provide 'claude-code-emacs-tools)
;;; claude-code-emacs-tools.el ends here
