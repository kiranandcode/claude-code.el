;;; claude-code-project-notes.el --- Auto-update project notes -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Kiran Shenoy
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Automatically proposes updates to the project context notes based on
;; conversation outcomes.  After a session reaches a significant length
;; (configurable threshold), the agent is prompted to diff what it
;; learned against the existing project-context.org and propose
;; additions — new conventions discovered, bugs root-caused,
;; architectural decisions made.
;;
;; The agent writes its own memory.  Over time the project notes become
;; a living record authored jointly by developer and agent, not a
;; document the developer has to maintain manually.
;;
;; Trigger modes:
;;   - `on-idle': After N turns, propose on next idle (default).
;;   - `on-ask':  Only when the user runs M-x claude-code-update-project-notes.
;;   - `auto':    Silently apply updates without asking.

;;; Code:

(require 'cl-lib)

;;;; Customization

(defcustom claude-code-project-notes-auto-update 'on-ask
  "When to auto-update project notes from conversation outcomes.

  `on-idle' — After `claude-code-project-notes-turn-threshold' turns,
              propose updates on next idle.
  `on-ask'  — Only when the user explicitly runs
              `claude-code-update-project-notes'.
  `auto'    — Silently apply updates without confirmation."
  :type '(choice (const :tag "Propose on idle (after N turns)" on-idle)
                 (const :tag "Only on user request" on-ask)
                 (const :tag "Apply automatically" auto))
  :group 'claude-code)

(defcustom claude-code-project-notes-turn-threshold 8
  "Minimum conversation turns before auto-proposing project notes updates."
  :type 'integer
  :group 'claude-code)

;;;; State

(defvar-local claude-code-project-notes--proposed nil
  "Non-nil if we have already proposed notes for this session.")

(defvar-local claude-code-project-notes--turn-count 0
  "Count of result events (completed turns) in this session.")

;;;; Core: Extract learnings and propose updates

(defun claude-code-project-notes--summarize-conversation ()
  "Build a summary of the current conversation for notes extraction.
Returns a string with key facts from the conversation."
  (when (boundp 'claude-code--messages)
    (let ((msgs (reverse claude-code--messages))
          (parts nil)
          (turn 0))
      (dolist (msg msgs)
        (let ((type (alist-get 'type msg)))
          (pcase type
            ("user"
             (cl-incf turn)
             (let ((prompt (alist-get 'prompt msg)))
               (when (and prompt (> (length prompt) 0))
                 (push (format "Turn %d (user): %s"
                               turn
                               (truncate-string-to-width prompt 200))
                       parts))))
            ("assistant"
             (when-let ((content (alist-get 'content msg)))
               (when (vectorp content)
                 (seq-do
                  (lambda (block)
                    (when (equal (alist-get 'type block) "text")
                      (let ((text (alist-get 'text block)))
                        (when text
                          (push (format "Turn %d (assistant): %s"
                                        turn
                                        (truncate-string-to-width text 300))
                                parts)))))
                  content))))
            ("error"
             (push (format "Error: %s" (alist-get 'message msg)) parts)))))
      (when parts
        (mapconcat #'identity (nreverse parts) "\n")))))

(defun claude-code-project-notes--build-update-prompt ()
  "Build the prompt to send to the agent for notes update.
Returns nil if there is nothing meaningful to update."
  (let ((summary (claude-code-project-notes--summarize-conversation))
        (current-notes (when (fboundp 'claude-code--load-dir-notes)
                         (claude-code--load-dir-notes))))
    (when summary
      (format
       (concat
        "[PROJECT-NOTES-UPDATE] Please review this conversation and update "
        "the project context notes if you learned anything new.\n\n"
        "Current project notes:\n```org\n%s\n```\n\n"
        "Conversation summary (last %d turns):\n%s\n\n"
        "Instructions:\n"
        "1. Identify new conventions, architectural decisions, bug patterns, "
        "or workflow knowledge discovered in this conversation.\n"
        "2. If there is genuinely new information worth recording, edit the "
        "project notes file to add it.  Use the Edit tool.\n"
        "3. If nothing new was learned, just say 'No updates needed.'\n"
        "4. Do NOT remove existing notes.  Only add or refine.\n"
        "5. Keep additions concise — bullet points or short paragraphs.")
       (or current-notes "(no existing notes)")
       claude-code-project-notes--turn-count
       summary))))

;;;; Trigger

(defun claude-code-project-notes--maybe-propose ()
  "Check if we should propose a notes update and do so if appropriate."
  (when (and (not claude-code-project-notes--proposed)
             (>= claude-code-project-notes--turn-count
                 claude-code-project-notes-turn-threshold)
             (not (eq claude-code-project-notes-auto-update 'on-ask)))
    (setq claude-code-project-notes--proposed t)
    (when-let ((prompt (claude-code-project-notes--build-update-prompt)))
      (pcase claude-code-project-notes-auto-update
        ('on-idle
         ;; Show a message and let the user decide.
         (message "claude-code: %d turns completed — run M-x claude-code-update-project-notes to update project notes"
                  claude-code-project-notes--turn-count))
        ('auto
         ;; Send directly.
         (when (fboundp 'claude-code-send)
           (claude-code-send prompt)))))))

(defun claude-code-project-notes--on-result ()
  "Hook function called when a result event is received."
  (cl-incf claude-code-project-notes--turn-count)
  (claude-code-project-notes--maybe-propose))

;;;; Interactive command

(defun claude-code-update-project-notes ()
  "Prompt the agent to review the conversation and update project notes."
  (interactive)
  (unless (derived-mode-p 'claude-code-mode)
    (user-error "Not in a Claude Code buffer"))
  (let ((prompt (claude-code-project-notes--build-update-prompt)))
    (if prompt
        (progn
          (setq claude-code-project-notes--proposed t)
          (claude-code-send prompt))
      (message "No conversation to summarize."))))

;;;; Integration with events

(defun claude-code-project-notes-setup ()
  "Enable project notes auto-update in the current buffer.
Hooks into the result event handler."
  (add-hook 'claude-code-result-hook
            #'claude-code-project-notes--on-result nil t))

(defun claude-code-project-notes-teardown ()
  "Disable project notes auto-update."
  (remove-hook 'claude-code-result-hook
               #'claude-code-project-notes--on-result t))

(provide 'claude-code-project-notes)
;;; claude-code-project-notes.el ends here
