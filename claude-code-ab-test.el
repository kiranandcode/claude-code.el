;;; claude-code-ab-test.el --- Live A/B testing of output format -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Kiran Shenoy
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; When uncertain how to format a response, the agent can split the
;; window and render two versions side by side, prompting the user
;; for a preference.  The preferred format can then be encoded into
;; the rendering source.
;;
;; Genuine self-improvement with a human-in-the-loop feedback signal
;; — possible only because the agent can read and write its own source.
;;
;; Usage (from the agent):
;;   1. Call EvalEmacs to invoke `claude-code-ab-test-start' with two
;;      render variants (each a string of formatted output).
;;   2. The user sees them side by side and presses `a' or `b'.
;;   3. The result is returned to the agent, which can then apply
;;      the preferred format to future renders.
;;
;; Usage (interactive):
;;   M-x claude-code-ab-test-start — prompts for two text variants.

;;; Code:

(require 'cl-lib)

;;;; State

(defvar claude-code-ab-test--active nil
  "Non-nil when an A/B test is in progress.
Plist: (:buf-a BUF :buf-b BUF :callback FN :description STR).")

(defvar claude-code-ab-test--history nil
  "List of past A/B test results.
Each entry: (DESCRIPTION CHOICE TIMESTAMP).")

;;;; Core

(defun claude-code-ab-test-start (description variant-a variant-b &optional callback)
  "Start a live A/B test with two output VARIANT-A and VARIANT-B.
DESCRIPTION names the test.  CALLBACK is called with the winner
symbol (`a' or `b') when the user decides.  If nil, the choice is
just recorded in `claude-code-ab-test--history'.

Returns immediately; the user picks asynchronously."
  (let ((buf-a (get-buffer-create "*Claude A/B: Variant A*"))
        (buf-b (get-buffer-create "*Claude A/B: Variant B*")))
    ;; Populate variant buffers.
    (with-current-buffer buf-a
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "═══ Variant A: %s ═══\n\n" description)
                            'face 'bold))
        (insert variant-a)
        (goto-char (point-min))
        (claude-code-ab-test-mode)))
    (with-current-buffer buf-b
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "═══ Variant B: %s ═══\n\n" description)
                            'face 'bold))
        (insert variant-b)
        (goto-char (point-min))
        (claude-code-ab-test-mode)))
    ;; Display side by side.
    (delete-other-windows)
    (switch-to-buffer buf-a)
    (let ((win-b (split-window-right)))
      (set-window-buffer win-b buf-b))
    ;; Store state.
    (setq claude-code-ab-test--active
          (list :buf-a buf-a
                :buf-b buf-b
                :callback callback
                :description description))
    (message "A/B test: press 'a' to pick Variant A, 'b' to pick Variant B, 'q' to cancel")))

(defun claude-code-ab-test-choose (choice)
  "Record the user's CHOICE (`a' or `b') and clean up."
  (unless claude-code-ab-test--active
    (user-error "No A/B test in progress"))
  (let* ((desc (plist-get claude-code-ab-test--active :description))
         (callback (plist-get claude-code-ab-test--active :callback))
         (buf-a (plist-get claude-code-ab-test--active :buf-a))
         (buf-b (plist-get claude-code-ab-test--active :buf-b)))
    ;; Record result.
    (push (list desc choice (current-time)) claude-code-ab-test--history)
    ;; Clean up buffers.
    (when (buffer-live-p buf-a) (kill-buffer buf-a))
    (when (buffer-live-p buf-b) (kill-buffer buf-b))
    (setq claude-code-ab-test--active nil)
    ;; Restore window layout.
    (delete-other-windows)
    ;; Invoke callback.
    (when callback
      (funcall callback choice))
    (message "A/B test '%s': chose variant %s" desc (upcase (symbol-name choice)))))

(defun claude-code-ab-test-choose-a ()
  "Choose Variant A in the current A/B test."
  (interactive)
  (claude-code-ab-test-choose 'a))

(defun claude-code-ab-test-choose-b ()
  "Choose Variant B in the current A/B test."
  (interactive)
  (claude-code-ab-test-choose 'b))

(defun claude-code-ab-test-cancel ()
  "Cancel the current A/B test without choosing."
  (interactive)
  (when claude-code-ab-test--active
    (let ((buf-a (plist-get claude-code-ab-test--active :buf-a))
          (buf-b (plist-get claude-code-ab-test--active :buf-b)))
      (when (buffer-live-p buf-a) (kill-buffer buf-a))
      (when (buffer-live-p buf-b) (kill-buffer buf-b))
      (setq claude-code-ab-test--active nil)
      (delete-other-windows)
      (message "A/B test cancelled"))))

;;;; History

(defun claude-code-ab-test-history ()
  "Display past A/B test results."
  (interactive)
  (if (null claude-code-ab-test--history)
      (message "No A/B test history.")
    (with-current-buffer (get-buffer-create "*Claude A/B History*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "A/B Test History\n")
        (insert (make-string 40 ?─) "\n\n")
        (dolist (entry (reverse claude-code-ab-test--history))
          (let ((desc (nth 0 entry))
                (choice (nth 1 entry))
                (time (nth 2 entry)))
            (insert (format "  %s  %s → Variant %s\n"
                            (format-time-string "%Y-%m-%d %H:%M" time)
                            desc
                            (upcase (symbol-name choice))))))
        (goto-char (point-min))
        (special-mode))
      (display-buffer (current-buffer)))))

(defun claude-code-ab-test--last-result ()
  "Return the choice from the most recent A/B test, or nil.
For agent consumption: returns \"a\" or \"b\" as a string."
  (when-let ((entry (car claude-code-ab-test--history)))
    (symbol-name (nth 1 entry))))

;;;; Minor mode for A/B test buffers

(defvar-keymap claude-code-ab-test-mode-map
  :doc "Keymap for A/B test variant buffers."
  "a" #'claude-code-ab-test-choose-a
  "b" #'claude-code-ab-test-choose-b
  "q" #'claude-code-ab-test-cancel)

(define-derived-mode claude-code-ab-test-mode special-mode "Claude-AB"
  "Major mode for A/B test variant display buffers.
Press `a' to pick Variant A, `b' for Variant B, `q' to cancel."
  :group 'claude-code
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local header-line-format
              '(" A/B Test — press "
                (:propertize "a" face bold) " or "
                (:propertize "b" face bold) " to choose, "
                (:propertize "q" face bold) " to cancel")))

(provide 'claude-code-ab-test)
;;; claude-code-ab-test.el ends here
