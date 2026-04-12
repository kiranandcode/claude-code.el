;;; claude-code-fork-tree.el --- Fork tree visualisation for claude-code.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Visual DAG of conversation forks.  Shows the parent–child relationship
;; between sessions so the user can see which branch they are on and jump
;; between them.

;;; Code:

(require 'claude-code-vars)
(require 'claude-code-agents)
(require 'magit-section)

;;;; Faces

(defface claude-code-fork-tree-current
  '((t :inherit success :weight bold))
  "Indicator for the currently active session in the fork tree."
  :group 'claude-code)

(defface claude-code-fork-tree-branch
  '((t :inherit shadow))
  "Box-drawing branch lines in the fork tree."
  :group 'claude-code)

;;;; Buffer-local state

(defvar-local claude-code-fork-tree--current-key nil
  "Agent key of the session that invoked the fork tree.
Used to highlight the current branch with a ◀ marker.")

(defvar claude-code-fork-tree--render-timer nil
  "Timer for debounced fork tree renders.")

;;;; Tree traversal helpers

(defun claude-code-fork-tree--find-root (agent-id)
  "Walk `:parent-id' links from AGENT-ID up to the root.
Returns the root agent ID."
  (let ((id agent-id))
    (while (when-let ((agent (gethash id claude-code--agents)))
             (when-let ((parent (plist-get agent :parent-id)))
               (setq id parent))))
    id))

(defun claude-code-fork-tree--has-forks-p (agent-id)
  "Return non-nil if AGENT-ID has any fork children (recursively).
Tasks (non-fork children) are ignored; only `:fork-point' children count."
  (when-let ((agent (gethash agent-id claude-code--agents)))
    (cl-some (lambda (child-id)
               (when-let ((child (gethash child-id claude-code--agents)))
                 (plist-get child :fork-point)))
             (plist-get agent :children))))

(defun claude-code-fork-tree--fork-children (agent-id)
  "Return fork-only children of AGENT-ID (filtering out tasks)."
  (when-let ((agent (gethash agent-id claude-code--agents)))
    (seq-filter (lambda (child-id)
                  (when-let ((child (gethash child-id claude-code--agents)))
                    (plist-get child :fork-point)))
                (plist-get agent :children))))

;;;; Rendering

(defun claude-code-fork-tree--schedule-render ()
  "Schedule a debounced re-render of the fork tree."
  (when-let ((buf (get-buffer "*Claude Fork Tree*")))
    (when (buffer-live-p buf)
      (when claude-code-fork-tree--render-timer
        (cancel-timer claude-code-fork-tree--render-timer))
      (setq claude-code-fork-tree--render-timer
            (run-at-time 0.05 nil #'claude-code-fork-tree--do-render)))))

(defun claude-code-fork-tree--do-render ()
  "Render the fork tree buffer."
  (when-let ((buf (get-buffer "*Claude Fork Tree*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (old-point (point))
              (current-key claude-code-fork-tree--current-key))
          (erase-buffer)
          (magit-insert-section (fork-tree-root)
            (insert (propertize "Fork Tree" 'face 'claude-code-header))
            (insert "\n")
            (insert (propertize (make-string 42 ?─) 'face 'claude-code-separator))
            (insert "\n\n")
            ;; Determine which roots to show.
            ;; If we have a current-key, find its root and show that tree.
            ;; Otherwise show all roots that have fork children.
            (let* ((focus-root (when current-key
                                 (claude-code-fork-tree--find-root current-key)))
                   (roots (if focus-root
                              (list focus-root)
                            ;; Show all roots with forks
                            (seq-filter
                             #'claude-code-fork-tree--has-forks-p
                             (seq-filter
                              (lambda (id)
                                (when-let ((a (gethash id claude-code--agents)))
                                  (let ((b (plist-get a :buffer)))
                                    (or (and b (buffer-live-p b))
                                        (plist-get a :children)))))
                              (claude-code--agent-root-ids))))))
              (if (null roots)
                  (insert (propertize "  No conversation forks yet.\n\n"
                                      'face 'shadow)
                          (propertize "  Use " 'face 'shadow)
                          (propertize "f" 'face 'font-lock-keyword-face)
                          (propertize " on a " 'face 'shadow)
                          (propertize "▶ You" 'face 'claude-code-user-label)
                          (propertize " message to create a fork.\n" 'face 'shadow))
                (dolist (root-id roots)
                  (claude-code-fork-tree--render-node
                   root-id 0 nil current-key)
                  (insert "\n")))))
          (goto-char (min old-point (point-max))))))))

(defun claude-code-fork-tree--render-node (agent-id depth ancestors current-key)
  "Render AGENT-ID as a fork tree node.
DEPTH is the nesting level (0 for root).
ANCESTORS is a list of booleans (newest-first) where t means the
ancestor at that level was the last sibling (so draw space not │).
CURRENT-KEY is the agent-id to highlight with ◀."
  (when-let ((agent (gethash agent-id claude-code--agents)))
    (let* ((status      (plist-get agent :status))
           (desc        (plist-get agent :description))
           (fork-point  (plist-get agent :fork-point))
           (buf         (plist-get agent :buffer))
           (buf-live    (and buf (buffer-live-p buf)))
           (is-current  (and current-key (equal agent-id current-key)))
           (icon        (claude-code--agents-status-icon status))
           (sface       (claude-code--agents-status-face status))
           (fork-kids   (claude-code-fork-tree--fork-children agent-id))
           ;; Build the prefix from ancestors
           (prefix      (claude-code-fork-tree--prefix ancestors)))
      (magit-insert-section section (claude-agent agent-id nil)
        (magit-insert-heading
          (propertize
           (concat
            ;; Tree branch prefix
            (propertize prefix 'face 'claude-code-fork-tree-branch)
            ;; Fold indicator for nodes with fork children
            (if fork-kids
                (propertize
                 (concat (if (oref section hidden) "▸" "▾") " ")
                 'face 'shadow)
              "  ")
            ;; Status icon
            (propertize icon 'face sface)
            " "
            ;; Node label
            (if (= depth 0)
                ;; Root: show abbreviated directory
                (propertize (abbreviate-file-name agent-id)
                            'face 'claude-code-agent-session)
              ;; Fork: show fork description
              (propertize (or desc (format "⑂ %s" (or fork-point "fork")))
                          'face 'claude-code-agent-session))
            ;; Status badge
            "  "
            (propertize (format "[%s]" status) 'face sface)
            ;; Current marker
            (if is-current
                (propertize "  ◀" 'face 'claude-code-fork-tree-current)
              ""))
           'mouse-face 'highlight))
        ;; Show fork point text for root nodes (their "latest message" context)
        (when (and (= depth 0) desc)
          (insert (propertize
                   (format "%s    %s\n"
                           (claude-code-fork-tree--continuation-prefix ancestors)
                           (truncate-string-to-width desc 50))
                   'face 'shadow)))
        ;; Show buffer name if live
        (when buf-live
          (insert (propertize
                   (format "%s    ⎘ %s\n"
                           (claude-code-fork-tree--continuation-prefix ancestors)
                           (truncate-string-to-width (buffer-name buf) 40))
                   'face 'shadow)))
        ;; Render fork children recursively
        (when fork-kids
          (let ((last-idx (1- (length fork-kids))))
            (cl-loop for child-id in fork-kids
                     for idx from 0
                     do (claude-code-fork-tree--render-node
                         child-id
                         (1+ depth)
                         (cons (= idx last-idx) ancestors)
                         current-key))))))))

(defun claude-code-fork-tree--prefix (ancestors)
  "Build the tree-drawing prefix string from ANCESTORS.
ANCESTORS is a list of booleans (newest-first) where t means the
ancestor at that level was the last sibling.  The first element
is the immediate parent's is-last flag."
  (if (null ancestors)
      ""
    (let* ((is-last (car ancestors))
           (rest    (cdr ancestors))
           ;; Build from outermost (end of list) to innermost (start)
           (parts   (nreverse
                     (mapcar (lambda (was-last)
                               (if was-last "    " "│   "))
                             rest))))
      (concat (apply #'concat parts)
              (if is-last "└── " "├── ")))))

(defun claude-code-fork-tree--continuation-prefix (ancestors)
  "Build continuation prefix (for detail lines below a heading).
Same as `claude-code-fork-tree--prefix' but with spaces instead of └/├."
  (if (null ancestors)
      ""
    (let* ((is-last (car ancestors))
           (rest    (cdr ancestors))
           (parts   (nreverse
                     (mapcar (lambda (was-last)
                               (if was-last "    " "│   "))
                             rest))))
      (concat (apply #'concat parts)
              (if is-last "    " "│   ")))))

;;;; Navigation

(defun claude-code-fork-tree-goto ()
  "Jump to the session buffer for the fork at point."
  (interactive)
  (when-let ((section (magit-current-section)))
    (when-let ((agent-id (oref section value)))
      (when-let ((agent (gethash agent-id claude-code--agents)))
        (let ((buf (plist-get agent :buffer)))
          (if (and buf (buffer-live-p buf))
              (pop-to-buffer buf)
            (message "Buffer for this fork is no longer available")))))))

(defun claude-code-fork-tree-toggle-or-goto ()
  "Toggle fold on nodes with children; navigate otherwise."
  (interactive)
  (when-let ((section (magit-current-section)))
    (let* ((agent-id (oref section value))
           (fork-kids (and agent-id
                          (claude-code-fork-tree--fork-children agent-id))))
      (if fork-kids
          (magit-section-toggle section)
        (claude-code-fork-tree-goto)))))

;;;; Major mode

(defvar-keymap claude-code-fork-tree-mode-map
  :doc "Keymap for the Claude fork tree buffer."
  :parent magit-section-mode-map)

(keymap-set claude-code-fork-tree-mode-map "RET"   #'claude-code-fork-tree-goto)
(keymap-set claude-code-fork-tree-mode-map "q"     #'quit-window)
(keymap-set claude-code-fork-tree-mode-map "g"     #'claude-code-fork-tree-refresh)
(keymap-set claude-code-fork-tree-mode-map "<tab>" #'claude-code-fork-tree-toggle-or-goto)
(keymap-set claude-code-fork-tree-mode-map "<mouse-1>" #'claude-code-fork-tree-goto-mouse)

(define-derived-mode claude-code-fork-tree-mode magit-section-mode "Fork-Tree"
  "Major mode for the Claude fork tree visualisation.
\\{claude-code-fork-tree-mode-map}"
  :group 'claude-code
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (setq-local cursor-type 'bar)
  (hl-line-mode 1)
  (add-hook 'claude-code-agents-update-hook
            #'claude-code-fork-tree--schedule-render))

(defun claude-code-fork-tree-refresh ()
  "Force re-render the fork tree."
  (interactive)
  (claude-code-fork-tree--do-render))

(defun claude-code-fork-tree-goto-mouse (event)
  "Navigate to the fork at the mouse click position."
  (interactive "e")
  (mouse-set-point event)
  (claude-code-fork-tree-goto))

;;;; Entry point

;;;###autoload
(defun claude-code-fork-tree ()
  "Open the fork tree visualisation.
Shows the conversation DAG for the current session, highlighting
which branch is active.  Press RET to jump to any branch."
  (interactive)
  ;; Capture current session key before switching buffers
  (let ((current-key (when (bound-and-true-p claude-code--cwd)
                       (claude-code--effective-session-key)))
        (buf (get-buffer-create "*Claude Fork Tree*")))
    (with-current-buffer buf
      (unless (eq major-mode 'claude-code-fork-tree-mode)
        (claude-code-fork-tree-mode))
      (setq-local claude-code-fork-tree--current-key current-key))
    (claude-code-fork-tree--do-render)
    (display-buffer-in-side-window
     buf `((side . left)
            (window-width . ,claude-code-agents-sidebar-width)
            (slot . -2)
            (window-parameters . ((no-delete-other-windows . t)))))))

;;;###autoload
(defun claude-code-fork-tree-toggle ()
  "Toggle the fork tree window."
  (interactive)
  (if-let ((buf (get-buffer "*Claude Fork Tree*"))
           (win (get-buffer-window buf)))
      (delete-window win)
    (claude-code-fork-tree)))

(provide 'claude-code-fork-tree)
;;; claude-code-fork-tree.el ends here
