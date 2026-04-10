;;; claude-code-events.el --- Backend event handling for claude-code.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Handles JSON events from the Python backend: status transitions,
;; assistant messages, streaming deltas, task events, and render scheduling.

;;; Code:

(require 'claude-code-vars)
(require 'claude-code-agents)
(require 'claude-code-stats)

;; Forward declarations for functions defined in files loaded after this one.
(declare-function claude-code--render "claude-code-render")
(declare-function claude-code--start-thinking "claude-code-render")
(declare-function claude-code--stop-thinking "claude-code-render")
(declare-function claude-code--dispatch-input "claude-code-commands")
(declare-function claude-code--send-json "claude-code-process")

;;;; Event Handling

(defun claude-code--handle-event (event)
  "Dispatch a protocol EVENT from the backend."
  (let ((type (alist-get 'type event)))
    (pcase type
      ("status"
       (claude-code--handle-status-event event))
      ("system"
       (claude-code--handle-system-event event))
      ("assistant"
       (claude-code--handle-assistant-event event))
      ("result"
       (claude-code--handle-result-event event))
      ("error"
       (claude-code--handle-error-event event))
      ;; Streaming deltas
      ("content_block_start"
       (claude-code--handle-block-start event))
      ("text_delta"
       (claude-code--handle-text-delta event))
      ("thinking_delta"
       (claude-code--handle-thinking-delta event))
      ("content_block_stop"
       (claude-code--handle-block-stop event))
      ;; Task / subagent events
      ("task_started"
       (let ((task-id (alist-get 'task_id event))
             (desc (alist-get 'description event))
             (parent-key (claude-code--effective-session-key)))
         (when task-id
           (claude-code--agent-register
            task-id
            :type 'task :description desc :status 'working
            :parent-id parent-key :cwd claude-code--cwd
            :children nil)
           (claude-code--agent-add-child parent-key task-id)
           ;; Create a dedicated task buffer and store it on the agent entry
           (let ((task-buf (claude-code--task-buffer-create
                            task-id desc (current-buffer))))
             (claude-code--agent-update task-id :buffer task-buf)))
         (push `((type . "info")
                 (text . ,(format "Subagent started: %s" desc)))
               claude-code--messages)
         (claude-code--schedule-render)))
      ("task_progress"
       (let* ((task-id    (alist-get 'task_id event))
              (tool-name  (alist-get 'last_tool_name event))
              (tool-input (alist-get 'last_tool_input event)))
         (when task-id
           (claude-code--agent-update
            task-id
            :description (alist-get 'description event)
            :last-tool       tool-name
            :last-tool-input tool-input
            :status 'working)
           ;; Forward tool-use events to the task buffer
           (when-let* ((child (gethash task-id claude-code--agents))
                       (_ tool-name))
             (claude-code--task-buffer-append-tool
              (plist-get child :buffer) tool-name tool-input)))))
      ("task_notification"
       (let ((task-id (alist-get 'task_id event))
             (status (alist-get 'status event))
             (summary (alist-get 'summary event)))
         (when task-id
           (claude-code--agent-update
            task-id
            :status (intern (or status "completed"))
            :summary summary)
           ;; Finalize the task buffer with status and summary
           (when-let ((child (gethash task-id claude-code--agents)))
             (claude-code--task-buffer-finalize
              (plist-get child :buffer) status summary)))
         (push `((type . "info")
                 (text . ,(format "Subagent %s: %s" status summary)))
               claude-code--messages)
         (claude-code--schedule-render)))
      ("permission_request"
       (claude-code--handle-permission-request event))
      ;; input_json_delta, rate_limit — ignored for now
      )))

(defun claude-code--handle-status-event (event)
  "Handle a status EVENT."
  (let ((status    (alist-get 'status event))
        (agent-key (claude-code--effective-session-key)))
    (pcase status
      ("ready"
       (setq claude-code--status 'ready)
       (claude-code--stop-thinking)
       (claude-code--flush-streaming)
       (setq claude-code--query-start-time nil)
       (setq claude-code--thinking-block-start-time nil)
       ;; Auto-send the oldest queued input, if any.
       (setq claude-code--queue-edit-index nil)
       (when claude-code--input-queued
         (let ((queued (car claude-code--input-queued)))
           (setq claude-code--input-queued (cdr claude-code--input-queued))
           (claude-code--dispatch-input queued)))
       (when agent-key
         (claude-code--agent-update agent-key :status 'ready)))
      ("working"
       (setq claude-code--status 'working)
       (setq claude-code--query-start-time (float-time)
             claude-code--streaming-char-count 0
             claude-code--thinking-elapsed-sec 0.0
             claude-code--thinking-block-start-time nil)
       (claude-code--start-thinking)
       (when agent-key
         (claude-code--agent-update agent-key :status 'working))
       ;; Mark that this subagent has actually started doing real work
       (when claude-code--subagent-task-id
         (setq claude-code--subagent-has-worked t)))
      ("cancelled"
       (setq claude-code--status 'ready)
       (claude-code--stop-thinking)
       (claude-code--flush-streaming)
       (setq claude-code--query-start-time nil
             claude-code--thinking-block-start-time nil
             claude-code--input-queued nil
             claude-code--queue-edit-index nil
             claude-code--pending-permission nil)
       (when agent-key
         (claude-code--agent-update agent-key :status 'ready))
       (push '((type . "info") (text . "Cancelled."))
             claude-code--messages))
      ("error"
       (setq claude-code--status 'error)
       (claude-code--stop-thinking)
       (setq claude-code--query-start-time nil
             claude-code--thinking-block-start-time nil)
       (when agent-key
         (claude-code--agent-update agent-key :status 'error))))
    (claude-code--schedule-render)))

;;;; File-buffer Pulse Highlighting

(defun claude-code--tool-use-file-path (tool-name input)
  "Return the file path from INPUT for a file-touching TOOL-NAME, or nil.
Handles both symbol-keyed (decoded JSON alists) and string-keyed inputs."
  (when (and input (not (eq input :null)) (listp input))
    (pcase tool-name
      ((or "Read" "Write" "Edit" "MultiEdit")
       (when-let ((path (or (alist-get 'path input)
                            (alist-get 'file_path input)
                            (alist-get "path" input nil nil #'equal)
                            (alist-get "file_path" input nil nil #'equal))))
         (format "%s" path))))))

(defun claude-code--pulse-buffer-region (buf beg end)
  "Pulse BEG..END in BUF using `pulse-momentary-highlight-region'.
Does nothing if BUF is not live or the region is degenerate."
  (when (and (buffer-live-p buf) (< beg end))
    (with-current-buffer buf
      (pulse-momentary-highlight-region beg end))))

(defun claude-code--pulse-from-tool-use (block cwd)
  "Pulse any live buffer referenced by tool-use BLOCK.
CWD is used to expand relative paths.  Silently does nothing when no
buffer is currently visiting the referenced file."
  (require 'pulse)
  (let* ((name      (alist-get 'name block))
         (input     (alist-get 'input block))
         (rel-path  (claude-code--tool-use-file-path name input)))
    (when rel-path
      (let* ((full-path (if (file-name-absolute-p rel-path)
                            rel-path
                          (expand-file-name rel-path (or cwd default-directory))))
             (buf       (find-buffer-visiting full-path)))
        (when (buffer-live-p buf)
          (claude-code--pulse-buffer-region buf
                                            (with-current-buffer buf (point-min))
                                            (with-current-buffer buf (point-max))))))))

(defun claude-code--pulse-assistant-tool-files (event)
  "Pulse open file buffers referenced by tool-use blocks in assistant EVENT.
Iterates over every content block in EVENT; for each `tool_use' block
that references a file, pulses any open buffer visiting that file."
  (let* ((content (alist-get 'content event))
         (cwd     claude-code--cwd)
         (blocks  (cond ((vectorp content) (append content nil))
                        ((listp   content) content))))
    (dolist (block blocks)
      (when (equal (alist-get 'type block) "tool_use")
        (claude-code--pulse-from-tool-use block cwd)))))

(defun claude-code--permission-pattern-allows-p (tool-name tool-input)
  "Return non-nil if a pattern in `claude-code--permission-patterns' matches.
Checks every entry whose :tool-name equals TOOL-NAME; the entry's :pattern
is matched (as a regexp) against the primary argument string extracted from
TOOL-INPUT by `claude-code--tool-input-primary-string'."
  (let ((input-str (or (claude-code--tool-input-primary-string tool-name tool-input) "")))
    (seq-some (lambda (pat)
                (and (equal (plist-get pat :tool-name) tool-name)
                     (string-match-p (plist-get pat :pattern) input-str)))
              claude-code--permission-patterns)))

(defun claude-code--handle-permission-request (event)
  "Handle a permission_request EVENT from the backend.
If a saved pattern in `claude-code--permission-patterns' matches the call,
auto-approves it immediately (no widget shown).  Otherwise stores the
request in `claude-code--pending-permission' and triggers a render so the
approval widget appears inline above the input area."
  (let ((request-id (alist-get 'request_id event))
        (tool-name  (alist-get 'tool_name event))
        (tool-input (alist-get 'tool_input event)))
    (if (claude-code--permission-pattern-allows-p tool-name tool-input)
        ;; A saved pattern matches — silently approve without showing the widget.
        (claude-code--send-json
         `((type       . "permission_response")
           (request_id . ,request-id)
           (decision   . "allow")))
      ;; No pattern matches — show the inline approval widget.
      (setq claude-code--pending-permission
            `((request-id . ,request-id)
              (tool-name  . ,tool-name)
              (tool-input . ,tool-input)))
      (claude-code--schedule-render)
      (message "claude-code: approval needed for %s — press y/Y/n in the Claude buffer"
               tool-name))))

(defun claude-code--handle-system-event (event)
  "Handle a system EVENT."
  (let ((subtype (alist-get 'subtype event))
        (data (alist-get 'data event)))
    (when (equal subtype "init")
      (setq claude-code--session-id
            (alist-get 'session_id data)))))

(defun claude-code--handle-assistant-event (event)
  "Handle a complete assistant EVENT (non-streaming).
The complete event already contains all content blocks (thinking, text,
tool_use), so we discard the streaming buffers rather than flushing them
to avoid duplicating thinking/text content in separate ◀ Assistant blocks.
Also pulses any open Emacs buffers whose files were touched by tool calls."
  ;; Discard streaming buffers — the complete event supersedes them.
  (setq claude-code--streaming-text ""
        claude-code--streaming-thinking ""
        claude-code--streaming-active nil)
  (push event claude-code--messages)
  ;; Pulse open file buffers referenced by tool-use blocks (Read/Edit/Write).
  (claude-code--pulse-assistant-tool-files event)
  (claude-code--schedule-render))

(defun claude-code--handle-result-event (event)
  "Handle a result EVENT."
  (claude-code--flush-streaming)
  (claude-code--stop-thinking)
  (push event claude-code--messages)
  ;; Capture token counts for the context-window usage bar in the header.
  (when-let ((in  (alist-get 'input_tokens event)))
    (setq claude-code--last-input-tokens in))
  (when-let ((out (alist-get 'output_tokens event)))
    (setq claude-code--last-output-tokens out))
  ;; Record stats (in-memory, session lifetime only)
  (claude-code-stats-record!
   (or claude-code--cwd default-directory)
   (alist-get 'total_cost_usd event)
   (alist-get 'num_turns event)
   (alist-get 'duration_ms event))
  ;; If this is an Emacs-native subagent that has actually run (not the
  ;; startup ready→working edge), notify the parent session of completion.
  (when (and claude-code--subagent-task-id
             claude-code--subagent-has-worked)
    (claude-code--subagent-notify-parent))
  (claude-code--schedule-render))

(defun claude-code--subagent-notify-parent ()
  "Notify the parent session that this subagent has completed.
Called from `claude-code--handle-result-event' in subagent sessions.
Updates the agent registry entry and pushes an info message to the parent."
  (let* ((task-id    claude-code--subagent-task-id)
         (parent-key claude-code--subagent-parent-key)
         ;; Extract a one-line summary from the last assistant text block
         (summary
          (when-let* ((msg (seq-find
                            (lambda (m) (equal (alist-get 'type m) "assistant"))
                            claude-code--messages))
                      (content (alist-get 'content msg))
                      (_ (vectorp content))
                      (tb (seq-find
                           (lambda (b) (equal (alist-get 'type b) "text"))
                           content))
                      (text (alist-get 'text tb)))
            (car (split-string (string-trim text) "\n"))))
         (parent-agent (gethash parent-key claude-code--agents))
         (parent-buf   (when parent-agent (plist-get parent-agent :buffer))))
    ;; Mark the task completed in the registry
    (claude-code--agent-update task-id :status 'completed :summary summary)
    ;; Don't fire again for subsequent turns
    (setq claude-code--subagent-task-id nil)
    ;; Push an info message into the parent session
    (when (and parent-buf (buffer-live-p parent-buf))
      (with-current-buffer parent-buf
        (push `((type . "info")
                (text . ,(format "✓ Subagent completed: %s%s"
                                 (or (when-let ((a (gethash task-id
                                                            claude-code--agents)))
                                       (plist-get a :description))
                                     task-id)
                                 (if summary
                                     (format " — %s" summary)
                                   ""))))
              claude-code--messages)
        (claude-code--schedule-render)))))

(defun claude-code--handle-error-event (event)
  "Handle an error EVENT."
  (claude-code--stop-thinking)
  (push `((type . "error") (message . ,(alist-get 'message event)))
        claude-code--messages)
  (claude-code--schedule-render))

;;;; Streaming Delta Handling

(defun claude-code--handle-block-start (event)
  "Handle a content_block_start EVENT."
  (let ((block-type (alist-get 'block_type event)))
    (pcase block-type
      ("text"
       (setq claude-code--streaming-text ""
             claude-code--streaming-active t))
      ("thinking"
       (setq claude-code--streaming-thinking ""
             claude-code--streaming-active t
             claude-code--thinking-block-start-time (float-time))))))

(defun claude-code--handle-text-delta (event)
  "Handle a text_delta EVENT — append streaming text."
  (let ((text (alist-get 'text event)))
    (when text
      (setq claude-code--streaming-text
            (concat claude-code--streaming-text text))
      (cl-incf claude-code--streaming-char-count (length text))
      (claude-code--schedule-render))))

(defun claude-code--handle-thinking-delta (event)
  "Handle a thinking_delta EVENT — append streaming thinking."
  (let ((thinking (alist-get 'thinking event)))
    (when thinking
      (setq claude-code--streaming-thinking
            (concat claude-code--streaming-thinking thinking))
      (cl-incf claude-code--streaming-char-count (length thinking))
      ;; Only re-render occasionally for thinking (it's collapsed by default)
      (when (= 0 (mod (length claude-code--streaming-thinking) 200))
        (claude-code--schedule-render)))))

(defun claude-code--handle-block-stop (_event)
  "Handle a content_block_stop EVENT."
  ;; Accumulate thinking time from the completed block.
  (when claude-code--thinking-block-start-time
    (cl-incf claude-code--thinking-elapsed-sec
             (- (float-time) claude-code--thinking-block-start-time))
    (setq claude-code--thinking-block-start-time nil)))

(defun claude-code--flush-streaming ()
  "Flush any accumulated streaming content into a message."
  (when claude-code--streaming-active
    (let ((content '()))
      (when (not (string-empty-p claude-code--streaming-thinking))
        (push `((type . "thinking")
                (thinking . ,claude-code--streaming-thinking))
              content))
      (when (not (string-empty-p claude-code--streaming-text))
        (push `((type . "text")
                (text . ,claude-code--streaming-text))
              content))
      (when content
        (push `((type . "assistant")
                (content . ,(vconcat (nreverse content))))
              claude-code--messages)))
    (setq claude-code--streaming-text ""
          claude-code--streaming-thinking ""
          claude-code--streaming-active nil)))

;;;; Render Scheduling

(defun claude-code--schedule-render ()
  "Schedule a buffer render with debouncing."
  (unless claude-code--render-pending
    (setq claude-code--render-pending t)
    (run-at-time 0.03 nil
                 (lambda (buf)
                   (when (buffer-live-p buf)
                     (with-current-buffer buf
                       (setq claude-code--render-pending nil)
                       (claude-code--render))))
                 (current-buffer))))

(provide 'claude-code-events)
;;; claude-code-events.el ends here
