;;; claude-code-render.el --- Buffer rendering for claude-code.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Renders the conversation buffer using magit-section: header, messages
;; (user/assistant/result/error/info), content blocks (text/thinking/tool-use),
;; streaming preview, and the thinking spinner animation.

;;; Code:

(require 'claude-code-vars)
(require 'claude-code-config)
(require 'claude-code-agents)
(require 'magit-section)

;;;; Buffer Rendering

(defun claude-code--render ()
  "Render the conversation buffer."
  ;; Save any text the user has typed in the input area before erasing.
  (let* ((input-active (and claude-code--input-marker
                            (marker-buffer claude-code--input-marker)))
         (saved-input (cond
                       (input-active
                        (buffer-substring-no-properties
                         claude-code--input-marker (point-max)))
                       (claude-code--pending-input
                        (prog1 claude-code--pending-input
                          (setq claude-code--pending-input nil)))
                       (t "")))
         (was-in-input (and input-active
                            (>= (point)
                                (marker-position claude-code--input-marker))))
         (at-end (or was-in-input (>= (point) (point-max))))
         (old-point (point)))
    ;; Remove all thinking overlays (including any orphaned ones from previous
    ;; renders that may have escaped cleanup via the tracked variable).
    (remove-overlays (point-min) (point-max) 'claude-code-spinner t)
    (setq claude-code--thinking-overlay nil)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (magit-insert-section (root)
        (claude-code--render-header)
        (insert "\n")
        ;; Messages are stored newest-first; render oldest-first
        (dolist (msg (reverse claude-code--messages))
          (claude-code--render-message msg))
        ;; Show in-progress streaming content
        (claude-code--render-streaming)
        ;; Pinned spawned-agents panel (below all output, above input)
        (claude-code--render-subagents-panel))
      ;; Thinking spinner overlay (cheap to update, sits at end of buffer)
      (when (eq claude-code--status 'working)
        (let ((ov (make-overlay (point-max) (point-max))))
          (overlay-put ov 'after-string
                       (propertize (claude-code--thinking-overlay-string)
                                   'face 'claude-code-thinking))
          (overlay-put ov 'claude-code-spinner t)
          (setq claude-code--thinking-overlay ov)))
      ;; Insert the input area at the bottom
      (insert "\n")
      (insert (propertize (make-string 70 ?─) 'face 'claude-code-separator))
      (insert "\n")
      (insert (propertize "> " 'face 'claude-code-input-prompt))
      ;; Advance the marker to the current point (start of user input).
      ;; marker-insertion-type nil means new text inserted at the marker
      ;; position will go AFTER the marker, keeping the marker fixed.
      (unless (and claude-code--input-marker
                   (marker-buffer claude-code--input-marker))
        (setq claude-code--input-marker (make-marker)))
      (set-marker claude-code--input-marker (point))
      (set-marker-insertion-type claude-code--input-marker nil)
      ;; Restore whatever the user had typed before the re-render
      (insert saved-input)
      ;; Make everything above the input area read-only via text property.
      ;; The input area itself stays editable.
      (let ((boundary (marker-position claude-code--input-marker)))
        (add-text-properties (point-min) boundary
                             '(read-only t))
        ;; Make the boundary rear-nonsticky so typed text after "> "
        ;; does not inherit read-only or the input-prompt face color.
        (when (> boundary (point-min))
          (put-text-property (1- boundary) boundary
                             'rear-nonsticky '(read-only face)))))
    ;; Restore point
    (if at-end
        (goto-char (point-max))
      (goto-char (min old-point (point-max))))
    ;; Keep window scrolled to bottom when following
    (when-let ((win (get-buffer-window (current-buffer))))
      (when at-end
        (set-window-point win (point-max))))))

(defun claude-code--render-header ()
  "Render the buffer header line."
  (let ((cfg (claude-code--session-config)))
    (insert (propertize "Claude Code" 'face 'claude-code-header))
    (insert "  ")
    (insert (propertize (format "[%s]" claude-code--status)
                        'face 'claude-code-status))
    (when claude-code--cwd
      (insert "  "
              (propertize (abbreviate-file-name claude-code--cwd)
                          'face 'shadow)))
    (insert "\n")
    ;; Show active config summary
    (let ((model (alist-get 'model cfg))
          (effort (alist-get 'effort cfg))
          (mode (alist-get 'permission-mode cfg)))
      (insert (propertize
               (format "  %s%s  %s"
                       (or model "default model")
                       (if effort (format " [%s]" effort) "")
                       (or mode ""))
               'face 'shadow))
      (insert "\n"))
    (insert (propertize (make-string 70 ?─) 'face 'claude-code-separator))
    (insert "\n")
    ;; Action buttons: Reset and New Session
    (insert "  ")
    (insert-button "[Reset]"
                   'action (lambda (_btn) (claude-code-reset))
                   'help-echo "Hard-reset: clear all messages and restart the backend"
                   'face 'claude-code-action-button
                   'follow-link t)
    (insert "  ")
    (insert-button "[New Session]"
                   'action (lambda (_btn) (claude-code-new-session))
                   'help-echo "Open a new independent session for this directory"
                   'face 'claude-code-action-button
                   'follow-link t)
    (insert "\n")))

(defun claude-code--render-message (msg)
  "Render a single conversation MSG."
  (let ((type (alist-get 'type msg)))
    (pcase type
      ("user"      (claude-code--render-user-msg msg))
      ("assistant" (claude-code--render-assistant-msg msg))
      ("result"    (claude-code--render-result-msg msg))
      ("error"     (claude-code--render-error-msg msg))
      ("info"      (claude-code--render-info-msg msg)))))

(defun claude-code--render-user-msg (msg)
  "Render a user MSG."
  ;; Store MSG as the section value so `claude-code-fork' can retrieve it.
  (magit-insert-section (claude-user msg)
    (magit-insert-heading
      (propertize "▶ You" 'face 'claude-code-user-prompt))
    ;; Append a fork button to the heading line (before its trailing newline).
    ;; After magit-insert-heading, point is at the start of the section body
    ;; one line below the heading, so we use save-excursion to reach the
    ;; heading's end-of-line and splice the button in there.
    (save-excursion
      (forward-line -1)
      (end-of-line)
      (insert "  ")
      (let ((btn-start (point)))
        (insert "[fork]")
        (make-text-button btn-start (point)
                          'action (let ((m msg))
                                    (lambda (_btn)
                                      (claude-code--fork-at-msg m)))
                          'help-echo "Fork conversation at this message"
                          'face 'claude-code-action-button
                          'follow-link t)))
    (insert "  " (alist-get 'prompt msg) "\n\n")))

(defun claude-code--render-assistant-msg (msg)
  "Render an assistant MSG with its content blocks."
  (magit-insert-section (claude-assistant nil nil)
    (magit-insert-heading
      (propertize "◀ Assistant" 'face 'claude-code-assistant-label))
    (let ((content (alist-get 'content msg)))
      ;; json-parse-string returns vectors for arrays
      (when (vectorp content)
        (setq content (append content nil)))
      (dolist (block content)
        (claude-code--render-content-block block)))
    (insert "\n")))

(defun claude-code--render-content-block (block)
  "Render a single content BLOCK."
  (let ((block-type (alist-get 'type block)))
    (pcase block-type
      ("text"
       (claude-code--render-text (alist-get 'text block)))
      ("thinking"
       (claude-code--render-thinking (alist-get 'thinking block)))
      ("tool_use"
       (claude-code--render-tool-use block))
      ("tool_result"
       (claude-code--render-tool-result block)))))

(defun claude-code--render-text (text)
  "Render a TEXT content block."
  (when (and text (not (string-empty-p text)))
    (dolist (line (split-string text "\n"))
      (insert "  ")
      (claude-code--insert-linkified line)
      (insert "\n"))))

(defun claude-code--render-thinking (text)
  "Render a collapsible thinking TEXT block."
  (when (and text (not (string-empty-p text)))
    (magit-insert-section (claude-thinking nil
                                           (not claude-code-show-thinking))
      (magit-insert-heading
        (propertize "  ◆ Thinking" 'face 'claude-code-thinking))
      (insert (propertize (claude-code--indent text 4)
                          'face 'claude-code-thinking))
      (insert "\n"))))

(defun claude-code--render-tool-use (block)
  "Render a collapsible tool-use BLOCK."
  (let* ((name (alist-get 'name block))
         (input (alist-get 'input block))
         (summary (claude-code--tool-summary name input)))
    (magit-insert-section (claude-tool-use nil
                                           (not claude-code-show-tool-details))
      (magit-insert-heading
        (concat "  "
                (propertize (format "⚙ %s" name)
                            'face 'claude-code-tool-name)
                (when summary
                  (concat " " (propertize summary 'face 'shadow)))))
      (when input
        (insert (propertize
                 (claude-code--indent
                  (if (stringp input)
                      input
                    (json-encode input))
                  6)
                 'face 'claude-code-tool-input))
        (insert "\n")))))

(defun claude-code--render-tool-result (block)
  "Render a tool result BLOCK."
  (let ((content (alist-get 'content block))
        (is-error (alist-get 'is_error block)))
    (when (and content (stringp content) (not (string-empty-p content)))
      (let ((face (if is-error 'claude-code-error 'shadow)))
        (magit-insert-section (claude-tool-result nil t)
          (magit-insert-heading
            (propertize (if is-error "  ✗ Tool error" "  ↳ Tool result")
                        'face face))
          (insert (propertize (claude-code--indent content 6) 'face face))
          (insert "\n"))))))

(defun claude-code--render-result-msg (msg)
  "Render a result MSG."
  (let ((cost (alist-get 'total_cost_usd msg))
        (turns (alist-get 'num_turns msg))
        (duration (alist-get 'duration_ms msg)))
    (insert (propertize
             (format "  ✓ Done%s\n"
                     (concat
                      (when turns (format " | %d turns" turns))
                      (when cost (format " | $%.4f" cost))
                      (when duration (format " | %.1fs" (/ duration 1000.0)))))
             'face 'claude-code-result))
    (insert (propertize (make-string 70 ?─) 'face 'claude-code-separator))
    (insert "\n\n")))

(defun claude-code--render-error-msg (msg)
  "Render an error MSG."
  (insert (propertize (format "  ✗ Error: %s\n\n" (alist-get 'message msg))
                      'face 'claude-code-error)))

(defun claude-code--render-info-msg (msg)
  "Render an informational MSG."
  (insert (propertize (format "  ℹ %s\n" (alist-get 'text msg))
                      'face 'claude-code-status)))

(defun claude-code--render-streaming ()
  "Render in-progress streaming content inline."
  (when claude-code--streaming-active
    (when (not (string-empty-p claude-code--streaming-thinking))
      (magit-insert-section (claude-thinking nil
                                             (not claude-code-show-thinking))
        (magit-insert-heading
          (propertize "  ◆ Thinking..." 'face 'claude-code-thinking))
        (insert (propertize (claude-code--indent
                             claude-code--streaming-thinking 4)
                            'face 'claude-code-thinking))
        (insert "\n")))
    (when (not (string-empty-p claude-code--streaming-text))
      (claude-code--render-text claude-code--streaming-text))))

;;;; Spawned Agents Panel

(defun claude-code--render-subagents-panel ()
  "Render a pinned Spawned Agents panel after all messages.
Shows one clickable link per subagent task, with its status and summary."
  (when-let* ((session-key (or claude-code--session-key claude-code--cwd))
              (parent (gethash session-key claude-code--agents))
              (children (plist-get parent :children)))
    (when children
      (insert (propertize (make-string 70 ?─) 'face 'claude-code-separator))
      (insert "\n")
      (insert (propertize "  Spawned Agents\n" 'face 'claude-code-assistant-label))
      (dolist (child-id children)
        (when-let ((child (gethash child-id claude-code--agents)))
          (let* ((status  (plist-get child :status))
                 (desc    (or (plist-get child :description) "task"))
                 (buf     (plist-get child :buffer))
                 (icon    (claude-code--agents-status-icon status))
                 (sface   (claude-code--agents-status-face status)))
            (insert "    ")
            (insert (propertize icon 'face sface))
            (insert " ")
            ;; Description — clickable if the task buffer is live
            (let ((btn-start (point)))
              (insert (truncate-string-to-width desc 50))
              (when (and buf (buffer-live-p buf))
                (make-text-button btn-start (point)
                                  'action (let ((b buf))
                                            (lambda (_) (pop-to-buffer b)))
                                  'face 'claude-code-file-link
                                  'help-echo "Jump to subagent buffer"
                                  'follow-link t)))
            (insert "  ")
            (insert (propertize (format "[%s]" status) 'face sface))
            (when-let ((summary (plist-get child :summary)))
              (insert "  ")
              (insert (propertize (truncate-string-to-width summary 35)
                                  'face 'shadow)))
            (insert "\n"))))
      (insert "\n"))))

;;;; Text Utilities

(defun claude-code--indent (text n)
  "Indent each line of TEXT by N spaces."
  (let ((prefix (make-string n ?\s)))
    (replace-regexp-in-string "^" prefix text)))

(defun claude-code--tool-summary (name input)
  "Generate a short summary for tool NAME with INPUT."
  (when (listp input)
    (pcase name
      ("Read"  (alist-get 'file_path input))
      ("Write" (alist-get 'file_path input))
      ("Edit"  (alist-get 'file_path input))
      ("Bash"  (when-let ((cmd (alist-get 'command input)))
                 (truncate-string-to-width cmd 60)))
      ("Glob"  (alist-get 'pattern input))
      ("Grep"  (alist-get 'pattern input))
      (_       nil))))

(defun claude-code--insert-linkified (text)
  "Insert TEXT with URLs and file paths made clickable."
  (let ((start (point)))
    (insert text)
    ;; Linkify URLs
    (save-excursion
      (goto-char start)
      (while (re-search-forward "https?://[^ \t\n\"'>)]+" (line-end-position) t)
        (let ((url (match-string 0)))
          (make-text-button (match-beginning 0) (match-end 0)
                            'action (lambda (_) (browse-url url))
                            'face 'claude-code-file-link
                            'help-echo url))))
    ;; Linkify absolute file paths
    (save-excursion
      (goto-char start)
      (while (re-search-forward "/[^ \t\n\"'>:)]+" (line-end-position) t)
        (let ((path (match-string 0)))
          (when (file-exists-p path)
            (make-text-button (match-beginning 0) (match-end 0)
                              'action (lambda (_) (find-file path))
                              'face 'claude-code-file-link
                              'help-echo (format "Open %s" path))))))))

;;;; Thinking Animation

(defun claude-code--format-elapsed (seconds)
  "Format SECONDS as a compact human-readable duration string."
  (cond
   ((< seconds 60) (format "%.0fs" seconds))
   (t (format "%dm %ds"
              (floor (/ seconds 60))
              (round (mod seconds 60))))))

(defun claude-code--thinking-overlay-string ()
  "Build the spinner overlay string with live stats and queued-message indicator.
Format: \\n  FRAME Working… (ELAPSED · ↓ CHARS · thought THINKs)\\n
Followed by one line per queued message:  ⏳ [N] message…
Character count is an approximation of output size; true token counts
are only available in the final result event."
  (let* ((frame   (aref claude-code--thinking-frames
                        (mod claude-code--thinking-frame
                             (length claude-code--thinking-frames))))
         (elapsed (when claude-code--query-start-time
                    (- (float-time) claude-code--query-start-time)))
         (chars   claude-code--streaming-char-count)
         ;; Include time in the current (possibly still-open) thinking block.
         (think-sec (+ claude-code--thinking-elapsed-sec
                       (if claude-code--thinking-block-start-time
                           (- (float-time) claude-code--thinking-block-start-time)
                         0.0)))
         (parts '()))
    (when (and elapsed (> elapsed 0.5))
      (push (claude-code--format-elapsed elapsed) parts))
    (when (> chars 0)
      (push (format "↓ %d chars" chars) parts))
    (when (> think-sec 1.0)
      (push (format "thought %s" (claude-code--format-elapsed think-sec)) parts))
    (let ((stats-line
           (if parts
               (format "\n  %s Working… (%s)\n" frame
                       (mapconcat #'identity (nreverse parts) " · "))
             (format "\n  %s Working…\n" frame))))
      (if claude-code--input-queued
          (let ((queue-lines
                 (cl-loop for msg in claude-code--input-queued
                          for i from 1
                          concat (format "  ⏳ [%d] %s\n"
                                         i
                                         (truncate-string-to-width
                                          msg 60 nil nil "…")))))
            (concat stats-line queue-lines))
        stats-line))))

(defun claude-code--start-thinking ()
  "Start the thinking spinner animation."
  (unless claude-code--thinking-timer
    (setq claude-code--thinking-frame 0)
    (let ((buf (current-buffer)))
      (setq claude-code--thinking-timer
            (run-with-timer
             0.08 0.08
             (lambda ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (cl-incf claude-code--thinking-frame)
                   (claude-code--update-thinking-overlay)))))))))

(defun claude-code--stop-thinking ()
  "Stop the thinking spinner animation."
  (when claude-code--thinking-timer
    (cancel-timer claude-code--thinking-timer)
    (setq claude-code--thinking-timer nil))
  ;; Remove all spinner overlays, including any orphaned ones.
  (remove-overlays (point-min) (point-max) 'claude-code-spinner t)
  (setq claude-code--thinking-overlay nil))

(defun claude-code--update-thinking-overlay ()
  "Update the thinking spinner overlay text."
  (when claude-code--thinking-overlay
    (overlay-put
     claude-code--thinking-overlay
     'after-string
     (propertize (claude-code--thinking-overlay-string)
                 'face 'claude-code-thinking))))

(provide 'claude-code-render)
;;; claude-code-render.el ends here
