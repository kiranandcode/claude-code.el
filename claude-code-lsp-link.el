;;; claude-code-lsp-link.el --- LSP symbol linkification for claude-code.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Scan assistant responses for identifiers in backtick code spans and
;; linkify those that match symbols known to the project's LSP server
;; (eglot or lsp-mode).  Clicking a linkified identifier jumps to its
;; definition.

;;; Code:

(require 'cl-lib)

;; Forward declarations — eglot / lsp-mode may not be loaded.
(declare-function eglot-current-server "eglot")
(declare-function eglot--request "eglot")
(declare-function lsp-request "lsp-mode")
(declare-function lsp-workspaces "lsp-mode")

;;;; Customization

(defcustom claude-code-enable-lsp-links t
  "When non-nil, linkify identifiers in responses via LSP workspace symbols.
Requires an active eglot or lsp-mode server in the project."
  :type 'boolean
  :group 'claude-code)

;;;; Per-render symbol cache

(defvar claude-code-lsp-link--cache (make-hash-table :test 'equal)
  "Cache of identifier → location alist for the current render cycle.
Keys are identifier strings.  Values are either:
  (file line column)  — a known symbol location
  nil                 — looked up but not found
Cleared at the start of each render cycle.")

(defvar claude-code-lsp-link--cache-lsp-buf nil
  "The LSP buffer used for the current cache.
If the LSP buffer changes, the cache is invalidated.")

(defun claude-code-lsp-link--clear-cache ()
  "Clear the symbol lookup cache."
  (clrhash claude-code-lsp-link--cache)
  (setq claude-code-lsp-link--cache-lsp-buf nil))

;;;; LSP server detection

(defun claude-code-lsp-link--find-lsp-buffer (cwd)
  "Find a buffer visiting a file under CWD with an active LSP server.
Returns the buffer or nil."
  (cl-some
   (lambda (buf)
     (with-current-buffer buf
       (and buffer-file-name
            (string-prefix-p (expand-file-name cwd) (expand-file-name buffer-file-name))
            (or (and (bound-and-true-p eglot--managed-mode)
                     (fboundp 'eglot-current-server)
                     (eglot-current-server))
                (and (bound-and-true-p lsp-mode)
                     (fboundp 'lsp-workspaces)
                     (lsp-workspaces)))
            buf)))
   (buffer-list)))

;;;; Symbol lookup

(defun claude-code-lsp-link--lookup (identifier lsp-buf)
  "Look up IDENTIFIER via the LSP server in LSP-BUF.
Returns (file line column) or nil.  Results are cached."
  ;; Check cache first
  (let ((cached (gethash identifier claude-code-lsp-link--cache 'miss)))
    (if (not (eq cached 'miss))
        cached
      ;; Query LSP
      (let ((result (claude-code-lsp-link--query identifier lsp-buf)))
        (puthash identifier result claude-code-lsp-link--cache)
        result))))

(defun claude-code-lsp-link--query (identifier lsp-buf)
  "Query the LSP server in LSP-BUF for IDENTIFIER.
Returns (file line column) for the first exact match, or nil."
  (condition-case nil
      (with-current-buffer lsp-buf
        (cond
         ;; Eglot
         ((and (bound-and-true-p eglot--managed-mode)
               (fboundp 'eglot-current-server)
               (fboundp 'eglot--request))
          (let* ((server (eglot-current-server))
                 (results (and server
                               (eglot--request server :workspace/symbol
                                               `(:query ,identifier)))))
            (claude-code-lsp-link--extract-match identifier results 'eglot)))
         ;; lsp-mode
         ((and (bound-and-true-p lsp-mode)
               (fboundp 'lsp-request))
          (let ((results (lsp-request "workspace/symbol"
                                      `(:query ,identifier))))
            (claude-code-lsp-link--extract-match identifier results 'lsp-mode)))
         (t nil)))
    ;; Any LSP error — silently return nil
    (error nil)))

(defun claude-code-lsp-link--extract-match (identifier results backend)
  "Extract the first exact name match for IDENTIFIER from RESULTS.
BACKEND is `eglot' or `lsp-mode'.
Returns (file line column) or nil."
  (when results
    (let ((items (if (vectorp results) (append results nil) results)))
      (cl-some
       (lambda (sym)
         (let* ((name (cond
                       ((hash-table-p sym) (gethash "name" sym))
                       ((listp sym) (or (alist-get 'name sym)
                                        (plist-get sym :name)))
                       (t nil)))
                (location (cond
                           ((hash-table-p sym) (gethash "location" sym))
                           ((listp sym) (or (alist-get 'location sym)
                                            (plist-get sym :location)))
                           (t nil))))
           (when (and name (string= name identifier) location)
             (claude-code-lsp-link--location-to-triple location backend))))
       items))))

(defun claude-code-lsp-link--location-to-triple (location backend)
  "Convert an LSP LOCATION to (file line column).
BACKEND is `eglot' or `lsp-mode'."
  (condition-case nil
      (let* ((uri (cond
                   ((hash-table-p location) (gethash "uri" location))
                   ((listp location) (or (alist-get 'uri location)
                                         (plist-get location :uri)))
                   (t nil)))
             (range (cond
                     ((hash-table-p location) (gethash "range" location))
                     ((listp location) (or (alist-get 'range location)
                                           (plist-get location :range)))
                     (t nil)))
             (start (when range
                      (cond
                       ((hash-table-p range) (gethash "start" range))
                       ((listp range) (or (alist-get 'start range)
                                          (plist-get range :start)))
                       (t nil))))
             (line (when start
                     (cond
                      ((hash-table-p start) (gethash "line" start))
                      ((listp start) (or (alist-get 'line start)
                                         (plist-get start :line)))
                      (t nil))))
             (col (when start
                    (cond
                     ((hash-table-p start) (gethash "character" start))
                     ((listp start) (or (alist-get 'character start)
                                        (plist-get start :character)))
                     (t nil))))
             (file (when uri
                     (if (string-prefix-p "file://" uri)
                         (url-unhex-string (substring uri 7))
                       uri))))
        (when (and file line)
          (list file (1+ line) (or col 0))))
    (error nil)))

;;;; Text scanning and buttonization

(defun claude-code-lsp-link--linkify-region (start end cwd)
  "Scan START..END for inline code spans and linkify LSP symbols.
CWD is the project root used to find an LSP-managed buffer."
  (when (and claude-code-enable-lsp-links cwd)
    (let ((lsp-buf (claude-code-lsp-link--find-lsp-buffer cwd)))
      (when lsp-buf
        ;; Ensure cache is primed for this LSP buffer
        (unless (eq lsp-buf claude-code-lsp-link--cache-lsp-buf)
          (claude-code-lsp-link--clear-cache)
          (setq claude-code-lsp-link--cache-lsp-buf lsp-buf))
        (save-excursion
          (goto-char start)
          ;; Walk through the region looking for text with the
          ;; claude-code-markdown-code face — these are the backtick spans.
          (let ((pos start))
            (while (< pos end)
              (let* ((face-at (get-text-property pos 'face))
                     (has-code-face
                      (cond
                       ((eq face-at 'claude-code-markdown-code) t)
                       ((and (listp face-at)
                             (memq 'claude-code-markdown-code face-at)) t)
                       (t nil))))
                (if (not has-code-face)
                    ;; Skip to next face change
                    (setq pos (next-single-property-change pos 'face nil end))
                  ;; Found a code span — find its extent
                  (let* ((span-end (next-single-property-change pos 'face nil end))
                         (text (buffer-substring-no-properties pos span-end)))
                    ;; Only linkify if it looks like a single identifier
                    ;; (not multi-word, not a path, not a command)
                    (when (and (string-match-p "\\`[a-zA-Z_][a-zA-Z0-9_.:-]*\\'" text)
                               (not (string-match-p "/" text))
                               (> (length text) 1))
                      (let ((loc (claude-code-lsp-link--lookup text lsp-buf)))
                        (when loc
                          (let ((file (nth 0 loc))
                                (line (nth 1 loc))
                                (col  (nth 2 loc)))
                            (make-text-button
                             pos span-end
                             'action (lambda (_)
                                       (find-file file)
                                       (goto-char (point-min))
                                       (forward-line (1- line))
                                       (forward-char col)
                                       (pulse-momentary-highlight-one-line (point)))
                             'face '(claude-code-file-link claude-code-markdown-code)
                             'help-echo (format "→ %s:%d"
                                                (abbreviate-file-name file) line)
                             'follow-link t)))))
                    (setq pos span-end)))))))))))

(provide 'claude-code-lsp-link)
;;; claude-code-lsp-link.el ends here
