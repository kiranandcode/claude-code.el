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
                 claude-code--agents)
        ;; Re-render the parent session buffer so its Spawned Agents panel
        ;; reflects the removal immediately.
        (when-let ((parent-buf (plist-get parent :buffer)))
          (when (buffer-live-p parent-buf)
            (with-current-buffer parent-buf
              (claude-code--schedule-render))))))
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
  "Return non-nil if AGENT plist is a root (top-level session) agent."
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
                   ;; Only show sessions that have a live buffer OR have child
                   ;; tasks registered.  Sessions with a nil or killed buffer
                   ;; and no children are ghost entries (stale forks, background
                   ;; sidechains without a buffer) and we suppress them.
                   (seq-filter
                    (lambda (id)
                      (when-let ((a (gethash id claude-code--agents)))
                        (let ((buf (plist-get a :buffer)))
                          (or (and buf (buffer-live-p buf))
                              (plist-get a :children)))))
                    (claude-code--agent-root-ids))))
              (if (null live-roots)
                  (insert (propertize "  No active sessions\n" 'face 'shadow))
                (dolist (root-id live-roots)
                  (claude-code--agents-render-root root-id)))))
          (goto-char (min old-point (point-max))))))))

(defun claude-code--agents-fold-indicator (section)
  "Return a fold indicator string for SECTION.
Shows ▾ when expanded (or no children), ▸ when collapsed."
  (if (and section (oref section hidden)) "▸" "▾"))

(defun claude-code--agents-render-root (agent-id)
  "Render a root session agent AGENT-ID and its children."
  (when-let ((agent (gethash agent-id claude-code--agents)))
    (let* ((status (plist-get agent :status))
           (desc (plist-get agent :description))
           (children (plist-get agent :children))
           (buf (plist-get agent :buffer))
           (buf-name (when (and buf (buffer-live-p buf)) (buffer-name buf)))
           (icon (claude-code--agents-status-icon status))
           (sface (claude-code--agents-status-face status))
           (has-children (not (null children))))
      (magit-insert-section section (claude-agent agent-id nil)
        (magit-insert-heading
          (propertize
           (concat (propertize
                    (if has-children
                        (concat (claude-code--agents-fold-indicator section) " ")
                      "  ")
                    'face 'shadow)
                   (propertize icon 'face sface)
                   " "
                   (propertize (abbreviate-file-name agent-id)
                               'face 'claude-code-agent-session)
                   "  "
                   (propertize (format "[%s]" status) 'face sface))
           'mouse-face 'highlight))
        (when desc
          (insert (propertize
                   (format "   %s\n"
                           (truncate-string-to-width desc 36))
                   'face 'shadow)))
        (when buf-name
          (insert (propertize
                   (format "   ⎘ %s\n"
                           (truncate-string-to-width buf-name 36))
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
           (buf (plist-get agent :buffer))
           (buf-name (when (and buf (buffer-live-p buf)) (buffer-name buf)))
           (icon (claude-code--agents-status-icon status))
           (sface (claude-code--agents-status-face status))
           (branch (if is-last "└" "├"))
           (cont   (if is-last " " "│")))
      (magit-insert-section (claude-agent agent-id t)
        (magit-insert-heading
          (propertize
           (concat (propertize (format "  %s─ " branch) 'face 'shadow)
                   (propertize icon 'face sface)
                   " "
                   (propertize (or desc "task")
                               'face 'claude-code-agent-task)
                   "  "
                   (propertize (format "[%s]" status) 'face sface))
           'mouse-face 'highlight))
        (when buf-name
          (insert (propertize (format "  %s    ⎘ %s\n" cont
                                      (truncate-string-to-width buf-name 30))
                              'face 'shadow)))
        (when-let ((tool (plist-get agent :last-tool)))
          (insert (propertize (format "  %s    ⚙ %s\n" cont tool)
                              'face 'shadow)))
        (when-let ((summary (plist-get agent :summary)))
          (insert (propertize
                   (format "  %s    %s\n" cont
                           (truncate-string-to-width summary 32))
                   'face 'shadow)))))))

(defvar-keymap claude-code-agents-mode-map
  :doc "Keymap for the Claude agent sidebar."
  :parent magit-section-mode-map)

;; Use keymap-set (not defvar-keymap literals) so bindings are always
;; re-applied when the file is reloaded, mutating the existing map object
;; in-place rather than creating a fresh one.  This ensures any live buffer
;; that holds a reference to the same keymap picks up the changes immediately.
(keymap-set claude-code-agents-mode-map "RET"            #'claude-code-agents-goto)
(keymap-set claude-code-agents-mode-map "k"              #'claude-code-agents-kill-at-point)
(keymap-set claude-code-agents-mode-map "q"              #'claude-code-agents-quit)
(keymap-set claude-code-agents-mode-map "g"              #'claude-code-agents-refresh)
(keymap-set claude-code-agents-mode-map "<tab>"          #'claude-code-agents-toggle-or-goto)
(keymap-set claude-code-agents-mode-map "<mouse-1>"      #'claude-code-agents-goto-mouse)
(keymap-set claude-code-agents-mode-map "<double-mouse-1>" #'claude-code-agents-goto-mouse)

(define-derived-mode claude-code-agents-mode magit-section-mode "Agents"
  "Major mode for the Claude agent sidebar.
\\{claude-code-agents-mode-map}"
  :group 'claude-code
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (setq-local cursor-type 'bar)
  (hl-line-mode 1)
  (add-hook 'claude-code-agents-update-hook
            #'claude-code--agents-schedule-render))

(defun claude-code-agents-goto ()
  "Jump to the buffer for the agent at point.
For session agents jumps to the conversation buffer.
For task agents jumps to the task progress buffer; if that is gone,
falls back to the parent session buffer."
  (interactive)
  (when-let ((section (magit-current-section)))
    (when-let ((agent-id (oref section value)))
      (when-let ((agent (gethash agent-id claude-code--agents)))
        (let* ((is-root (claude-code--agent-root-p agent))
               ;; For tasks: prefer own task buffer, fall back to parent session.
               (buf (if is-root
                        (plist-get agent :buffer)
                      (let ((own (plist-get agent :buffer)))
                        (if (and own (buffer-live-p own))
                            own
                          (when-let ((parent (gethash (plist-get agent :parent-id)
                                                      claude-code--agents)))
                            (plist-get parent :buffer)))))))
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

(defun claude-code-agents-goto-mouse (event)
  "Navigate to the agent at the mouse click position."
  (interactive "e")
  (mouse-set-point event)
  (claude-code-agents-goto))

(defun claude-code-agents-toggle-or-goto ()
  "On a session (root) node collapse/expand it; on a task navigate to it."
  (interactive)
  (when-let ((section (magit-current-section)))
    (if (and (oref section value)
             (when-let ((agent (gethash (oref section value) claude-code--agents)))
               (claude-code--agent-root-p agent)))
        (magit-section-toggle section)
      (claude-code-agents-goto))))

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
          (when (yes-or-no-p
                 (if (eq type 'task)
                     (format "Cancel task \"%s\"? (cancels the whole parent session) " desc)
                   (format "Kill session \"%s\"? " desc)))
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

;;;; Task Buffers

(defvar-local claude-code--task-id nil
  "Task ID for this task buffer.")

(defvar-local claude-code--task-parent-buffer nil
  "Parent session buffer for this task buffer.")

(defvar-local claude-code--task-last-tool nil
  "Last tool name appended to this task buffer (used to deduplicate).")

(defvar-keymap claude-code-task-mode-map
  :doc "Keymap for Claude subagent task progress buffers."
  "q"       #'quit-window
  "c"       #'claude-code-task-cancel
  "C-c C-c" #'claude-code-task-cancel)

(define-derived-mode claude-code-task-mode special-mode "Claude-Task"
  "Major mode for Claude subagent task progress buffers.
\\{claude-code-task-mode-map}"
  :group 'claude-code
  (setq-local truncate-lines nil))

(defun claude-code-task-cancel ()
  "Cancel the parent session that spawned this task.
Since tasks run inside a single SDK query, cancelling them cancels the
whole parent session query — there is no per-task interrupt in the SDK."
  (interactive)
  (if (and claude-code--task-parent-buffer
           (buffer-live-p claude-code--task-parent-buffer))
      (with-current-buffer claude-code--task-parent-buffer
        (claude-code-cancel)
        (message "Cancelling parent session…"))
    (message "Parent session buffer is gone — nothing to cancel")))

(defun claude-code--task-buffer-create (task-id desc parent-buf)
  "Create and return a task progress buffer for TASK-ID with DESC.
PARENT-BUF is the parent session buffer."
  (let* ((short-desc (truncate-string-to-width (or desc task-id) 45))
         (name (format "*Claude Task: %s*" short-desc))
         (buf (generate-new-buffer name)))
    (with-current-buffer buf
      (claude-code-task-mode)
      (setq-local claude-code--task-id task-id)
      (setq-local claude-code--task-parent-buffer parent-buf)
      (let ((inhibit-read-only t))
        (insert (propertize "Claude Subagent" 'face 'claude-code-header))
        (insert "\n")
        (insert (propertize (make-string 50 ?─) 'face 'claude-code-separator))
        (insert "\n")
        (when desc
          (insert (propertize (format "  %s\n" desc) 'face 'bold)))
        (insert (propertize "  ⠹ working…  " 'face 'claude-code-agent-status-working))
        (insert-button "[Cancel]"
                       'action (lambda (_btn)
                                 (claude-code-task-cancel))
                       'face 'warning
                       'follow-link t
                       'help-echo "Cancel the parent session")
        (insert "\n")
        (insert (propertize (make-string 50 ?─) 'face 'claude-code-separator))
        (insert "\n\n")))
    buf))

(defun claude-code--task-buffer-append-tool (buf tool-name)
  "Append TOOL-NAME as a step to task BUF, deduplicating consecutive identical calls."
  (when (and buf (buffer-live-p buf))
    (with-current-buffer buf
      (unless (equal tool-name claude-code--task-last-tool)
        (setq claude-code--task-last-tool tool-name)
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (propertize (format "  ⚙ %s\n" tool-name)
                              'face 'claude-code-tool-name)))))))

(defun claude-code--task-buffer-finalize (buf status summary)
  "Mark task BUF as done with STATUS symbol string and SUMMARY text."
  (when (and buf (buffer-live-p buf))
    (with-current-buffer buf
      (let* ((inhibit-read-only t)
             (sym (intern (or status "completed")))
             (icon (claude-code--agents-status-icon sym))
             (face (claude-code--agents-status-face sym)))
        ;; Replace the "working…" status line in the header
        (save-excursion
          (goto-char (point-min))
          (when (re-search-forward "  ⠹ working…" nil t)
            (replace-match
             (propertize (format "  %s %s" icon status) 'face face))))
        ;; Append a summary footer
        (goto-char (point-max))
        (insert "\n")
        (insert (propertize (make-string 50 ?─) 'face 'claude-code-separator))
        (insert "\n")
        (insert (propertize
                 (format "  %s %s\n" icon (or summary "Done."))
                 'face face))))))

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
