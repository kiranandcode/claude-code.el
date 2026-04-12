;;; claude-code-adaptive.el --- Adaptive rendering from observed UI behaviour -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Kiran Shenoy
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tracks how the user interacts with the conversation buffer —
;; which sections they expand/collapse, which code blocks they copy,
;; how long point lingers in different regions — and uses these
;; observations to adjust rendering defaults.
;;
;; This is not a preference setting.  It is literal observation of
;; live UI state driving self-modification of the renderer.
;;
;; Tracked signals:
;;   - Section toggle (expand/collapse) per section type
;;   - Code block copy events
;;   - Point dwell time per section type (via idle timer)
;;
;; Adjustments applied:
;;   - Default collapse state for section types (e.g. always-collapse
;;     thinking blocks if the user never expands them)
;;   - The agent can read the observations via
;;     `claude-code-adaptive--summary' and propose deeper changes.

;;; Code:

(require 'cl-lib)

;;;; Customization

(defcustom claude-code-adaptive-enabled t
  "When non-nil, track UI interactions and adapt rendering."
  :type 'boolean
  :group 'claude-code)

(defcustom claude-code-adaptive-dwell-interval 3.0
  "Seconds of idle time before recording a dwell observation."
  :type 'number
  :group 'claude-code)

;;;; Observation storage

(defvar claude-code-adaptive--toggle-counts (make-hash-table :test #'eq)
  "Hash: section-type symbol → (EXPAND-COUNT . COLLAPSE-COUNT).")

(defvar claude-code-adaptive--copy-count 0
  "Number of code block copy events observed.")

(defvar claude-code-adaptive--dwell-times (make-hash-table :test #'eq)
  "Hash: section-type symbol → total dwell seconds (float).")

(defvar claude-code-adaptive--dwell-timer nil
  "Idle timer for dwell tracking.")

(defvar claude-code-adaptive--last-dwell-section nil
  "Section type symbol where point was during last dwell tick.")

(defvar claude-code-adaptive--last-dwell-time nil
  "Timestamp of last dwell tick.")

;;;; Collapse overrides (the adaptive output)

(defvar claude-code-adaptive--collapse-overrides (make-hash-table :test #'eq)
  "Hash: section-type symbol → t (force collapse) or nil.
Applied by `claude-code-adaptive-default-hidden-p'.")

;;;; Toggle tracking (advice on magit-section-toggle)

(defun claude-code-adaptive--track-toggle (orig-fn &rest args)
  "Advice around `magit-section-toggle' to record expand/collapse.
ORIG-FN and ARGS are the original function and its arguments."
  (when claude-code-adaptive-enabled
    (when-let* ((sec (magit-current-section))
                (type (oref sec type))
                (was-hidden (oref sec hidden)))
      (let ((counts (gethash type claude-code-adaptive--toggle-counts
                             (cons 0 0))))
        (if was-hidden
            ;; Was hidden → expanding
            (setcar counts (1+ (car counts)))
          ;; Was visible → collapsing
          (setcdr counts (1+ (cdr counts))))
        (puthash type counts claude-code-adaptive--toggle-counts))))
  (apply orig-fn args))

;;;; Copy tracking (advice on claude-code-copy-code-block)

(defun claude-code-adaptive--track-copy (orig-fn &rest args)
  "Advice around `claude-code-copy-code-block' to count copies.
ORIG-FN and ARGS are the original function and its arguments."
  (when claude-code-adaptive-enabled
    (cl-incf claude-code-adaptive--copy-count))
  (apply orig-fn args))

;;;; Dwell tracking (idle timer)

(defun claude-code-adaptive--dwell-tick ()
  "Record a dwell observation at the current point position."
  (when (and claude-code-adaptive-enabled
             (derived-mode-p 'claude-code-mode))
    (when-let* ((sec (magit-current-section))
                (type (oref sec type)))
      (let ((now (float-time)))
        ;; If still in the same section type, accumulate time.
        (when (and (eq type claude-code-adaptive--last-dwell-section)
                   claude-code-adaptive--last-dwell-time)
          (let ((dt (- now claude-code-adaptive--last-dwell-time)))
            (when (< dt 30)  ; cap at 30s to avoid counting AFK time
              (puthash type
                       (+ (gethash type claude-code-adaptive--dwell-times 0.0) dt)
                       claude-code-adaptive--dwell-times))))
        (setq claude-code-adaptive--last-dwell-section type
              claude-code-adaptive--last-dwell-time now)))))

;;;; Analysis and adjustment

(defun claude-code-adaptive--analyze ()
  "Analyze observations and update collapse overrides.
Returns an alist of adjustments made."
  (let (adjustments)
    (maphash
     (lambda (type counts)
       (let ((expands (car counts))
             (collapses (cdr counts))
             (total (+ (car counts) (cdr counts))))
         ;; If a section type is collapsed >80% of the time with
         ;; at least 5 observations, default to collapsed.
         (when (and (>= total 5)
                    (> (/ (float collapses) total) 0.8))
           (unless (gethash type claude-code-adaptive--collapse-overrides)
             (puthash type t claude-code-adaptive--collapse-overrides)
             (push (cons type 'default-collapse) adjustments)))
         ;; If expanded >80% of the time, default to expanded.
         (when (and (>= total 5)
                    (> (/ (float expands) total) 0.8))
           (when (gethash type claude-code-adaptive--collapse-overrides)
             (remhash type claude-code-adaptive--collapse-overrides)
             (push (cons type 'default-expand) adjustments)))))
     claude-code-adaptive--toggle-counts)
    adjustments))

(defun claude-code-adaptive-default-hidden-p (section)
  "Return non-nil if SECTION should be hidden by default per adaptive data."
  (and claude-code-adaptive-enabled
       (gethash (oref section type)
                claude-code-adaptive--collapse-overrides)))

;;;; Summary (for agent consumption)

(defun claude-code-adaptive--summary ()
  "Return a human-readable summary of UI observations."
  (let ((lines nil))
    (push "=== Adaptive Rendering Observations ===" lines)
    (push (format "Code block copies: %d" claude-code-adaptive--copy-count) lines)
    (push "" lines)
    (push "Section toggle counts (type: expand/collapse):" lines)
    (maphash
     (lambda (type counts)
       (push (format "  %s: %d expands, %d collapses"
                     type (car counts) (cdr counts))
             lines))
     claude-code-adaptive--toggle-counts)
    (push "" lines)
    (push "Dwell times (type: seconds):" lines)
    (maphash
     (lambda (type secs)
       (push (format "  %s: %.1fs" type secs) lines))
     claude-code-adaptive--dwell-times)
    (push "" lines)
    (push "Active collapse overrides:" lines)
    (let ((any nil))
      (maphash
       (lambda (type _v)
         (push (format "  %s → default collapsed" type) lines)
         (setq any t))
       claude-code-adaptive--collapse-overrides)
      (unless any
        (push "  (none)" lines)))
    (mapconcat #'identity (nreverse lines) "\n")))

;;;; Interactive

(defun claude-code-adaptive-show-observations ()
  "Display adaptive rendering observations in a temporary buffer."
  (interactive)
  (with-current-buffer (get-buffer-create "*Claude Adaptive*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (claude-code-adaptive--summary))
      (goto-char (point-min))
      (special-mode))
    (display-buffer (current-buffer))))

(defun claude-code-adaptive-reset ()
  "Reset all adaptive observations and overrides."
  (interactive)
  (clrhash claude-code-adaptive--toggle-counts)
  (clrhash claude-code-adaptive--dwell-times)
  (clrhash claude-code-adaptive--collapse-overrides)
  (setq claude-code-adaptive--copy-count 0)
  (message "Adaptive rendering observations reset."))

;;;; Lifecycle

(defun claude-code-adaptive-setup ()
  "Enable adaptive rendering tracking."
  (when claude-code-adaptive-enabled
    (claude-code-adaptive-teardown)
    ;; Toggle tracking.
    (advice-add 'magit-section-toggle :around
                #'claude-code-adaptive--track-toggle)
    ;; Copy tracking.
    (when (fboundp 'claude-code-copy-code-block)
      (advice-add 'claude-code-copy-code-block :around
                  #'claude-code-adaptive--track-copy))
    ;; Dwell tracking.
    (setq claude-code-adaptive--dwell-timer
          (run-with-idle-timer claude-code-adaptive-dwell-interval
                               t
                               #'claude-code-adaptive--dwell-tick))))

(defun claude-code-adaptive-teardown ()
  "Disable adaptive rendering tracking."
  (advice-remove 'magit-section-toggle
                 #'claude-code-adaptive--track-toggle)
  (when (fboundp 'claude-code-copy-code-block)
    (advice-remove 'claude-code-copy-code-block
                   #'claude-code-adaptive--track-copy))
  (when claude-code-adaptive--dwell-timer
    (cancel-timer claude-code-adaptive--dwell-timer)
    (setq claude-code-adaptive--dwell-timer nil)))

;; Auto-setup on load.
(claude-code-adaptive-setup)

(provide 'claude-code-adaptive)
;;; claude-code-adaptive.el ends here
