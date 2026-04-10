;;; claude-code-export.el --- Export conversations to org/markdown -*- lexical-binding: t; -*-

;;; Commentary:

;; Export the current Claude conversation buffer as a clean org-mode or
;; Markdown file, rendering user/assistant/tool/thinking/result blocks
;; into readable document sections.

;;; Code:

(require 'claude-code-vars)
(require 'claude-code-render)

;;;; Helpers

(defun claude-code-export--tool-input-summary (name input)
  "Return a short textual summary of tool INPUT for tool NAME."
  (let ((inp (cond
              ((listp input) input)
              ((hash-table-p input)
               (let (pairs)
                 (maphash (lambda (k v) (push (cons k v) pairs)) input)
                 pairs))
              (t nil))))
    (pcase name
      ("Bash"
       (or (alist-get 'command inp) (json-encode input)))
      ((or "Read" "Write" "Edit" "Glob" "Grep")
       (or (alist-get 'file_path inp)
           (alist-get 'path inp)
           (alist-get 'pattern inp)
           (json-encode input)))
      (_
       (let ((s (json-encode input)))
         (if (> (length s) 200)
             (concat (substring s 0 197) "...")
           s))))))

(defun claude-code-export--sanitize-text (text)
  "Strip text properties from TEXT and ensure it's a string."
  (if (stringp text) (substring-no-properties text) ""))

;;;; Org Export

(defun claude-code-export--msg-to-org (msg)
  "Convert a single message MSG to an org-mode string."
  (let ((type (alist-get 'type msg)))
    (pcase type
      ("user"
       (let ((prompt (claude-code-export--sanitize-text
                      (alist-get 'prompt msg))))
         (concat "** User\n\n" prompt "\n\n")))

      ("assistant"
       (let* ((content (alist-get 'content msg))
              (blocks (if (vectorp content) (append content nil) content))
              (parts nil))
         (dolist (block blocks)
           (let ((btype (alist-get 'type block)))
             (pcase btype
               ("text"
                (push (concat (alist-get 'text block) "\n") parts))
               ("thinking"
                (push (format "#+begin_details Thinking\n%s\n#+end_details\n"
                              (alist-get 'thinking block))
                      parts))
               ("tool_use"
                (let* ((tname (alist-get 'name block))
                       (tinput (alist-get 'input block))
                       (summary (claude-code-export--tool-input-summary
                                 tname tinput)))
                  (push (format "*** Tool: %s\n=%s=\n" tname summary)
                        parts)))
               ("tool_result"
                (let* ((raw (alist-get 'content block))
                       (text (claude-code--tool-result-text raw))
                       (is-err (eq t (alist-get 'is_error block))))
                  (when (and text (not (string-empty-p text)))
                    (let ((label (if is-err "Tool Error" "Tool Result"))
                          (truncated (if (> (length text) 2000)
                                         (concat (substring text 0 1997) "...")
                                       text)))
                      (push (format "#+begin_details %s\n#+begin_example\n%s\n#+end_example\n#+end_details\n"
                                    label truncated)
                            parts))))))))
         (concat "** Assistant\n\n"
                 (mapconcat #'identity (nreverse parts) "\n")
                 "\n")))

      ("result"
       (let ((cost (alist-get 'total_cost_usd msg))
             (turns (alist-get 'num_turns msg))
             (duration (alist-get 'duration_ms msg)))
         (format "-----\n/Done%s/\n\n"
                 (concat
                  (when turns (format " · %d turns" turns))
                  (when cost (format " · $%.4f" cost))
                  (when duration
                    (format " · %.1fs" (/ duration 1000.0)))))))

      ("error"
       (format "** Error\n\n=%s=\n\n" (alist-get 'message msg)))

      ("info"
       (format "/ℹ %s/\n\n" (alist-get 'text msg)))

      (_ ""))))

(defun claude-code-export--to-org (messages)
  "Export MESSAGES (oldest-first list) to an org-mode string."
  (concat "#+title: Claude Conversation Export\n"
          "#+date: " (format-time-string "[%Y-%m-%d %a %H:%M]") "\n\n"
          "* Conversation\n\n"
          (mapconcat #'claude-code-export--msg-to-org messages "")))

;;;; Markdown Export

(defun claude-code-export--msg-to-md (msg)
  "Convert a single message MSG to a Markdown string."
  (let ((type (alist-get 'type msg)))
    (pcase type
      ("user"
       (let ((prompt (claude-code-export--sanitize-text
                      (alist-get 'prompt msg))))
         (concat "## 🧑 User\n\n" prompt "\n\n")))

      ("assistant"
       (let* ((content (alist-get 'content msg))
              (blocks (if (vectorp content) (append content nil) content))
              (parts nil))
         (dolist (block blocks)
           (let ((btype (alist-get 'type block)))
             (pcase btype
               ("text"
                (push (concat (alist-get 'text block) "\n") parts))
               ("thinking"
                (push (format "<details>\n<summary>Thinking</summary>\n\n%s\n\n</details>\n"
                              (alist-get 'thinking block))
                      parts))
               ("tool_use"
                (let* ((tname (alist-get 'name block))
                       (tinput (alist-get 'input block))
                       (summary (claude-code-export--tool-input-summary
                                 tname tinput)))
                  (push (format "### 🔧 Tool: %s\n`%s`\n" tname summary)
                        parts)))
               ("tool_result"
                (let* ((raw (alist-get 'content block))
                       (text (claude-code--tool-result-text raw))
                       (is-err (eq t (alist-get 'is_error block))))
                  (when (and text (not (string-empty-p text)))
                    (let ((label (if is-err "Tool Error" "Tool Result"))
                          (truncated (if (> (length text) 2000)
                                         (concat (substring text 0 1997) "...")
                                       text)))
                      (push (format "<details>\n<summary>%s</summary>\n\n```\n%s\n```\n\n</details>\n"
                                    label truncated)
                            parts))))))))
         (concat "## 🤖 Assistant\n\n"
                 (mapconcat #'identity (nreverse parts) "\n")
                 "\n")))

      ("result"
       (let ((cost (alist-get 'total_cost_usd msg))
             (turns (alist-get 'num_turns msg))
             (duration (alist-get 'duration_ms msg)))
         (format "---\n*Done%s*\n\n"
                 (concat
                  (when turns (format " · %d turns" turns))
                  (when cost (format " · $%.4f" cost))
                  (when duration
                    (format " · %.1fs" (/ duration 1000.0)))))))

      ("error"
       (format "## ❌ Error\n\n`%s`\n\n" (alist-get 'message msg)))

      ("info"
       (format "*ℹ %s*\n\n" (alist-get 'text msg)))

      (_ ""))))

(defun claude-code-export--to-md (messages)
  "Export MESSAGES (oldest-first list) to a Markdown string."
  (concat "# Claude Conversation Export\n\n"
          "*Exported: " (format-time-string "%Y-%m-%d %H:%M") "*\n\n"
          (mapconcat #'claude-code-export--msg-to-md messages "")))

;;;; Interactive Entry Point

;;;###autoload
(defun claude-code-export (format)
  "Export the current Claude conversation to FORMAT.
FORMAT is a symbol: `org' or `markdown'.  Interactively, choose
from a prompt.  The export is written to a new buffer from which
it can be saved to a file."
  (interactive
   (list (intern (completing-read "Export format: " '("org" "markdown") nil t))))
  (unless (bound-and-true-p claude-code--messages)
    (user-error "No conversation messages to export"))
  (let* ((msgs (reverse claude-code--messages))
         (text (pcase format
                 ('org      (claude-code-export--to-org msgs))
                 ('markdown (claude-code-export--to-md msgs))
                 (_         (user-error "Unknown format: %s" format))))
         (ext  (pcase format ('org ".org") ('markdown ".md")))
         (buf  (generate-new-buffer
                (format "*Claude Export%s*" ext))))
    (with-current-buffer buf
      (insert text)
      (goto-char (point-min))
      (pcase format
        ('org      (when (fboundp 'org-mode) (org-mode)))
        ('markdown (when (fboundp 'markdown-mode) (markdown-mode))))
      (set-buffer-modified-p nil))
    (pop-to-buffer buf)
    (message "Conversation exported to %s (%d messages)" (buffer-name buf) (length msgs))))

(provide 'claude-code-export)
;;; claude-code-export.el ends here
