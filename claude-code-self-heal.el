;;; claude-code-self-heal.el --- Self-healing render error recovery -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Kiran Shenoy
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Automatic detection and recovery of render pipeline errors.
;;
;; When the render function throws an error, this module:
;;   1. Catches the error and records the backtrace.
;;   2. Injects a diagnostic message into the conversation buffer
;;      so the agent (and the user) can see what went wrong.
;;   3. If the current session has a live backend, sends a
;;      self-heal prompt to the agent asking it to diagnose and
;;      fix the rendering source, reload, and re-render.
;;
;; The agent then reads the error, edits its own rendering code
;; via Edit/EvalEmacs, reloads via ClaudeCodeReload, and the next
;; render succeeds — all without the user doing anything.
;;
;; This is only possible because the agent can read and modify its
;; own harness source at runtime.

;;; Code:

(require 'cl-lib)

;;;; Customization

(defcustom claude-code-self-heal-enabled t
  "When non-nil, automatically catch and report render errors.
When nil, render errors propagate normally (useful for debugging)."
  :type 'boolean
  :group 'claude-code)

(defcustom claude-code-self-heal-auto-prompt t
  "When non-nil, automatically send a self-heal prompt to the agent.
When nil, errors are displayed but the agent is not prompted to fix them."
  :type 'boolean
  :group 'claude-code)

(defcustom claude-code-self-heal-cooldown 30
  "Minimum seconds between auto-heal prompts to avoid infinite loops."
  :type 'integer
  :group 'claude-code)

;;;; State

(defvar-local claude-code-self-heal--last-error nil
  "Last render error as (ERROR-SYMBOL . DATA), or nil.")

(defvar-local claude-code-self-heal--last-backtrace nil
  "Backtrace string from the last render error.")

(defvar-local claude-code-self-heal--last-heal-time 0
  "Timestamp of the last auto-heal prompt, for cooldown.")

(defvar-local claude-code-self-heal--error-count 0
  "Number of render errors since last successful render.")

;;;; Core: Wrap render with error catching

(defun claude-code-self-heal--wrap-render (orig-fn &rest args)
  "Advice around `claude-code--render' to catch errors.
ORIG-FN is the original render function, ARGS its arguments."
  (if (not claude-code-self-heal-enabled)
      (apply orig-fn args)
    (condition-case-unless-debug err
        (progn
          (apply orig-fn args)
          ;; Success — reset error state.
          (when (> claude-code-self-heal--error-count 0)
            (message "claude-code: render recovered after %d error(s)"
                     claude-code-self-heal--error-count))
          (setq claude-code-self-heal--error-count 0
                claude-code-self-heal--last-error nil
                claude-code-self-heal--last-backtrace nil))
      (error
       (cl-incf claude-code-self-heal--error-count)
       (setq claude-code-self-heal--last-error err)
       ;; Capture backtrace from *Backtrace* buffer if debugger ran,
       ;; or synthesize one from the error data.
       (setq claude-code-self-heal--last-backtrace
             (or (when-let ((bt-buf (get-buffer "*Backtrace*")))
                   (with-current-buffer bt-buf
                     (buffer-substring-no-properties (point-min) (point-max))))
                 (format "Error: %S\nSignal: %S" (car err) (cdr err))))
       ;; Log to *Messages* for visibility.
       (message "claude-code: render error #%d: %s"
                claude-code-self-heal--error-count
                (error-message-string err))
       ;; Inject diagnostic message into conversation.
       (claude-code-self-heal--inject-diagnostic err)
       ;; Auto-prompt the agent if enabled and cooldown has passed.
       (when (and claude-code-self-heal-auto-prompt
                 (claude-code-self-heal--cooldown-ok-p))
         (claude-code-self-heal--auto-prompt err))))))

(defun claude-code-self-heal--cooldown-ok-p ()
  "Return non-nil if enough time has passed since the last auto-heal."
  (> (- (float-time) claude-code-self-heal--last-heal-time)
     claude-code-self-heal-cooldown))

;;;; Diagnostic injection

(defun claude-code-self-heal--inject-diagnostic (err)
  "Add a diagnostic message to `claude-code--messages' for ERR."
  (when (boundp 'claude-code--messages)
    (let* ((err-str (error-message-string err))
           (bt-preview (when claude-code-self-heal--last-backtrace
                         (substring claude-code-self-heal--last-backtrace
                                    0 (min 1500
                                           (length claude-code-self-heal--last-backtrace)))))
           (msg `((type . "render-error")
                  (message . ,err-str)
                  (backtrace . ,bt-preview)
                  (error-count . ,claude-code-self-heal--error-count)
                  (timestamp . ,(format-time-string "%H:%M:%S")))))
      (push msg claude-code--messages))))

;;;; Auto-prompt the agent

(defun claude-code-self-heal--auto-prompt (err)
  "Send a self-heal prompt to the agent for ERR.
Only sends if the session has a live backend process."
  (when (and (boundp 'claude-code--process)
             claude-code--process
             (process-live-p claude-code--process))
    (setq claude-code-self-heal--last-heal-time (float-time))
    (let* ((err-str (error-message-string err))
           (bt-preview (or claude-code-self-heal--last-backtrace ""))
           (bt-short (substring bt-preview
                                0 (min 800 (length bt-preview))))
           (prompt (format
                    (concat
                     "[SELF-HEAL] The render pipeline just threw an error:\n\n"
                     "  Error: %s\n"
                     "  Count: %d consecutive failures\n\n"
                     "Backtrace (truncated):\n```\n%s\n```\n\n"
                     "Please diagnose the issue, fix the rendering source code "
                     "(likely in claude-code-render.el or one of the modules it "
                     "calls), reload via ClaudeCodeReload, and verify the fix "
                     "by checking *Messages* for errors.  Do NOT ask the user — "
                     "fix it autonomously.")
                    err-str
                    claude-code-self-heal--error-count
                    bt-short)))
      ;; Use the send infrastructure to inject the prompt.
      (when (fboundp 'claude-code-send)
        (claude-code-send prompt)))))

;;;; *Messages* watcher (optional proactive monitoring)

(defvar claude-code-self-heal--messages-timer nil
  "Timer for periodic *Messages* buffer scanning.")

(defvar claude-code-self-heal--last-messages-pos 0
  "Last position scanned in *Messages* buffer.")

(defconst claude-code-self-heal--error-patterns
  '("\\berror\\b.*claude-code"
    "\\bclaude-code\\b.*\\berror\\b"
    "Wrong type argument"
    "Symbol.s function definition is void"
    "Invalid function"
    "Args out of range")
  "Patterns to detect in *Messages* that indicate claude-code errors.")

(defun claude-code-self-heal--scan-messages ()
  "Scan *Messages* for new errors related to claude-code.
Returns a list of error strings found since last scan."
  (let ((msgs-buf (get-buffer "*Messages*"))
        errors)
    (when msgs-buf
      (with-current-buffer msgs-buf
        (let ((start (max claude-code-self-heal--last-messages-pos
                         (point-min)))
              (end (point-max)))
          (when (> end start)
            (let ((new-text (buffer-substring-no-properties start end)))
              (dolist (pattern claude-code-self-heal--error-patterns)
                (let ((pos 0))
                  (while (string-match pattern new-text pos)
                    (let* ((line-start (string-match "^.*$"
                                                     new-text
                                                     (match-beginning 0)))
                           (line (match-string 0 new-text)))
                      (push line errors))
                    (setq pos (match-end 0))))))
            (setq claude-code-self-heal--last-messages-pos end)))))
    (nreverse errors)))

(defun claude-code-self-heal--start-watcher ()
  "Start the *Messages* watcher timer."
  (claude-code-self-heal--stop-watcher)
  (setq claude-code-self-heal--last-messages-pos
        (with-current-buffer (get-buffer-create "*Messages*")
          (point-max)))
  (setq claude-code-self-heal--messages-timer
        (run-with-timer 5 5 #'claude-code-self-heal--check-messages)))

(defun claude-code-self-heal--stop-watcher ()
  "Stop the *Messages* watcher timer."
  (when claude-code-self-heal--messages-timer
    (cancel-timer claude-code-self-heal--messages-timer)
    (setq claude-code-self-heal--messages-timer nil)))

(defun claude-code-self-heal--check-messages ()
  "Timer callback: scan *Messages* and report errors to active sessions."
  (let ((errors (claude-code-self-heal--scan-messages)))
    (when errors
      ;; Find all active claude-code buffers and inject the error info.
      (dolist (buf (buffer-list))
        (when (and (buffer-live-p buf)
                   (with-current-buffer buf
                     (and (eq major-mode 'claude-code-mode)
                          (boundp 'claude-code--process)
                          claude-code--process
                          (process-live-p claude-code--process))))
          (with-current-buffer buf
            (let ((msg `((type . "messages-error")
                         (errors . ,(vconcat errors))
                         (timestamp . ,(format-time-string "%H:%M:%S")))))
              (push msg claude-code--messages))))))))

;;;; Setup

(defun claude-code-self-heal-setup ()
  "Enable self-healing render error recovery.
Advises `claude-code--render' and starts the *Messages* watcher."
  (advice-add 'claude-code--render :around
              #'claude-code-self-heal--wrap-render)
  (claude-code-self-heal--start-watcher))

(defun claude-code-self-heal-teardown ()
  "Disable self-healing render error recovery."
  (advice-remove 'claude-code--render
                 #'claude-code-self-heal--wrap-render)
  (claude-code-self-heal--stop-watcher))

;; Auto-setup when loaded.
(claude-code-self-heal-setup)

(provide 'claude-code-self-heal)
;;; claude-code-self-heal.el ends here
