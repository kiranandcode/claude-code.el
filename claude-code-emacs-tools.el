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

(defun claude-code-tools--sanitize-string (str)
  "Remove control characters from STR that would break JSON encoding.
Keeps tab (\\t), newline (\\n), and carriage return (\\r) but strips all
other C0 control characters (U+0000–U+001F) and DEL (U+007F)."
  (replace-regexp-in-string "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]" "" str))

(defun claude-code-tools-get-messages (&optional n-chars)
  "Return the last N-CHARS characters from the *Messages* buffer.
Defaults to 3000 characters.  Returns a plain string."
  (let ((n (or n-chars 3000)))
    (if (get-buffer "*Messages*")
        (with-current-buffer "*Messages*"
          (let* ((end (point-max))
                 (start (max (point-min) (- end n))))
            (claude-code-tools--sanitize-string
             (buffer-substring-no-properties start end))))
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
        (let ((text (claude-code-tools--sanitize-string
                     (buffer-substring-no-properties (point-min) (point-max)))))
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
          (let ((lines (split-string (claude-code-tools--sanitize-string
                                      (buffer-substring-no-properties
                                       (point-min) (point-max)))
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

;;;; ─────────────────────────────────────────────────────────────────────────
;;;; Persistent MCP socket server
;;;;
;;;; Replaces the per-call `emacsclient' subprocess with a Unix socket that
;;;; the Python backend connects to once and reuses for every MCP tool call.
;;;; Eliminates fork/exec overhead and avoids stale-socket-file issues.
;;;;
;;;; Wire format: line-delimited JSON.
;;;;   request:  {"id": "<str>", "elisp": "<form>"}\n
;;;;   response: {"id": "<str>", "ok": true, "result": <any>}\n
;;;;             {"id": "<str>", "ok": false, "error": "<msg>"}\n
;;;;
;;;; The server is single-shared per Emacs instance.  Multiple Python
;;;; backends (one per Claude session buffer) all connect to the same socket.
;;;; ─────────────────────────────────────────────────────────────────────────

(require 'json)

(defvar claude-code-tools--mcp-socket-process nil
  "The listening server process, or nil if not running.")

(defvar claude-code-tools--mcp-socket-path nil
  "Filesystem path of the Unix socket the server is listening on.")

(defun claude-code-tools--mcp-socket-default-path ()
  "Return the default socket path for this Emacs instance."
  (expand-file-name (format "claude-code-mcp-%d.sock" (emacs-pid))
                    temporary-file-directory))

(defun claude-code-tools-mcp-server-start ()
  "Start the MCP Unix socket server if not already running.
Returns the socket path.  Idempotent: a no-op if the server is alive."
  (if (and claude-code-tools--mcp-socket-process
           (process-live-p claude-code-tools--mcp-socket-process))
      claude-code-tools--mcp-socket-path
    ;; Clean up any stale socket file from a previous (crashed) Emacs.
    (let ((path (claude-code-tools--mcp-socket-default-path)))
      (when (file-exists-p path)
        (ignore-errors (delete-file path)))
      (setq claude-code-tools--mcp-socket-path path
            claude-code-tools--mcp-socket-process
            (make-network-process
             :name "claude-code-mcp-server"
             :family 'local
             :server t
             :service path
             :coding 'utf-8-unix
             :filter #'claude-code-tools--mcp-socket-filter
             :sentinel #'claude-code-tools--mcp-socket-sentinel
             :noquery t))
      path)))

(defun claude-code-tools-mcp-server-stop ()
  "Stop the MCP socket server and remove the socket file."
  (interactive)
  (when (and claude-code-tools--mcp-socket-process
             (process-live-p claude-code-tools--mcp-socket-process))
    (delete-process claude-code-tools--mcp-socket-process))
  (setq claude-code-tools--mcp-socket-process nil)
  (when (and claude-code-tools--mcp-socket-path
             (file-exists-p claude-code-tools--mcp-socket-path))
    (ignore-errors (delete-file claude-code-tools--mcp-socket-path)))
  (setq claude-code-tools--mcp-socket-path nil))

(defun claude-code-tools--mcp-socket-sentinel (proc event)
  "Handle EVENT for the MCP server PROC.
Logs disconnects and cleans up partial-line buffers."
  (cond
   ((string-match-p "open" event)
    nil)  ; new client connection
   ((string-match-p "deleted" event)
    nil)  ; orderly client disconnect
   (t
    (process-put proc :claude-mcp-buf nil))))

(defun claude-code-tools--mcp-socket-filter (proc data)
  "Filter for incoming socket data.
Buffers partial lines per-connection in PROC's plist."
  (let ((buf (concat (or (process-get proc :claude-mcp-buf) "") data)))
    (while (string-match "\n" buf)
      (let ((line (substring buf 0 (match-beginning 0)))
            (rest (substring buf (match-end 0))))
        (setq buf rest)
        (when (and line (not (string-empty-p line)))
          (claude-code-tools--mcp-handle-request proc line))))
    (process-put proc :claude-mcp-buf buf)))

(defun claude-code-tools--mcp-handle-request (proc line)
  "Parse LINE as a JSON request and send a response back to PROC.
The request format is `{\"id\": <str>, \"elisp\": <form>}'.
Errors during JSON decoding or evaluation are returned as
`{\"id\": <id>, \"ok\": false, \"error\": <msg>}'."
  (let (req-id elisp-str response-alist)
    (condition-case parse-err
        (let ((req (json-parse-string line :object-type 'alist)))
          (setq req-id (alist-get 'id req)
                elisp-str (alist-get 'elisp req)))
      (error
       ;; JSON parse failed — best-effort response with no id
       (setq response-alist
             `((id . :null)
               (ok . :false)
               (error . ,(format "json parse: %s"
                                 (error-message-string parse-err)))))))
    (unless response-alist
      (setq response-alist
            (claude-code-tools--mcp-eval-and-encode req-id elisp-str)))
    (condition-case _err
        (process-send-string proc
                             (concat (json-encode response-alist) "\n"))
      (error nil))))  ; client may have disconnected

(defun claude-code-tools--mcp-eval-and-encode (req-id elisp-str)
  "Evaluate ELISP-STR and return a response alist for REQ-ID.
The result is included as a JSON value (string, number, bool, …).
On error, the alist contains an `error' key instead of `result'."
  (condition-case eval-err
      (let* ((form (read elisp-str))
             (result (eval form t)))
        ;; json-encode handles strings, numbers, booleans, nil, alists
        ;; and vectors; for anything else (e.g. cons cells, symbols)
        ;; fall back to a printed representation.
        `((id . ,(or req-id ""))
          (ok . t)
          (result . ,(claude-code-tools--mcp-jsonable result))))
    (error
     `((id . ,(or req-id ""))
       (ok . :false)
       (error . ,(error-message-string eval-err))))))

(defun claude-code-tools--mcp-jsonable (value)
  "Coerce VALUE into something `json-encode' can serialize.
Strings, numbers, t, nil, vectors, and alists pass through unchanged.
Symbols and other Lisp objects are converted to their printed form."
  (cond
   ((or (stringp value) (numberp value) (vectorp value)) value)
   ((eq value t) t)
   ((null value) nil)
   ((and (consp value) (consp (car value)) (symbolp (caar value)))
    value)  ; alist — let json-encode handle it
   (t (format "%s" value))))

(provide 'claude-code-emacs-tools)
;;; claude-code-emacs-tools.el ends here
