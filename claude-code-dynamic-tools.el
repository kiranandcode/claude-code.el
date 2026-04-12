;;; claude-code-dynamic-tools.el --- Agent-bootstrapped tool registry -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Kiran Shenoy
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Mid-session dynamic tool creation.  The agent can define an Emacs Lisp
;; function, register it as a named tool via the Python backend's
;; CreateDynamicTool MCP tool, and invoke it on subsequent turns via
;; CallDynamicTool.  This module provides the Emacs-side registry and UI
;; integration.
;;
;; Workflow (from the agent's perspective):
;;
;;   1. Use EvalEmacs to defun a new function, e.g.:
;;      (defun claude-code-dyn--query-org-agenda (args)
;;        "Return today's org-agenda as a string."
;;        (with-temp-buffer
;;          (org-agenda-list 1)
;;          (buffer-string)))
;;
;;   2. Call CreateDynamicTool:
;;      name: "query-org-agenda"
;;      description: "Query today's Org Agenda"
;;      elisp_function: "claude-code-dyn--query-org-agenda"
;;
;;   3. Call CallDynamicTool on subsequent turns:
;;      name: "query-org-agenda"
;;      args: {}
;;
;; The tool's capability set grows through the conversation.

;;; Code:

(require 'cl-lib)

;;;; Registry

(defvar claude-code-dynamic-tools--registry (make-hash-table :test #'equal)
  "Hash table mapping tool name (string) → plist.
Each plist has at least :elisp-function (string).")

(defun claude-code-dynamic-tools--register (name elisp-fn)
  "Register dynamic tool NAME backed by ELISP-FN.
Called from the Python backend after CreateDynamicTool succeeds."
  (puthash name (list :elisp-function elisp-fn
                      :created-at (current-time))
           claude-code-dynamic-tools--registry)
  (message "Dynamic tool registered: %s → %s" name elisp-fn)
  name)

(defun claude-code-dynamic-tools--list ()
  "Return an alist of (NAME . PLIST) for all registered dynamic tools."
  (let (result)
    (maphash (lambda (k v) (push (cons k v) result))
             claude-code-dynamic-tools--registry)
    (nreverse result)))

(defun claude-code-dynamic-tools--clear ()
  "Clear all dynamic tools.  Useful for session reset."
  (clrhash claude-code-dynamic-tools--registry))

;;;; Interactive commands

(defun claude-code-list-dynamic-tools ()
  "Display registered dynamic tools in a temporary buffer."
  (interactive)
  (let ((tools (claude-code-dynamic-tools--list)))
    (if (null tools)
        (message "No dynamic tools registered.")
      (with-current-buffer (get-buffer-create "*Claude Dynamic Tools*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Dynamic Tools (agent-created)\n")
          (insert (make-string 40 ?─) "\n\n")
          (dolist (entry tools)
            (let* ((name (car entry))
                   (plist (cdr entry))
                   (fn (plist-get plist :elisp-function))
                   (time (plist-get plist :created-at)))
              (insert (propertize name 'face 'font-lock-function-name-face))
              (insert " → " fn)
              (when time
                (insert (format "  (%s)" (format-time-string "%H:%M:%S" time))))
              (insert "\n")))
          (goto-char (point-min))
          (special-mode))
        (display-buffer (current-buffer))))))

(provide 'claude-code-dynamic-tools)
;;; claude-code-dynamic-tools.el ends here
