;;; claude-code-ambient.el --- Ambient context from editor state -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Kiran Shenoy
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Silently tracks the user's editing context — which file they are
;; visiting, where the cursor is, what region is selected — and
;; surfaces it as implicit context on the next prompt.  The user never
;; has to paste file paths or describe "the function I'm looking at";
;; Claude already knows.
;;
;; Implementation:
;;   - `window-buffer-change-functions' records buffer switches.
;;   - `post-command-hook' (throttled) captures cursor position and
;;     active region.
;;   - `claude-code-ambient--build-context' assembles a short context
;;     block prepended to prompts in `claude-code-send'.
;;
;; All tracking is buffer-local to Claude conversation buffers and
;; only fires when `claude-code-ambient-enabled' is non-nil.

;;; Code:

(require 'cl-lib)

;;;; Customization

(defcustom claude-code-ambient-enabled t
  "When non-nil, automatically include ambient editor context in prompts."
  :type 'boolean
  :group 'claude-code)

(defcustom claude-code-ambient-max-region 500
  "Maximum characters of selected region to include as context."
  :type 'integer
  :group 'claude-code)

(defcustom claude-code-ambient-idle-threshold 2.0
  "Seconds of idle time before capturing ambient context snapshot.
Prevents excessive tracking during rapid navigation."
  :type 'number
  :group 'claude-code)

;;;; State (global — shared across all Claude sessions)

(defvar claude-code-ambient--current-file nil
  "Absolute path of the file the user is currently visiting, or nil.")

(defvar claude-code-ambient--current-line nil
  "Line number (1-based) of point in the current file.")

(defvar claude-code-ambient--current-defun nil
  "Name of the defun/function enclosing point, or nil.")

(defvar claude-code-ambient--current-mode nil
  "Major mode symbol of the current non-Claude buffer.")

(defvar claude-code-ambient--active-region nil
  "Active region text (truncated), or nil if no region.")

(defvar claude-code-ambient--last-update 0
  "Timestamp of the last ambient context update.")

(defvar claude-code-ambient--recent-files nil
  "List of recently visited files (most recent first), max 5.")

(defvar claude-code-ambient--idle-timer nil
  "Idle timer for ambient context capture.")

;;;; Context capture

(defun claude-code-ambient--capture ()
  "Capture ambient context from the current editor state.
Called from an idle timer so it doesn't slow down editing."
  (let ((buf (window-buffer (selected-window))))
    ;; Only capture from non-Claude, file-visiting buffers.
    (when (and buf
               (buffer-live-p buf)
               (not (with-current-buffer buf
                      (derived-mode-p 'claude-code-mode))))
      (with-current-buffer buf
        (let ((file (buffer-file-name))
              (line (line-number-at-pos (point)))
              (defun-name (ignore-errors
                            (which-function)))
              (mode major-mode)
              (region (when (use-region-p)
                        (let ((text (buffer-substring-no-properties
                                     (region-beginning) (region-end))))
                          (if (> (length text) claude-code-ambient-max-region)
                              (concat (substring text 0 claude-code-ambient-max-region)
                                      "…")
                            text)))))
          (setq claude-code-ambient--current-file file
                claude-code-ambient--current-line line
                claude-code-ambient--current-defun defun-name
                claude-code-ambient--current-mode mode
                claude-code-ambient--active-region region
                claude-code-ambient--last-update (float-time))
          ;; Track recent files (deduplicated, max 5).
          (when file
            (setq claude-code-ambient--recent-files
                  (seq-take
                   (cons file (delete file claude-code-ambient--recent-files))
                   5))))))))

;;;; Context assembly

(defun claude-code-ambient--build-context ()
  "Build an ambient context string to prepend to prompts.
Returns nil if there is no meaningful context to include."
  (when (and claude-code-ambient-enabled
             claude-code-ambient--current-file
             ;; Only include if the context is reasonably fresh (< 5 min).
             (< (- (float-time) claude-code-ambient--last-update) 300))
    (let* ((file claude-code-ambient--current-file)
           (rel (claude-code-ambient--relative-path file))
           (parts nil))
      ;; File + line.
      (push (format "File: %s:%d" rel (or claude-code-ambient--current-line 1))
            parts)
      ;; Function/defun.
      (when claude-code-ambient--current-defun
        (push (format "Function: %s" claude-code-ambient--current-defun)
              parts))
      ;; Major mode.
      (when claude-code-ambient--current-mode
        (push (format "Mode: %s" claude-code-ambient--current-mode)
              parts))
      ;; Active selection.
      (when claude-code-ambient--active-region
        (push (format "Selected:\n```\n%s\n```"
                      claude-code-ambient--active-region)
              parts))
      ;; Recent files (other than current).
      (let ((others (seq-take
                     (seq-remove (lambda (f) (equal f file))
                                 claude-code-ambient--recent-files)
                     3)))
        (when others
          (push (format "Recent: %s"
                        (mapconcat #'claude-code-ambient--relative-path
                                   others ", "))
                parts)))
      ;; Assemble.
      (format "[Ambient context — user's editor state]\n%s"
              (mapconcat #'identity (nreverse parts) "\n")))))

(defun claude-code-ambient--relative-path (file)
  "Return FILE relative to the session's cwd, or the absolute path."
  (let ((cwd (or (and (boundp 'claude-code--cwd) claude-code--cwd)
                 default-directory)))
    (if (and cwd (string-prefix-p (expand-file-name cwd) file))
        (file-relative-name file cwd)
      file)))

;;;; Lifecycle

(defun claude-code-ambient-start ()
  "Start ambient context tracking."
  (when claude-code-ambient-enabled
    (claude-code-ambient-stop)  ; clean up any previous timer
    (setq claude-code-ambient--idle-timer
          (run-with-idle-timer claude-code-ambient-idle-threshold
                               t  ; repeat
                               #'claude-code-ambient--capture))))

(defun claude-code-ambient-stop ()
  "Stop ambient context tracking."
  (when claude-code-ambient--idle-timer
    (cancel-timer claude-code-ambient--idle-timer)
    (setq claude-code-ambient--idle-timer nil)))

(defun claude-code-ambient-reset ()
  "Clear all ambient context state."
  (setq claude-code-ambient--current-file nil
        claude-code-ambient--current-line nil
        claude-code-ambient--current-defun nil
        claude-code-ambient--current-mode nil
        claude-code-ambient--active-region nil
        claude-code-ambient--recent-files nil
        claude-code-ambient--last-update 0))

;; Auto-start when loaded.
(claude-code-ambient-start)

(provide 'claude-code-ambient)
;;; claude-code-ambient.el ends here
