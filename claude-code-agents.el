;;; claude-code-agents.el --- Agent tracking and sidebar for claude-code.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Agent registry, tracking, and the treemacs-style agent sidebar.

;;; Code:

(require 'claude-code-vars)
(require 'magit-section)

;;;; Agent Tracking

(defvar claude-code--agents (make-hash-table :test 'equal)
  "Global registry of agents.  Maps agent-id to agent plist.
Agent plist keys:
  :id          - unique string (session directory or task_id)
  :type        - symbol: session or task
  :description - short description of current work
  :status      - symbol: starting, ready, working, completed, failed, stopped
  :buffer      - associated buffer (sessions only)
  :parent-id   - id of parent agent, nil for root sessions
  :children    - list of child agent ids
  :last-tool   - last tool name (tasks only)
  :summary     - completion summary (tasks only)
  :cwd         - working directory")

(defvar claude-code-agents-update-hook nil
  "Hook run after the agent registry changes.")

(defun claude-code--agent-register (id &rest props)
  "Register agent ID with PROPS in the global registry."
  (puthash id (append (list :id id) props) claude-code--agents)
  (run-hooks 'claude-code-agents-update-hook))

(defun claude-code--agent-update (id &rest props)
  "Update agent ID, merging PROPS into existing properties."
  (when-let ((agent (gethash id claude-code--agents)))
    (let ((p props))
      (while p
        (setq agent (plist-put agent (pop p) (pop p)))))
    (puthash id agent claude-code--agents)
    (run-hooks 'claude-code-agents-update-hook)))

(defun claude-code--agent-unregister (id)
  "Remove agent ID and all its children from the registry."
  (when-let ((agent (gethash id claude-code--agents)))
    (dolist (child-id (plist-get agent :children))
      (remhash child-id claude-code--agents))
    (when-let ((parent-id (plist-get agent :parent-id)))
      (when-let ((parent (gethash parent-id claude-code--agents)))
        (puthash parent-id
                 (plist-put parent :children
                            (delete id (plist-get parent :children)))
                 claude-code--agents)))
    (remhash id claude-code--agents)
    (run-hooks 'claude-code-agents-update-hook)))

(defun claude-code--agent-add-child (parent-id child-id)
  "Add CHILD-ID to PARENT-ID's children list."
  (when-let ((parent (gethash parent-id claude-code--agents)))
    (unless (member child-id (plist-get parent :children))
      (puthash parent-id
               (plist-put parent :children
                          (append (plist-get parent :children)
                                  (list child-id)))
               claude-code--agents))))

(defun claude-code--agent-root-p (agent)
  "Return non-nil if AGENT plist is a root (session) agent."
  (eq (plist-get agent :type) 'session))

(defun claude-code--agent-unregister-self ()
  "Unregister the agent for the current buffer.
Intended for use in `kill-buffer-hook' within `claude-code-mode' buffers."
  (let ((key (or claude-code--session-key claude-code--cwd)))
    (when key
      (claude-code--agent-unregister key)
      (when (eq (gethash claude-code--cwd claude-code--buffers) (current-buffer))
        (remhash claude-code--cwd claude-code--buffers)))))

(defun claude-code--agent-root-ids ()
  "Return a list of root agent IDs."
  (let (roots)
    (maphash (lambda (id agent)
               (when (claude-code--agent-root-p agent)
                 (push id roots)))
             claude-code--agents)
    (nreverse roots)))

;;;; Agent Sidebar

(defface claude-code-agent-session
  '((t :inherit font-lock-function-name-face :weight bold))
  "Session (root) agent name in the sidebar."
  :group 'claude-code)

(defface claude-code-agent-task
  '((t :inherit font-lock-variable-name-face))
  "Task (sub) agent name in the sidebar."
  :group 'claude-code)

(defface claude-code-agent-status-working
  '((t :inherit warning))
  "Working status indicator."
  :group 'claude-code)

(defface claude-code-agent-status-completed
  '((t :inherit success))
  "Completed status indicator."
  :group 'claude-code)

(defface claude-code-agent-status-failed
  '((t :inherit error))
  "Failed status indicator."
  :group 'claude-code)

(defun claude-code--agents-status-face (status)
  "Return the face for STATUS symbol."
  (pcase status
    ('working   'claude-code-agent-status-working)
    ('completed 'claude-code-agent-status-completed)
    ('failed    'claude-code-agent-status-failed)
    (_          'shadow)))

(defun claude-code--agents-status-icon (status)
  "Return a status icon for STATUS symbol."
  (pcase status
    ('starting  "◇")
    ('ready     "●")
    ('working   "⠹")
    ('completed "✓")
    ('failed    "✗")
    ('stopped   "■")
    (_          "?")))

(defvar claude-code--agents-render-timer nil
  "Timer for debounced sidebar renders.")

(defun claude-code--agents-schedule-render ()
  "Schedule a debounced re-render of the agent sidebar."
  (when-let ((buf (get-buffer "*Claude Agents*")))
    (when (buffer-live-p buf)
      (when claude-code--agents-render-timer
        (cancel-timer claude-code--agents-render-timer))
      (setq claude-code--agents-render-timer
            (run-at-time 0.05 nil #'claude-code--agents-do-render)))))

(defun claude-code--agents-do-render ()
  "Render the agent sidebar buffer."
  (when-let ((buf (get-buffer "*Claude Agents*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (old-point (point)))
          (erase-buffer)
          (magit-insert-section (agents-root)
            (insert (propertize "Claude Agents" 'face 'claude-code-header))
            (insert "\n")
            (insert (propertize (make-string 38 ?─) 'face 'claude-code-separator))
            (insert "\n\n")
            (let ((live-roots
                   ;; Omit root agents whose buffers have since been killed
                   ;; without going through `claude-code-kill'.
                   (seq-filter
                    (lambda (id)
                      (when-let ((a (gethash id claude-code--agents)))
                        (let ((buf (plist-get a :buffer)))
                          (or (null buf) (buffer-live-p buf)))))
                    (claude-code--agent-root-ids))))
              (if (null live-roots)
                  (insert (propertize "  No active sessions\n" 'face 'shadow))
                (dolist (root-id live-roots)
                  (claude-code--agents-render-root root-id)))))
          (goto-char (min old-point (point-max))))))))

(defun claude-code--agents-render-root (agent-id)
  "Render a root session agent AGENT-ID and its children."
  (when-let ((agent (gethash agent-id claude-code--agents)))
    (let* ((status (plist-get agent :status))
           (desc (plist-get agent :description))
           (children (plist-get agent :children))
           (icon (claude-code--agents-status-icon status))
           (sface (claude-code--agents-status-face status)))
      (magit-insert-section (claude-agent agent-id nil)
        (magit-insert-heading
          (concat (propertize icon 'face sface)
                  " "
                  (propertize (abbreviate-file-name agent-id)
                              'face 'claude-code-agent-session)
                  "  "
                  (propertize (format "[%s]" status) 'face sface)))
        (when desc
          (insert (propertize
                   (format "  %s\n"
                           (truncate-string-to-width desc 36))
                   'face 'shadow)))
        (when children
          (let ((last-idx (1- (length children))))
            (cl-loop for child-id in children
                     for idx from 0
                     do (claude-code--agents-render-child
                         child-id (= idx last-idx)))))
        (insert "\n")))))

(defun claude-code--agents-render-child (agent-id is-last)
  "Render a child task agent AGENT-ID.
IS-LAST is non-nil if this is the last sibling."
  (when-let ((agent (gethash agent-id claude-code--agents)))
    (let* ((status (plist-get agent :status))
           (desc (plist-get agent :description))
           (icon (claude-code--agents-status-icon status))
           (sface (claude-code--agents-status-face status))
           (branch (if is-last "└" "├"))
           (cont   (if is-last " " "│")))
      (magit-insert-section (claude-agent agent-id t)
        (magit-insert-heading
          (concat (propertize (format "  %s " branch) 'face 'shadow)
                  (propertize icon 'face sface)
                  " "
                  (propertize (or desc "task")
                              'face 'claude-code-agent-task)
                  "  "
                  (propertize (format "[%s]" status) 'face sface)))
        (when-let ((tool (plist-get agent :last-tool)))
          (insert (propertize (format "  %s   ⚙ %s\n" cont tool)
                              'face 'shadow)))
        (when-let ((summary (plist-get agent :summary)))
          (insert (propertize
                   (format "  %s   %s\n" cont
                           (truncate-string-to-width summary 32))
                   'face 'shadow)))))))

(defvar-keymap claude-code-agents-mode-map
  :doc "Keymap for the Claude agent sidebar."
  :parent magit-section-mode-map
  "RET" #'claude-code-agents-goto
  "k"   #'claude-code-agents-kill-at-point
  "q"   #'claude-code-agents-quit
  "g"   #'claude-code-agents-refresh)

(define-derived-mode claude-code-agents-mode magit-section-mode "Agents"
  "Major mode for the Claude agent sidebar.
\\{claude-code-agents-mode-map}"
  :group 'claude-code
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (setq-local cursor-type 'bar)
  (add-hook 'claude-code-agents-update-hook
            #'claude-code--agents-schedule-render))

(defun claude-code-agents-goto ()
  "Jump to the conversation buffer for the agent at point."
  (interactive)
  (when-let ((section (magit-current-section)))
    (when-let ((agent-id (oref section value)))
      (when-let ((agent (gethash agent-id claude-code--agents)))
        (let* ((is-root (claude-code--agent-root-p agent))
               (buf (if is-root
                        (plist-get agent :buffer)
                      (when-let ((parent (gethash (plist-get agent :parent-id)
                                                  claude-code--agents)))
                        (plist-get parent :buffer)))))
          (if (and buf (buffer-live-p buf))
              (pop-to-buffer buf)
            ;; Buffer is gone — offer to remove the stale entry.
            (when (yes-or-no-p
                   (format "Buffer for \"%s\" no longer exists. Remove it from the panel? "
                           (or (plist-get agent :description) agent-id)))
              (claude-code--agent-unregister
               (if is-root agent-id (plist-get agent :parent-id))))))))))

(defun claude-code-agents-quit ()
  "Close the agent sidebar window."
  (interactive)
  (quit-window))

(defun claude-code-agents-refresh ()
  "Force re-render the agent sidebar."
  (interactive)
  (claude-code--agents-do-render))

(defun claude-code-agents-kill-at-point ()
  "Kill the agent at point after confirmation.
For session agents, stops the process and kills the buffer.
For task agents, sends a cancel signal via the parent session."
  (interactive)
  (when-let ((section (magit-current-section)))
    (when-let ((agent-id (oref section value)))
      (when-let ((agent (gethash agent-id claude-code--agents)))
        (let* ((desc (or (plist-get agent :description) agent-id))
               (type (plist-get agent :type)))
          (when (yes-or-no-p (format "Kill agent \"%s\"? " desc))
            (pcase type
              ('session
               (when-let ((buf (plist-get agent :buffer)))
                 (when (buffer-live-p buf)
                   (with-current-buffer buf
                     (claude-code-kill)))))
              ('task
               ;; Tasks run inside the parent session; cancel via parent.
               (let ((parent-id (plist-get agent :parent-id)))
                 (if-let ((parent (and parent-id
                                       (gethash parent-id claude-code--agents)))
                           (buf (plist-get parent :buffer)))
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (claude-code-cancel)))
                   ;; No live parent — just remove from registry.
                   (claude-code--agent-unregister agent-id))))
              (_
               (claude-code--agent-unregister agent-id)))))))))

;;;###autoload
(defun claude-code-agents-capture-to-org (file)
  "Capture the current agent tree summary to an org FILE.
Intended to be called via `emacsclient -e' from a skill or hook:
  emacsclient -e \\='(claude-code-agents-capture-to-org \"~/org/inbox.org\")\\='"
  (interactive (list (read-file-name "Capture to org file: "
                                     "~/org/" nil nil "inbox.org")))
  (let ((entries
         (let (result)
           (maphash
            (lambda (_id agent)
              (when (claude-code--agent-root-p agent)
                (push (format "** [%s] %s  :%s:\n   %s\n"
                              (format-time-string "%Y-%m-%d %H:%M")
                              (or (plist-get agent :description) "Claude session")
                              (plist-get agent :status)
                              (or (plist-get agent :summary) ""))
                      result)))
            claude-code--agents)
           result)))
    (with-current-buffer (find-file-noselect (expand-file-name file))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "* Claude Agent Capture  %s\n"
                      (format-time-string "[%Y-%m-%d %a %H:%M]")))
      (dolist (e entries)
        (insert e))
      (save-buffer)
      (message "Captured %d agent(s) to %s" (length entries) file))))

;;;###autoload
(defun claude-code-agents ()
  "Open the agent sidebar."
  (interactive)
  (let ((buf (get-buffer-create "*Claude Agents*")))
    (with-current-buffer buf
      (unless (eq major-mode 'claude-code-agents-mode)
        (claude-code-agents-mode)))
    (claude-code--agents-do-render)
    (display-buffer-in-side-window
     buf `((side . left)
            (window-width . ,claude-code-agents-sidebar-width)
            (slot . -1)
            (window-parameters . ((no-delete-other-windows . t)))))))

;;;###autoload
(defun claude-code-agents-toggle ()
  "Toggle the agent sidebar window."
  (interactive)
  (if-let ((buf (get-buffer "*Claude Agents*"))
           (win (get-buffer-window buf)))
      (delete-window win)
    (claude-code-agents)))

(provide 'claude-code-agents)
;;; claude-code-agents.el ends here
