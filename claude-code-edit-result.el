;;; claude-code-edit-result.el --- Editable tool results for claude-code.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Allow the user to edit tool result text in a dedicated buffer, then
;; save changes back to the conversation's in-memory message list and
;; re-render.  Avoids describing corrections in a follow-up message —
;; the user edits the tool result directly and Claude sees the updated
;; version on the next turn.

;;; Code:

(require 'cl-lib)

;; Forward declarations
(declare-function claude-code--schedule-render "claude-code-events")

;;;; Buffer-local state for the edit buffer

(defvar-local claude-code-edit-result--block nil
  "The tool-result alist whose `content' is being edited.
A reference to the block in `claude-code--messages'.")

(defvar-local claude-code-edit-result--parent-buf nil
  "The Claude conversation buffer that owns this tool result.")

(defvar-local claude-code-edit-result--original nil
  "Original content string, for detecting actual changes.")

;;;; Major mode

(defvar-keymap claude-code-edit-result-mode-map
  :doc "Keymap for the tool-result edit buffer."
  "C-c C-c" #'claude-code-edit-result-save
  "C-c C-k" #'claude-code-edit-result-cancel)

(define-derived-mode claude-code-edit-result-mode text-mode "Edit-Result"
  "Major mode for editing a Claude tool result.
\\<claude-code-edit-result-mode-map>\
\\[claude-code-edit-result-save] saves changes back to the conversation.
\\[claude-code-edit-result-cancel] discards changes."
  :group 'claude-code
  (setq-local header-line-format
              (substitute-command-keys
               "Edit tool result.  \\[claude-code-edit-result-save] save  \\[claude-code-edit-result-cancel] cancel")))

;;;; Commands

(defun claude-code-edit-result-save ()
  "Save the edited tool result back to the conversation and re-render."
  (interactive)
  (let ((new-content (buffer-substring-no-properties (point-min) (point-max)))
        (block claude-code-edit-result--block)
        (parent claude-code-edit-result--parent-buf)
        (original claude-code-edit-result--original))
    (unless block
      (user-error "No tool-result block associated with this buffer"))
    ;; Only update if the content actually changed
    (if (string= new-content original)
        (progn
          (quit-window t)
          (message "No changes made"))
      ;; Update the block's content in-place — this mutates the alist in
      ;; claude-code--messages so the edit persists across re-renders.
      (claude-code-edit-result--set-content block new-content)
      (quit-window t)
      ;; Re-render the parent conversation buffer
      (when (and parent (buffer-live-p parent))
        (with-current-buffer parent
          (claude-code--schedule-render)))
      (message "Tool result updated"))))

(defun claude-code-edit-result-cancel ()
  "Discard changes and close the edit buffer."
  (interactive)
  (quit-window t)
  (message "Edit cancelled"))

;;;; Content mutation

(defun claude-code-edit-result--set-content (block new-content)
  "Set BLOCK's content field to NEW-CONTENT.
Handles both string and vector-of-blocks content formats."
  (let ((raw (alist-get 'content block)))
    (cond
     ;; String content (built-in tools) — replace directly
     ((stringp raw)
      (setf (alist-get 'content block) new-content))
     ;; Vector/list of {type, text} blocks — update the first text block
     ((or (vectorp raw) (listp raw))
      (let ((items (if (vectorp raw) (append raw nil) raw)))
        (if-let ((text-block (cl-find-if
                              (lambda (b) (equal "text" (alist-get 'type b)))
                              items)))
            (setf (alist-get 'text text-block) new-content)
          ;; No text block — replace the whole content with a string
          (setf (alist-get 'content block) new-content))))
     ;; Nil or unknown — just set as string
     (t
      (setf (alist-get 'content block) new-content)))))

;;;; Integration: opening the edit buffer

(defun claude-code-edit-result-open (block parent-buf)
  "Open tool-result BLOCK for editing.
PARENT-BUF is the Claude conversation buffer."
  (let* ((content (claude-code-edit-result--extract-text block))
         (buf (get-buffer-create "*Claude Edit Result*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert content))
      (claude-code-edit-result-mode)
      (setq-local claude-code-edit-result--block block)
      (setq-local claude-code-edit-result--parent-buf parent-buf)
      (setq-local claude-code-edit-result--original content)
      (goto-char (point-min))
      (set-buffer-modified-p nil))
    (pop-to-buffer buf)))

(defun claude-code-edit-result--extract-text (block)
  "Extract the text content from a tool-result BLOCK."
  (let ((raw (alist-get 'content block)))
    (cond
     ((stringp raw) raw)
     ((or (vectorp raw) (listp raw))
      (let* ((items (if (vectorp raw) (append raw nil) raw))
             (texts (delq nil (mapcar (lambda (b) (alist-get 'text b)) items))))
        (mapconcat #'identity texts "\n")))
     (t ""))))

;;;; Button helper for render pipeline

(declare-function claude-code--splice-heading-button "claude-code-render")

(defun claude-code-edit-result-maybe-add-button (block)
  "Splice an [edit] button into the current tool-result heading.
BLOCK is the tool-result alist.  Call after other heading buttons."
  (let ((parent-buf (current-buffer)))
    (claude-code--splice-heading-button
     "[edit]" 'claude-code-action-button
     "Edit this tool result"
     (lambda (_btn) (claude-code-edit-result-open block parent-buf)))))

(provide 'claude-code-edit-result)
;;; claude-code-edit-result.el ends here
