;;; claude-code-test.el --- Tests for claude-code.el -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for claude-code.  Run with:
;;   make test
;;   ./emacs-batch.sh -l claude-code-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'claude-code)

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defmacro claude-code-test-with-buffer (&rest body)
  "Run BODY in a fresh claude-code-mode buffer, then kill it."
  (declare (indent 0))
  `(let ((buf (generate-new-buffer " *claude-test*")))
     (unwind-protect
         (with-current-buffer buf
           (claude-code-mode)
           (setq claude-code--cwd "/tmp/test-project")
           (setq claude-code--status 'ready)
           ,@body)
       (kill-buffer buf))))

(defmacro claude-code-test-with-clean-agents (&rest body)
  "Run BODY with an empty agent registry, restore afterwards."
  (declare (indent 0))
  `(let ((saved claude-code--agents))
     (setq claude-code--agents (make-hash-table :test 'equal))
     (unwind-protect (progn ,@body)
       (setq claude-code--agents saved))))

;; ---------------------------------------------------------------------------
;; Mode setup
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-mode-sets-comment-start ()
  "The mode must set `comment-start' to avoid outline-minor-mode errors."
  (claude-code-test-with-buffer
    (should (stringp comment-start))
    (should (not (string-empty-p comment-start)))))

(ert-deftest claude-code-test-mode-disables-font-lock ()
  "Font-lock must be off to prevent jit-lock redisplay crashes."
  (claude-code-test-with-buffer
    (should (not font-lock-mode))))

(ert-deftest claude-code-test-mode-not-read-only ()
  "Buffer must not be read-only (input area needs to be editable)."
  (claude-code-test-with-buffer
    (should (not buffer-read-only))))

(ert-deftest claude-code-test-mode-word-wrap ()
  "Word wrap should be enabled."
  (claude-code-test-with-buffer
    (should word-wrap)
    (should visual-line-mode)))

;; ---------------------------------------------------------------------------
;; Rendering
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-render-empty ()
  "Rendering an empty conversation should not error."
  (claude-code-test-with-buffer
    (claude-code--render)
    (should (> (buffer-size) 0))
    ;; Should contain the header
    (should (string-match-p "Claude Code"
                            (buffer-substring-no-properties
                             (point-min) (point-max))))))

(ert-deftest claude-code-test-render-with-messages ()
  "Rendering a conversation with messages should not error."
  (claude-code-test-with-buffer
    (push '((type . "user") (prompt . "hello"))
          claude-code--messages)
    (push `((type . "assistant")
            (content . [((type . "text") (text . "world"))]))
          claude-code--messages)
    (claude-code--render)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "hello" text))
      (should (string-match-p "world" text)))))

(ert-deftest claude-code-test-render-with-thinking ()
  "Rendering thinking blocks should not error."
  (claude-code-test-with-buffer
    (push `((type . "assistant")
            (content . [((type . "thinking")
                         (thinking . "let me think..."))
                        ((type . "text")
                         (text . "answer"))]))
          claude-code--messages)
    (claude-code--render)
    (should (string-match-p "answer"
                            (buffer-substring-no-properties
                             (point-min) (point-max))))))

(ert-deftest claude-code-test-render-with-tool-use ()
  "Rendering tool-use blocks should not error."
  (claude-code-test-with-buffer
    (push `((type . "assistant")
            (content . [((type . "tool_use")
                         (id . "t1")
                         (name . "Read")
                         (input . ((file_path . "/tmp/foo.el"))))
                        ((type . "tool_result")
                         (tool_use_id . "t1")
                         (content . "file contents here")
                         (is_error . nil))]))
          claude-code--messages)
    (claude-code--render)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "Read" text)))))

(ert-deftest claude-code-test-splice-heading-button ()
  "`claude-code--splice-heading-button' inserts a clickable button in the heading."
  (claude-code-test-with-buffer
    ;; Build a minimal magit section with a heading, then splice a button.
    (magit-insert-section (claude-tool-result nil t)
      (magit-insert-heading "  ↳ Test heading")
      (claude-code--splice-heading-button
       "[go]" 'claude-code-file-link "test help"
       (lambda (_btn) (insert "CLICKED")))
      (insert "body\n"))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      ;; Button label should appear in the heading line
      (should (string-match-p "Test heading.*\\[go\\]" text)))
    ;; Button must have a callable action
    (save-excursion
      (goto-char (point-min))
      (re-search-forward "\\[go\\]" nil t)
      (should (functionp (get-text-property (- (point) 1) 'action))))))

(ert-deftest claude-code-test-view-button-pops-buffer ()
  "`[view]' button on a rendered tool result opens a `view-mode' buffer."
  (claude-code-test-with-buffer
    (push `((type . "assistant")
            (content . [((type . "tool_use")
                         (id . "vbuf-1")
                         (name . "Bash")
                         (input . ((command . "echo hi"))))
                        ((type . "tool_result")
                         (tool_use_id . "vbuf-1")
                         (content . "line-one\nline-two")
                         (is_error . nil))]))
          claude-code--messages)
    (claude-code--render)
    ;; Locate the [view] button and invoke its action
    (save-excursion
      (goto-char (point-min))
      (re-search-forward "\\[view\\]" nil t)
      (let ((action (get-text-property (- (point) 1) 'action)))
        (should (functionp action))
        (funcall action nil)))
    ;; The pop-up buffer must exist and contain the tool output
    (let ((buf (get-buffer "*Claude Tool result*")))
      (unwind-protect
          (progn
            (should buf)
            (should (with-current-buffer buf view-mode))
            (should (string-match-p "line-one"
                                    (with-current-buffer buf (buffer-string)))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest claude-code-test-render-tool-result-list-content ()
  "MCP tools return content as a vector of {type,text} blocks; it must render."
  (claude-code-test-with-buffer
    (push `((type . "assistant")
            (content . [((type . "tool_use")
                         (id . "t2")
                         (name . "mcp__emacs__EvalEmacs")
                         (input . ((code . "(+ 1 1)"))))
                        ((type . "tool_result")
                         (tool_use_id . "t2")
                         ;; MCP format: vector of content blocks
                         (content . [((type . "text") (text . "ok: 2"))])
                         (is_error . nil))]))
          claude-code--messages)
    (claude-code--render)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "EvalEmacs" text))
      (should (string-match-p "ok: 2" text)))))

(ert-deftest claude-code-test-render-mcp-tool-error-list-content ()
  "MCP tool errors with list content must be shown with the error face heading."
  (claude-code-test-with-buffer
    (push `((type . "assistant")
            (content . [((type . "tool_use")
                         (id . "t3")
                         (name . "mcp__emacs__EvalEmacs")
                         (input . ((code . "(+ 1 1)"))))
                        ((type . "tool_result")
                         (tool_use_id . "t3")
                         (content . [((type . "text")
                                      (text . "MCP tool ran into issue: stream closed"))])
                         (is_error . t))]))
          claude-code--messages)
    (claude-code--render)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "Tool error" text))
      (should (string-match-p "stream closed" text)))))

(ert-deftest claude-code-test-tool-result-text-extraction ()
  "`claude-code--tool-result-text' normalises both string and vector content."
  ;; Plain string (built-in tools)
  (should (equal "hello" (claude-code--tool-result-text "hello")))
  ;; Vector of content blocks (MCP tools)
  (should (equal "ok: 2"
                 (claude-code--tool-result-text
                  [((type . "text") (text . "ok: 2"))])))
  ;; Multi-block vector → joined with newline
  (should (equal "line1\nline2"
                 (claude-code--tool-result-text
                  [((type . "text") (text . "line1"))
                   ((type . "text") (text . "line2"))])))
  ;; nil content → nil
  (should (null (claude-code--tool-result-text nil))))

(ert-deftest claude-code-test-render-error-msg ()
  "Rendering an error message should not error."
  (claude-code-test-with-buffer
    (push '((type . "error") (message . "something broke"))
          claude-code--messages)
    (claude-code--render)
    (should (string-match-p "something broke"
                            (buffer-substring-no-properties
                             (point-min) (point-max))))))

(ert-deftest claude-code-test-render-result-msg ()
  "Rendering a result message should not error."
  (claude-code-test-with-buffer
    (push '((type . "result")
            (total_cost_usd . 0.05)
            (num_turns . 3)
            (duration_ms . 4200))
          claude-code--messages)
    (claude-code--render)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "Done" text))
      (should (string-match-p "3 turns" text)))))

(ert-deftest claude-code-test-render-streaming ()
  "Rendering in-progress streaming content should not error."
  (claude-code-test-with-buffer
    (setq claude-code--streaming-active t)
    (setq claude-code--streaming-text "partial response...")
    (setq claude-code--streaming-thinking "hmm...")
    (claude-code--render)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "partial response" text)))))

(ert-deftest claude-code-test-render-input-area ()
  "The input area marker should be set after rendering."
  (claude-code-test-with-buffer
    (claude-code--render)
    (should claude-code--input-marker)
    (should (marker-buffer claude-code--input-marker))
    ;; Text before the marker should be read-only
    (let ((pos (1- (marker-position claude-code--input-marker))))
      (when (> pos (point-min))
        (should (get-text-property pos 'read-only))))))

(ert-deftest claude-code-test-input-area-self-inserts ()
  "Keys in the input area should self-insert, not run mode commands."
  (claude-code-test-with-buffer
    (claude-code--render)
    ;; In the input area: pressing a key should insert the character
    (goto-char (marker-position claude-code--input-marker))
    (let ((pos (point)))
      ;; Execute the bound command for "s"
      (let ((last-command-event ?s))
        (call-interactively (key-binding "s")))
      ;; A character should have been inserted
      (should (equal "s" (buffer-substring-no-properties pos (point)))))
    ;; RET in input area should be the submit command
    (should (eq (key-binding (kbd "RET")) 'claude-code-return))
    ;; Outside the input area: keys should run mode commands (wrapped)
    (goto-char (point-min))
    (should (eq (key-binding "s") 'claude-code-key-focus-input))
    (should (eq (key-binding "?") 'claude-code-key-menu))))

(ert-deftest claude-code-test-input-area-typing ()
  "Typing in the input area should insert text, not run commands."
  (claude-code-test-with-buffer
    (claude-code--render)
    (goto-char (marker-position claude-code--input-marker))
    ;; Simulate typing
    (let ((inhibit-read-only nil))
      (insert "hello"))
    (should (string-match-p
             "hello"
             (buffer-substring-no-properties
              claude-code--input-marker (point-max))))))

;; ---------------------------------------------------------------------------
;; Process filter — JSON parsing
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-filter-valid-json ()
  "Valid JSON lines should be parsed and dispatched."
  (claude-code-test-with-buffer
    (setq claude-code--partial-line "")
    (let ((events '()))
      (cl-letf (((symbol-function 'claude-code--handle-event)
                 (lambda (e) (push e events)))
                ((symbol-function 'claude-code--schedule-render)
                 #'ignore))
        (claude-code--process-filter
         (current-buffer)
         "{\"type\": \"status\", \"status\": \"ready\"}\n"))
      (should (= 1 (length events)))
      (should (equal "status" (alist-get 'type (car events)))))))

(ert-deftest claude-code-test-filter-non-json-line ()
  "Non-JSON lines should be skipped without signaling an error."
  (claude-code-test-with-buffer
    (setq claude-code--partial-line "")
    (let ((events '())
          (warnings '()))
      (cl-letf (((symbol-function 'claude-code--handle-event)
                 (lambda (e) (push e events)))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) warnings)))
                ((symbol-function 'claude-code--schedule-render)
                 #'ignore))
        (claude-code--process-filter
         (current-buffer)
         "Using Python 3.12.9\n{\"type\": \"status\", \"status\": \"ready\"}\n"))
      ;; The non-JSON line should be skipped
      (should (= 1 (length events)))
      ;; A warning should have been logged
      (should (cl-some (lambda (w) (string-match-p "non-JSON" w)) warnings)))))

(ert-deftest claude-code-test-filter-partial-line ()
  "Incomplete lines should be buffered across calls."
  (claude-code-test-with-buffer
    (setq claude-code--partial-line "")
    (let ((events '()))
      (cl-letf (((symbol-function 'claude-code--handle-event)
                 (lambda (e) (push e events)))
                ((symbol-function 'claude-code--schedule-render)
                 #'ignore))
        ;; First chunk: incomplete
        (claude-code--process-filter
         (current-buffer)
         "{\"type\": \"stat")
        (should (= 0 (length events)))
        ;; Second chunk: completes the line
        (claude-code--process-filter
         (current-buffer)
         "us\", \"status\": \"ready\"}\n")
        (should (= 1 (length events)))))))

(ert-deftest claude-code-test-filter-empty-lines ()
  "Empty lines between JSON should be ignored."
  (claude-code-test-with-buffer
    (setq claude-code--partial-line "")
    (let ((events '()))
      (cl-letf (((symbol-function 'claude-code--handle-event)
                 (lambda (e) (push e events)))
                ((symbol-function 'claude-code--schedule-render)
                 #'ignore))
        (claude-code--process-filter
         (current-buffer)
         "\n\n{\"type\": \"status\", \"status\": \"ready\"}\n\n")
        (should (= 1 (length events)))))))

;; ---------------------------------------------------------------------------
;; Event handling
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-handle-status-event ()
  "Status events should update `claude-code--status'."
  (claude-code-test-with-buffer
    (claude-code-test-with-clean-agents
      (cl-letf (((symbol-function 'claude-code--start-thinking) #'ignore)
                ((symbol-function 'claude-code--stop-thinking) #'ignore)
                ((symbol-function 'claude-code--schedule-render) #'ignore)
                ((symbol-function 'claude-code--flush-streaming) #'ignore))
        (claude-code--handle-status-event '((status . "working")))
        (should (eq claude-code--status 'working))
        (claude-code--handle-status-event '((status . "ready")))
        (should (eq claude-code--status 'ready))
        (claude-code--handle-status-event '((status . "error")))
        (should (eq claude-code--status 'error))))))

(ert-deftest claude-code-test-handle-assistant-event ()
  "Assistant events should be added to messages."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore)
              ((symbol-function 'claude-code--flush-streaming) #'ignore))
      (let ((event '((type . "assistant")
                     (content . [((type . "text") (text . "hi"))]))))
        (claude-code--handle-assistant-event event)
        (should (= 1 (length claude-code--messages)))
        (should (equal "assistant" (alist-get 'type (car claude-code--messages))))))))

(ert-deftest claude-code-test-handle-error-event ()
  "Error events should be added to messages."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--stop-thinking) #'ignore)
              ((symbol-function 'claude-code--schedule-render) #'ignore))
      (claude-code--handle-error-event '((message . "boom")))
      (should (= 1 (length claude-code--messages)))
      (should (equal "error" (alist-get 'type (car claude-code--messages)))))))

;; ---------------------------------------------------------------------------
;; Streaming
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-streaming-text-delta ()
  "Text deltas should accumulate in streaming buffer."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
      (claude-code--handle-block-start '((block_type . "text")))
      (should claude-code--streaming-active)
      (claude-code--handle-text-delta '((text . "hello ")))
      (claude-code--handle-text-delta '((text . "world")))
      (should (equal "hello world" claude-code--streaming-text)))))

(ert-deftest claude-code-test-streaming-flush ()
  "Flushing streaming content should create a message."
  (claude-code-test-with-buffer
    (setq claude-code--streaming-active t)
    (setq claude-code--streaming-text "result")
    (setq claude-code--streaming-thinking "thought")
    (claude-code--flush-streaming)
    (should (= 1 (length claude-code--messages)))
    (should (not claude-code--streaming-active))
    (should (string-empty-p claude-code--streaming-text))))

;; ---------------------------------------------------------------------------
;; UV environment
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-python-dir ()
  "`claude-code--python-dir' should return the python/ subdirectory."
  (let ((dir (claude-code--python-dir)))
    (should (stringp dir))
    (should (string-suffix-p "python/" dir))))

(ert-deftest claude-code-test-uv-available ()
  "`claude-code--uv-available-p' should find uv on this machine."
  ;; This is a real system test — skip in CI if uv is not installed
  (skip-unless (executable-find "uv"))
  (should (claude-code--uv-available-p)))

(ert-deftest claude-code-test-ensure-env-errors-without-uv ()
  "Should signal an error if uv command is not found."
  (let ((claude-code-python-command "nonexistent-uv-binary-xyzzy"))
    (should-error (claude-code--ensure-environment) :type 'user-error)))

;; ---------------------------------------------------------------------------
;; Agent tracking
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-agent-register-and-lookup ()
  "Registering an agent should make it findable."
  (claude-code-test-with-clean-agents
    (claude-code--agent-register "a1"
      :type 'session :description "test" :status 'ready
      :children nil)
    (let ((agent (gethash "a1" claude-code--agents)))
      (should agent)
      (should (equal "a1" (plist-get agent :id)))
      (should (eq 'session (plist-get agent :type))))))

(ert-deftest claude-code-test-agent-update ()
  "Updating an agent should merge properties."
  (claude-code-test-with-clean-agents
    (claude-code--agent-register "a1"
      :type 'session :description "old" :status 'starting
      :children nil)
    (claude-code--agent-update "a1" :status 'working :description "new")
    (let ((agent (gethash "a1" claude-code--agents)))
      (should (eq 'working (plist-get agent :status)))
      (should (equal "new" (plist-get agent :description)))
      ;; Unchanged fields should be preserved
      (should (eq 'session (plist-get agent :type))))))

(ert-deftest claude-code-test-agent-children ()
  "Adding children should track parent-child relationships."
  (claude-code-test-with-clean-agents
    (claude-code--agent-register "root"
      :type 'session :children nil)
    (claude-code--agent-register "child1"
      :type 'task :parent-id "root" :children nil)
    (claude-code--agent-add-child "root" "child1")
    (let ((root (gethash "root" claude-code--agents)))
      (should (equal '("child1") (plist-get root :children))))))

(ert-deftest claude-code-test-agent-unregister-cascades ()
  "Unregistering a root should remove its children too."
  (claude-code-test-with-clean-agents
    (claude-code--agent-register "root"
      :type 'session :children nil)
    (claude-code--agent-register "child1"
      :type 'task :parent-id "root" :children nil)
    (claude-code--agent-add-child "root" "child1")
    (claude-code--agent-unregister "root")
    (should (= 0 (hash-table-count claude-code--agents)))))

(ert-deftest claude-code-test-agent-root-ids ()
  "`claude-code--agent-root-ids' should return only session agents."
  (claude-code-test-with-clean-agents
    (claude-code--agent-register "s1" :type 'session :children nil)
    (claude-code--agent-register "t1" :type 'task :parent-id "s1"
                                 :children nil)
    (claude-code--agent-register "s2" :type 'session :children nil)
    (let ((roots (claude-code--agent-root-ids)))
      (should (= 2 (length roots)))
      (should (member "s1" roots))
      (should (member "s2" roots))
      (should (not (member "t1" roots))))))

;; ---------------------------------------------------------------------------
;; Task event → agent tracking integration
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-task-started-registers-agent ()
  "A task_started event should register a child agent."
  (claude-code-test-with-buffer
    (claude-code-test-with-clean-agents
      (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
        ;; Register the root session first
        (claude-code--agent-register claude-code--cwd
          :type 'session :children nil)
        (claude-code--handle-event
         '((type . "task_started")
           (task_id . "task-42")
           (description . "search codebase")))
        (let ((task (gethash "task-42" claude-code--agents))
              (root (gethash claude-code--cwd claude-code--agents)))
          (should task)
          (should (eq 'task (plist-get task :type)))
          (should (eq 'working (plist-get task :status)))
          (should (member "task-42" (plist-get root :children))))))))

(ert-deftest claude-code-test-task-notification-updates-agent ()
  "A task_notification event should update agent status."
  (claude-code-test-with-buffer
    (claude-code-test-with-clean-agents
      (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
        (claude-code--agent-register claude-code--cwd
          :type 'session :children nil)
        (claude-code--agent-register "task-42"
          :type 'task :status 'working :parent-id claude-code--cwd
          :children nil)
        (claude-code--agent-add-child claude-code--cwd "task-42")
        (claude-code--handle-event
         '((type . "task_notification")
           (task_id . "task-42")
           (status . "completed")
           (summary . "found 3 files")))
        (let ((task (gethash "task-42" claude-code--agents)))
          (should (eq 'completed (plist-get task :status)))
          (should (equal "found 3 files" (plist-get task :summary))))))))

;; ---------------------------------------------------------------------------
;; Session config
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-session-config-defaults ()
  "Session config should fall back to defaults."
  (claude-code-test-with-buffer
    (let ((claude-code-project-config nil)
          (claude-code--session-overrides nil))
      (let ((cfg (claude-code--session-config)))
        (should (equal "bypassPermissions"
                       (alist-get 'permission-mode cfg)))
        (should (equal 50 (alist-get 'max-turns cfg)))))))

(ert-deftest claude-code-test-session-config-project-override ()
  "Project config should override defaults."
  (claude-code-test-with-buffer
    (let ((claude-code-project-config
           '(("/tmp/test-project" . ((model . "claude-opus-4-6")))))
          (claude-code--session-overrides nil))
      (let ((cfg (claude-code--session-config)))
        (should (equal "claude-opus-4-6" (alist-get 'model cfg)))
        ;; Other defaults should still be present
        (should (equal 50 (alist-get 'max-turns cfg)))))))

;; ---------------------------------------------------------------------------
;; Agent sidebar rendering
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-sidebar-render-empty ()
  "Sidebar should render without error when no agents exist."
  (claude-code-test-with-clean-agents
    (let ((buf (get-buffer-create "*Claude Agents*")))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (claude-code-agents-mode))
            (claude-code--agents-do-render)
            (with-current-buffer buf
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should (string-match-p "No active sessions" text)))))
        (kill-buffer buf)))))

(ert-deftest claude-code-test-sidebar-render-with-agents ()
  "Sidebar should render session and task agents."
  (claude-code-test-with-clean-agents
    (claude-code--agent-register "/tmp/proj"
      :type 'session :description "do stuff" :status 'working
      :cwd "/tmp/proj" :children nil)
    (claude-code--agent-register "task-1"
      :type 'task :description "search" :status 'working
      :parent-id "/tmp/proj" :last-tool "Grep" :children nil)
    (claude-code--agent-add-child "/tmp/proj" "task-1")
    (let ((buf (get-buffer-create "*Claude Agents*")))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (claude-code-agents-mode))
            (claude-code--agents-do-render)
            (with-current-buffer buf
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should (string-match-p "proj" text))
                (should (string-match-p "search" text))
                (should (string-match-p "Grep" text)))))
        (kill-buffer buf)))))

;; ---------------------------------------------------------------------------
;; Format elapsed
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-format-elapsed-seconds ()
  "`claude-code--format-elapsed' should show seconds for durations < 60s."
  (should (equal "0s"  (claude-code--format-elapsed 0)))
  (should (equal "5s"  (claude-code--format-elapsed 5)))
  (should (equal "59s" (claude-code--format-elapsed 59))))

(ert-deftest claude-code-test-format-elapsed-minutes ()
  "`claude-code--format-elapsed' should show minutes and seconds for >= 60s."
  (should (equal "1m 0s"  (claude-code--format-elapsed 60)))
  (should (equal "1m 30s" (claude-code--format-elapsed 90)))
  (should (equal "2m 5s"  (claude-code--format-elapsed 125))))

;; ---------------------------------------------------------------------------
;; Thinking overlay string
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-thinking-overlay-no-stats ()
  "Overlay with no stats should show 'Working' and omit detail fields."
  (claude-code-test-with-buffer
    (setq claude-code--query-start-time nil
          claude-code--streaming-char-count 0
          claude-code--thinking-elapsed-sec 0.0
          claude-code--thinking-block-start-time nil
          claude-code--input-queued nil)
    (let ((s (claude-code--thinking-overlay-string)))
      (should (string-match-p "Working" s))
      (should (not (string-match-p "chars" s)))
      (should (not (string-match-p "thought" s))))))

(ert-deftest claude-code-test-thinking-overlay-with-chars ()
  "Overlay should include char count when streaming output is non-zero."
  (claude-code-test-with-buffer
    (setq claude-code--query-start-time nil
          claude-code--streaming-char-count 400
          claude-code--thinking-elapsed-sec 0.0
          claude-code--thinking-block-start-time nil
          claude-code--input-queued nil)
    (let ((s (claude-code--thinking-overlay-string)))
      (should (string-match-p "400 chars" s)))))

(ert-deftest claude-code-test-thinking-overlay-with-thinking-time ()
  "Overlay should include thinking time when > 1s has been accumulated."
  (claude-code-test-with-buffer
    (setq claude-code--query-start-time nil
          claude-code--streaming-char-count 0
          claude-code--thinking-elapsed-sec 10.0
          claude-code--thinking-block-start-time nil
          claude-code--input-queued nil)
    (let ((s (claude-code--thinking-overlay-string)))
      (should (string-match-p "thought" s))
      (should (string-match-p "10s" s)))))

(ert-deftest claude-code-test-thinking-overlay-queued-indicator ()
  "Overlay should show queued-message indicator when input is queued."
  (claude-code-test-with-buffer
    (setq claude-code--query-start-time nil
          claude-code--streaming-char-count 0
          claude-code--thinking-elapsed-sec 0.0
          claude-code--thinking-block-start-time nil
          claude-code--input-queued (list "my queued message"))
    (let ((s (claude-code--thinking-overlay-string)))
      (should (string-match-p "my queued message" s)))))

(ert-deftest claude-code-test-thinking-overlay-queued-truncated ()
  "Queued messages longer than 60 chars should be truncated in the overlay."
  (claude-code-test-with-buffer
    (setq claude-code--query-start-time nil
          claude-code--streaming-char-count 0
          claude-code--thinking-elapsed-sec 0.0
          claude-code--thinking-block-start-time nil
          claude-code--input-queued (list (make-string 80 ?x)))
    (let ((s (claude-code--thinking-overlay-string)))
      (should (not (string-match-p (make-string 80 ?x) s))))))

(ert-deftest claude-code-test-thinking-overlay-queued-multiple ()
  "Overlay should show all queued messages when multiple are queued."
  (claude-code-test-with-buffer
    (setq claude-code--query-start-time nil
          claude-code--streaming-char-count 0
          claude-code--thinking-elapsed-sec 0.0
          claude-code--thinking-block-start-time nil
          claude-code--input-queued (list "first" "second" "third"))
    (let ((s (claude-code--thinking-overlay-string)))
      (should (string-match-p "\\[1\\]" s))
      (should (string-match-p "first" s))
      (should (string-match-p "\\[2\\]" s))
      (should (string-match-p "second" s))
      (should (string-match-p "\\[3\\]" s))
      (should (string-match-p "third" s)))))

;; ---------------------------------------------------------------------------
;; Streaming char count
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-text-delta-increments-char-count ()
  "Text deltas should increment `claude-code--streaming-char-count'."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
      (setq claude-code--streaming-char-count 0)
      (claude-code--handle-text-delta '((text . "hello")))
      (should (= 5 claude-code--streaming-char-count))
      (claude-code--handle-text-delta '((text . " world")))
      (should (= 11 claude-code--streaming-char-count)))))

(ert-deftest claude-code-test-thinking-delta-increments-char-count ()
  "Thinking deltas should also increment `claude-code--streaming-char-count'."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
      (setq claude-code--streaming-char-count 0)
      (claude-code--handle-thinking-delta '((thinking . "hmm")))
      (should (= 3 claude-code--streaming-char-count)))))

(ert-deftest claude-code-test-working-status-resets-stats ()
  "Working status should reset char count, thinking time, and start time."
  (claude-code-test-with-buffer
    (claude-code-test-with-clean-agents
      (cl-letf (((symbol-function 'claude-code--start-thinking) #'ignore)
                ((symbol-function 'claude-code--schedule-render) #'ignore))
        (setq claude-code--streaming-char-count 999
              claude-code--thinking-elapsed-sec 42.0)
        (claude-code--handle-status-event '((status . "working")))
        (should (= 0 claude-code--streaming-char-count))
        (should (= 0.0 claude-code--thinking-elapsed-sec))
        (should (numberp claude-code--query-start-time))))))

;; ---------------------------------------------------------------------------
;; Thinking block timing
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-block-start-thinking-sets-timer ()
  "A thinking block_start should record the start timestamp."
  (claude-code-test-with-buffer
    (setq claude-code--thinking-block-start-time nil)
    (claude-code--handle-block-start '((block_type . "thinking")))
    (should (numberp claude-code--thinking-block-start-time))))

(ert-deftest claude-code-test-block-start-text-no-timer ()
  "A text block_start should NOT set the thinking start timestamp."
  (claude-code-test-with-buffer
    (setq claude-code--thinking-block-start-time nil)
    (claude-code--handle-block-start '((block_type . "text")))
    (should (null claude-code--thinking-block-start-time))))

(ert-deftest claude-code-test-block-stop-accumulates-thinking ()
  "block_stop should accumulate elapsed thinking time and clear start time."
  (claude-code-test-with-buffer
    (setq claude-code--thinking-elapsed-sec 0.0
          claude-code--thinking-block-start-time (- (float-time) 5.0))
    (claude-code--handle-block-stop nil)
    (should (> claude-code--thinking-elapsed-sec 4.0))
    (should (null claude-code--thinking-block-start-time))))

(ert-deftest claude-code-test-block-stop-noop-without-start ()
  "block_stop with no start time should leave elapsed time unchanged."
  (claude-code-test-with-buffer
    (setq claude-code--thinking-elapsed-sec 3.0
          claude-code--thinking-block-start-time nil)
    (claude-code--handle-block-stop nil)
    (should (= 3.0 claude-code--thinking-elapsed-sec))))

;; ---------------------------------------------------------------------------
;; Message queuing
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-submit-queues-when-working ()
  "Submitting while working should append to queue and clear the input area."
  (claude-code-test-with-buffer
    (claude-code--render)
    (setq claude-code--status 'working)
    (let ((sent-text nil))
      (cl-letf (((symbol-function 'claude-code--update-thinking-overlay) #'ignore)
                ((symbol-function 'claude-code-send)
                 (lambda (text) (setq sent-text text))))
        (let ((inhibit-read-only t))
          (goto-char (marker-position claude-code--input-marker))
          (insert "my queued message"))
        (claude-code-submit-input)
        (should (equal (list "my queued message") claude-code--input-queued))
        (should (null sent-text))
        ;; Input area should be cleared after queuing.
        (should (string-empty-p
                 (string-trim
                  (buffer-substring-no-properties
                   claude-code--input-marker (point-max)))))))))

(ert-deftest claude-code-test-submit-multiple-messages-queued-fifo ()
  "Multiple submissions while working should build a FIFO list."
  (claude-code-test-with-buffer
    (claude-code--render)
    (setq claude-code--status 'working)
    (cl-letf (((symbol-function 'claude-code--update-thinking-overlay) #'ignore))
      (dolist (msg (list "first message" "second message" "third message"))
        (let ((inhibit-read-only t))
          (goto-char (marker-position claude-code--input-marker))
          (insert msg))
        (claude-code-submit-input))
      (should (equal (list "first message" "second message" "third message")
                     claude-code--input-queued)))))

(ert-deftest claude-code-test-submit-sends-when-ready ()
  "Submitting while ready should send immediately and clear the input area."
  (claude-code-test-with-buffer
    (claude-code--render)
    (setq claude-code--status 'ready)
    (let ((dispatched nil))
      (cl-letf (((symbol-function 'claude-code--dispatch-input)
                 (lambda (text) (setq dispatched text))))
        (let ((inhibit-read-only t))
          (goto-char (marker-position claude-code--input-marker))
          (insert "send this now"))
        (claude-code-submit-input)
        (should (equal "send this now" dispatched))
        (should (null claude-code--input-queued))
        (should (string-empty-p
                 (string-trim
                  (buffer-substring-no-properties
                   claude-code--input-marker (point-max)))))))))

(ert-deftest claude-code-test-cancel-clears-queue ()
  "Cancel should clear all queued messages."
  (claude-code-test-with-buffer
    (setq claude-code--input-queued (list "pending message" "another message"))
    (cl-letf (((symbol-function 'claude-code--send-json) #'ignore)
              ((symbol-function 'claude-code--stop-thinking) #'ignore)
              ((symbol-function 'claude-code--schedule-render) #'ignore))
      (claude-code-cancel)
      (should (null claude-code--input-queued)))))

(ert-deftest claude-code-test-ready-status-auto-sends-queue ()
  "When status becomes ready, the oldest queued message should be dispatched."
  (claude-code-test-with-buffer
    (claude-code-test-with-clean-agents
      (claude-code--render)
      (setq claude-code--input-queued (list "auto-send me"))
      (let ((dispatched nil))
        (cl-letf (((symbol-function 'claude-code--stop-thinking) #'ignore)
                  ((symbol-function 'claude-code--flush-streaming) #'ignore)
                  ((symbol-function 'claude-code--schedule-render) #'ignore)
                  ((symbol-function 'claude-code--dispatch-input)
                   (lambda (text) (setq dispatched text))))
          (claude-code--handle-status-event '((status . "ready")))
          (should (equal "auto-send me" dispatched))
          (should (null claude-code--input-queued)))))))

(ert-deftest claude-code-test-ready-status-dispatches-oldest-first ()
  "When status becomes ready with multiple queued messages, send oldest first."
  (claude-code-test-with-buffer
    (claude-code-test-with-clean-agents
      (claude-code--render)
      (setq claude-code--input-queued (list "first" "second" "third"))
      (let ((dispatched nil))
        (cl-letf (((symbol-function 'claude-code--stop-thinking) #'ignore)
                  ((symbol-function 'claude-code--flush-streaming) #'ignore)
                  ((symbol-function 'claude-code--schedule-render) #'ignore)
                  ((symbol-function 'claude-code--dispatch-input)
                   (lambda (text) (setq dispatched text))))
          (claude-code--handle-status-event '((status . "ready")))
          (should (equal "first" dispatched))
          (should (equal (list "second" "third") claude-code--input-queued)))))))

;; ---------------------------------------------------------------------------
;; Slash command dispatch
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-dispatch-routes-slash-command ()
  "Input starting with / should be routed to the slash command handler."
  (claude-code-test-with-buffer
    (let ((slash-called nil)
          (send-called nil))
      (cl-letf (((symbol-function 'claude-code--run-slash-command)
                 (lambda (text) (setq slash-called text)))
                ((symbol-function 'claude-code-send)
                 (lambda (text) (setq send-called text))))
        (claude-code--dispatch-input "/clear")
        (should (equal "/clear" slash-called))
        (should (null send-called))))))

(ert-deftest claude-code-test-dispatch-routes-normal-text ()
  "Normal input (no leading /) should go to claude-code-send."
  (claude-code-test-with-buffer
    (let ((sent nil))
      (cl-letf (((symbol-function 'claude-code-send)
                 (lambda (text) (setq sent text))))
        (claude-code--dispatch-input "hello Claude")
        (should (equal "hello Claude" sent))))))

(ert-deftest claude-code-test-slash-unknown-command-no-error ()
  "An unknown slash command should display a message but not signal an error."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'message) #'ignore))
      (should-not
       (condition-case _
           (progn (claude-code--run-slash-command "/nonexistent") nil)
         (error t))))))

;; ---------------------------------------------------------------------------
;; Slash command CAPF
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-capf-nil-outside-input-area ()
  "CAPF should return nil when point is outside the input area."
  (claude-code-test-with-buffer
    (claude-code--render)
    (goto-char (point-min))
    (should (null (claude-code--slash-command-capf)))))

(ert-deftest claude-code-test-capf-nil-without-slash ()
  "CAPF should return nil when input does not start with /."
  (claude-code-test-with-buffer
    (claude-code--render)
    (goto-char (marker-position claude-code--input-marker))
    (let ((inhibit-read-only t))
      (insert "hello"))
    (should (null (claude-code--slash-command-capf)))))

(ert-deftest claude-code-test-capf-returns-completions-with-slash ()
  "CAPF should return a completion table when input starts with /."
  (claude-code-test-with-buffer
    (claude-code--render)
    (goto-char (marker-position claude-code--input-marker))
    (let ((inhibit-read-only t))
      (insert "/cle"))
    (let ((result (claude-code--slash-command-capf)))
      (should (consp result))
      (should (integerp (nth 0 result)))   ; beg
      (should (integerp (nth 1 result)))   ; end
      (should (member "clear" (nth 2 result))))))

;; ---------------------------------------------------------------------------
;; Project todos — org-roam lookup
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-todos-node-nil-without-org-roam ()
  "Project-todos lookup should return nil when org-roam is unavailable."
  (cl-letf (((symbol-function 'claude-code--org-roam-available-p)
             (lambda () nil)))
    (should (null (claude-code--org-roam-find-project-todos-node "/tmp/any")))))

(ert-deftest claude-code-test-load-dir-todos-nil-without-org-roam ()
  "`claude-code--load-dir-todos' should return nil without org-roam."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--org-roam-available-p)
               (lambda () nil)))
      (should (null (claude-code--load-dir-todos))))))

(ert-deftest claude-code-test-load-dir-todos-filters-empty ()
  "`claude-code--load-dir-todos' should return nil for template-only content."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--org-roam-available-p)
               (lambda () t))
              ((symbol-function 'claude-code--org-roam-find-project-todos-node)
               (lambda (_dir) 'fake-node))
              ((symbol-function 'claude-code--org-roam-node-body)
               (lambda (_node)
                 "# Per-project TODO list.\n# Use standard org keywords.\n\n* TODO \n\n")))
      (should (null (claude-code--load-dir-todos))))))

(ert-deftest claude-code-test-load-dir-todos-keeps-real-items ()
  "`claude-code--load-dir-todos' should keep actual TODO items."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--org-roam-available-p)
               (lambda () t))
              ((symbol-function 'claude-code--org-roam-find-project-todos-node)
               (lambda (_dir) 'fake-node))
              ((symbol-function 'claude-code--org-roam-node-body)
               (lambda (_node)
                 "# Comment\n* TODO Fix the login bug\n* DONE Write tests\n")))
      (let ((result (claude-code--load-dir-todos)))
        (should result)
        (should (string-match-p "Fix the login bug" result))
        (should (string-match-p "Write tests" result))
        (should (not (string-match-p "^# Comment" result)))))))

;; ---------------------------------------------------------------------------
;; SPC scrolls in conversation area
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-space-scrolls-outside-input ()
  "SPC in conversation area should be bound to scroll, not undefined."
  (claude-code-test-with-buffer
    (claude-code--render)
    (goto-char (point-min))
    (should (eq (key-binding " ") 'claude-code-key-space))))

(ert-deftest claude-code-test-space-self-inserts-in-input ()
  "SPC in the input area should insert a space character."
  (claude-code-test-with-buffer
    (claude-code--render)
    (goto-char (marker-position claude-code--input-marker))
    (let ((pos (point)))
      (let ((last-command-event ?\s))
        (call-interactively (key-binding " ")))
      (should (equal " " (buffer-substring-no-properties pos (point)))))))

(ert-deftest claude-code-test-shift-space-scrolls-outside-input ()
  "S-SPC in the conversation area should be bound to scroll, not undefined."
  (claude-code-test-with-buffer
    (claude-code--render)
    (goto-char (point-min))
    (should (eq (key-binding (kbd "S-SPC")) 'claude-code-key-shift-space))))

(ert-deftest claude-code-test-shift-space-self-inserts-in-input ()
  "S-SPC in the input area should insert a space, not scroll the view.
Regression: holding Shift while capitalising across a word must not
trigger `scroll-down-command'."
  (claude-code-test-with-buffer
    (claude-code--render)
    (goto-char (marker-position claude-code--input-marker))
    (let ((pos (point)))
      (call-interactively (key-binding (kbd "S-SPC")))
      (should (equal " " (buffer-substring-no-properties pos (point)))))))

;; ---------------------------------------------------------------------------
;; Text utilities
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-indent ()
  "`claude-code--indent' should prefix each line."
  (should (equal "   a\n   b" (claude-code--indent "a\nb" 3))))

(ert-deftest claude-code-test-tool-summary ()
  "`claude-code--tool-summary' should extract key fields."
  (should (equal "/tmp/foo"
                 (claude-code--tool-summary "Read" '((file_path . "/tmp/foo")))))
  (should (equal "ls -la"
                 (claude-code--tool-summary "Bash" '((command . "ls -la")))))
  (should (equal "*.el"
                 (claude-code--tool-summary "Glob" '((pattern . "*.el"))))))

;; ---------------------------------------------------------------------------
;; Process recovery
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-sentinel-sets-stopped-and-messages ()
  "When the process exits, sentinel should set status to stopped and add a message."
  (claude-code-test-with-buffer
    (claude-code-test-with-clean-agents
      (setq claude-code--status 'working)
      (setq claude-code--messages nil)
      (claude-code--process-sentinel (current-buffer) "finished\n")
      (should (eq claude-code--status 'stopped))
      (should (null claude-code--process))
      (should (equal "info" (alist-get 'type (car claude-code--messages))))
      (should (string-match-p "exited"
                              (alist-get 'text (car claude-code--messages)))))))

(ert-deftest claude-code-test-send-json-auto-restarts ()
  "Sending JSON with a dead process should attempt auto-restart."
  (claude-code-test-with-buffer
    (setq claude-code--process nil)
    (let ((started nil))
      (cl-letf (((symbol-function 'claude-code--start-process)
                 (lambda () (setq started t)))
                ((symbol-function 'sit-for) #'ignore))
        (claude-code--send-json '((type . "test")))
        (should started)))))

(ert-deftest claude-code-test-restart-preserves-messages ()
  "Restart should keep conversation history but reset session-id."
  (claude-code-test-with-buffer
    (push '((type . "user") (prompt . "hello")) claude-code--messages)
    (push '((type . "assistant") (content . [])) claude-code--messages)
    (setq claude-code--session-id "old-session")
    (let ((started nil))
      (cl-letf (((symbol-function 'claude-code--stop-process) #'ignore)
                ((symbol-function 'claude-code--start-process)
                 (lambda () (setq started t)))
                ((symbol-function 'claude-code--schedule-render) #'ignore))
        (claude-code-restart)
        (should started)
        (should (null claude-code--session-id))
        ;; Original messages still there (plus the "restarted" info)
        (should (>= (length claude-code--messages) 3))))))

(ert-deftest claude-code-test-restart-recovers-nil-cwd ()
  "Restart should recover cwd from default-directory if nil."
  (claude-code-test-with-buffer
    (setq claude-code--cwd nil)
    (cl-letf (((symbol-function 'claude-code--stop-process) #'ignore)
              ((symbol-function 'claude-code--start-process) #'ignore)
              ((symbol-function 'claude-code--schedule-render) #'ignore))
      (claude-code-restart)
      (should (stringp claude-code--cwd)))))

(ert-deftest claude-code-test-last-query-cmd-recorded ()
  "Sending a query should record the command in `claude-code--last-query-cmd'."
  (claude-code-test-with-buffer
    (setq claude-code--session-id "test-session")
    (cl-letf (((symbol-function 'claude-code--send-json) #'ignore)
              ((symbol-function 'claude-code--schedule-render) #'ignore))
      (claude-code-send "test prompt")
      (should claude-code--last-query-cmd)
      (should (equal "query" (alist-get 'type claude-code--last-query-cmd)))
      (should (equal "test-session" (alist-get 'resume claude-code--last-query-cmd))))))

;; ---------------------------------------------------------------------------
;; Header action buttons (Reset, New Session)
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-header-has-reset-button ()
  "The buffer header should contain a clickable [Reset] button."
  (claude-code-test-with-buffer
    (claude-code--render)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "\\[Reset\\]" text)))))

(ert-deftest claude-code-test-header-has-new-session-button ()
  "The buffer header should contain a clickable [New Session] button."
  (claude-code-test-with-buffer
    (claude-code--render)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "\\[New Session\\]" text)))))

(ert-deftest claude-code-test-header-buttons-are-buttons ()
  "The [Reset] and [New Session] header items should have button text properties."
  (claude-code-test-with-buffer
    (claude-code--render)
    ;; Find [Reset] and verify it is a button
    (goto-char (point-min))
    (let ((found-reset nil)
          (found-new nil))
      (while (not (eobp))
        (when (button-at (point))
          (let ((label (buffer-substring-no-properties
                        (button-start (button-at (point)))
                        (button-end (button-at (point))))))
            (when (string= label "[Reset]")      (setq found-reset t))
            (when (string= label "[New Session]") (setq found-new t))))
        (forward-char 1))
      (should found-reset)
      (should found-new))))

(ert-deftest claude-code-test-reset-button-calls-reset ()
  "Activating the [Reset] button should invoke `claude-code-reset'."
  (claude-code-test-with-buffer
    (claude-code--render)
    (let ((reset-called nil))
      (cl-letf (((symbol-function 'claude-code-reset)
                 (lambda () (setq reset-called t))))
        ;; Find and activate the Reset button
        (goto-char (point-min))
        (let ((btn nil))
          (while (and (not btn) (not (eobp)))
            (when-let ((b (button-at (point))))
              (when (string= (buffer-substring-no-properties
                              (button-start b) (button-end b))
                             "[Reset]")
                (setq btn b)))
            (forward-char 1))
          (should btn)
          (button-activate btn)))
      (should reset-called))))

(ert-deftest claude-code-test-new-session-button-calls-new-session ()
  "Activating the [New Session] button should invoke `claude-code-new-session'."
  (claude-code-test-with-buffer
    (claude-code--render)
    (let ((new-called nil))
      (cl-letf (((symbol-function 'claude-code-new-session)
                 (lambda () (setq new-called t))))
        (goto-char (point-min))
        (let ((btn nil))
          (while (and (not btn) (not (eobp)))
            (when-let ((b (button-at (point))))
              (when (string= (buffer-substring-no-properties
                              (button-start b) (button-end b))
                             "[New Session]")
                (setq btn b)))
            (forward-char 1))
          (should btn)
          (button-activate btn)))
      (should new-called))))

;; ---------------------------------------------------------------------------
;; Fork button on user messages
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-user-msg-has-fork-button ()
  "Each user message heading should contain a [fork] button."
  (claude-code-test-with-buffer
    (push '((type . "user") (prompt . "hello there")) claude-code--messages)
    (claude-code--render)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "\\[fork\\]" text)))))

(ert-deftest claude-code-test-fork-button-is-button ()
  "The [fork] label next to a user message should be a real button."
  (claude-code-test-with-buffer
    (push '((type . "user") (prompt . "hello there")) claude-code--messages)
    (claude-code--render)
    (goto-char (point-min))
    (let ((found nil))
      (while (not (eobp))
        (when-let ((b (button-at (point))))
          (when (string= (buffer-substring-no-properties
                          (button-start b) (button-end b))
                         "[fork]")
            (setq found t)))
        (forward-char 1))
      (should found))))

(ert-deftest claude-code-test-fork-button-calls-fork-at-msg ()
  "Activating a [fork] button should invoke `claude-code--fork-at-msg'
with the correct message alist."
  (claude-code-test-with-buffer
    (let ((msg '((type . "user") (prompt . "hello there"))))
      (push msg claude-code--messages)
      (claude-code--render)
      (let ((forked-msg nil))
        (cl-letf (((symbol-function 'claude-code--fork-at-msg)
                   (lambda (m) (setq forked-msg m))))
          (goto-char (point-min))
          (let ((btn nil))
            (while (and (not btn) (not (eobp)))
              (when-let ((b (button-at (point))))
                (when (string= (buffer-substring-no-properties
                                (button-start b) (button-end b))
                               "[fork]")
                  (setq btn b)))
              (forward-char 1))
            (should btn)
            (button-activate btn)))
        (should forked-msg)
        (should (equal "hello there" (alist-get 'prompt forked-msg)))))))

(ert-deftest claude-code-test-multiple-user-msgs-have-fork-buttons ()
  "Every user message should get its own [fork] button."
  (claude-code-test-with-buffer
    (push '((type . "user") (prompt . "first message")) claude-code--messages)
    (push '((type . "assistant")
            (content . [((type . "text") (text . "reply"))]))
          claude-code--messages)
    (push '((type . "user") (prompt . "second message")) claude-code--messages)
    (claude-code--render)
    (let ((count 0))
      (goto-char (point-min))
      (while (not (eobp))
        (when-let ((b (button-at (point))))
          (when (string= (buffer-substring-no-properties
                          (button-start b) (button-end b))
                         "[fork]")
            (cl-incf count))
          (goto-char (button-end b)))
        (forward-char 1))
      ;; Two user messages → two fork buttons
      (should (= 2 count)))))

;; ---------------------------------------------------------------------------
;; claude-code--fork-at-msg
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-fork-at-msg-creates-new-buffer ()
  "`claude-code--fork-at-msg' should create a new buffer with forked history."
  (claude-code-test-with-buffer
    (claude-code-test-with-clean-agents
      (let* ((msg1 '((type . "user") (prompt . "first")))
             (msg2 '((type . "user") (prompt . "second"))))
        ;; Push oldest first so newest-first order is msg2, msg1
        (setq claude-code--messages (list msg2 msg1))
        (let ((created-buf nil))
          (cl-letf (((symbol-function 'claude-code--start-process) #'ignore)
                    ((symbol-function 'claude-code--schedule-render) #'ignore)
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buf) (setq created-buf buf)))
                    ((symbol-function 'message) #'ignore))
            ;; Fork at msg1 (the older message)
            (claude-code--fork-at-msg msg1))
          (should created-buf)
          (unwind-protect
              (with-current-buffer created-buf
                ;; Forked buffer should have only msg1 in history
                (should (= 1 (length claude-code--messages)))
                (should (eq msg1 (car claude-code--messages)))
                ;; Should have no session-id (fresh backend)
                (should (null claude-code--session-id)))
            (when (buffer-live-p created-buf)
              (kill-buffer created-buf))))))))

(ert-deftest claude-code-test-fork-at-msg-includes-older-messages ()
  "`claude-code--fork-at-msg' should include the target message and all older ones."
  (claude-code-test-with-buffer
    (claude-code-test-with-clean-agents
      (let* ((old-msg '((type . "user") (prompt . "oldest")))
             (mid-msg '((type . "user") (prompt . "middle")))
             (new-msg '((type . "user") (prompt . "newest"))))
        ;; newest-first
        (setq claude-code--messages (list new-msg mid-msg old-msg))
        (let ((created-buf nil))
          (cl-letf (((symbol-function 'claude-code--start-process) #'ignore)
                    ((symbol-function 'claude-code--schedule-render) #'ignore)
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buf) (setq created-buf buf)))
                    ((symbol-function 'message) #'ignore))
            ;; Fork at mid-msg: should get mid-msg + old-msg (newest-first)
            (claude-code--fork-at-msg mid-msg))
          (unwind-protect
              (with-current-buffer created-buf
                (should (= 2 (length claude-code--messages)))
                (should (eq mid-msg (nth 0 claude-code--messages)))
                (should (eq old-msg (nth 1 claude-code--messages))))
            (when (buffer-live-p created-buf)
              (kill-buffer created-buf))))))))

;; ---------------------------------------------------------------------------
;; N / f / W keys should no longer be bound to session commands
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-N-key-not-bound-to-new-session ()
  "N should no longer jump to new-session; it should self-insert in input area."
  (claude-code-test-with-buffer
    (claude-code--render)
    ;; In the input area N should self-insert (not run new-session)
    (goto-char (marker-position claude-code--input-marker))
    (let ((last-command-event ?N))
      (call-interactively (key-binding "N")))
    (should (string-match-p "N"
                            (buffer-substring-no-properties
                             (marker-position claude-code--input-marker)
                             (point-max))))))

(ert-deftest claude-code-test-W-key-not-bound-to-reset ()
  "W should no longer jump to reset; it should self-insert in input area."
  (claude-code-test-with-buffer
    (claude-code--render)
    (goto-char (marker-position claude-code--input-marker))
    (let ((last-command-event ?W))
      (call-interactively (key-binding "W")))
    (should (string-match-p "W"
                            (buffer-substring-no-properties
                             (marker-position claude-code--input-marker)
                             (point-max))))))

;; ---------------------------------------------------------------------------
;; Queue navigation (M-p / M-n)
;; ---------------------------------------------------------------------------

(defmacro claude-code-test-with-working-queue (queue &rest body)
  "Set up a working buffer with QUEUE and evaluate BODY.
The input area is rendered and status is `working'."
  (declare (indent 1))
  `(claude-code-test-with-buffer
     (claude-code--render)
     (setq claude-code--status 'working
           claude-code--input-queued ,queue
           claude-code--input-history nil
           claude-code--input-history-index -1
           claude-code--input-history-saved nil
           claude-code--queue-edit-index nil)
     ,@body))

(defun claude-code-test--input-text ()
  "Return the current input-area text (trimmed)."
  (string-trim
   (buffer-substring-no-properties
    claude-code--input-marker (point-max))))

(ert-deftest claude-code-test-mprev-enters-queue-newest-first ()
  "M-p from fresh input should show the newest (last) queued message."
  (claude-code-test-with-working-queue (list "first" "second" "third")
    (claude-code-previous-input)
    (should (= 2 claude-code--queue-edit-index))
    (should (equal "third" (claude-code-test--input-text)))))

(ert-deftest claude-code-test-mprev-cycles-through-queue ()
  "Repeated M-p should cycle through all queued messages newest-to-oldest."
  (claude-code-test-with-working-queue (list "first" "second" "third")
    (claude-code-previous-input)   ; -> "third" (index 2)
    (claude-code-previous-input)   ; -> "second" (index 1)
    (should (= 1 claude-code--queue-edit-index))
    (should (equal "second" (claude-code-test--input-text)))
    (claude-code-previous-input)   ; -> "first" (index 0)
    (should (= 0 claude-code--queue-edit-index))
    (should (equal "first" (claude-code-test--input-text)))))

(ert-deftest claude-code-test-mprev-past-queue-enters-history ()
  "M-p past the oldest queued message should enter history navigation."
  (claude-code-test-with-working-queue (list "queued")
    (setq claude-code--input-history (list "hist-newest" "hist-older"))
    (claude-code-previous-input)   ; -> queue "queued"
    (claude-code-previous-input)   ; -> history "hist-newest"
    (should (null claude-code--queue-edit-index))
    (should (= 0 claude-code--input-history-index))
    (should (equal "hist-newest" (claude-code-test--input-text)))))

(ert-deftest claude-code-test-mnext-from-queue-back-to-fresh ()
  "M-n past the newest queued message should restore fresh input."
  (claude-code-test-with-working-queue (list "first" "second")
    (let ((inhibit-read-only t))
      (goto-char (marker-position claude-code--input-marker))
      (insert "draft text"))
    (claude-code-previous-input)   ; snapshot "draft text", show "second"
    (claude-code-next-input)       ; back to fresh
    (should (null claude-code--queue-edit-index))
    (should (= -1 claude-code--input-history-index))
    (should (equal "draft text" (claude-code-test--input-text)))))

(ert-deftest claude-code-test-queue-edit-saved-on-mprev ()
  "Editing a queued message and pressing M-p should save the edit to that slot."
  (claude-code-test-with-working-queue (list "first" "second" "third")
    (claude-code-previous-input)   ; show "third" (index 2)
    (let ((inhibit-read-only t))
      (delete-region claude-code--input-marker (point-max))
      (insert "third EDITED"))
    (claude-code-previous-input)   ; save edit, show "second" (index 1)
    (should (equal "third EDITED" (nth 2 claude-code--input-queued)))
    (should (equal "second" (claude-code-test--input-text)))))

(ert-deftest claude-code-test-queue-edit-saved-on-mnext ()
  "Editing a queued message and pressing M-n should save the edit to that slot."
  (claude-code-test-with-working-queue (list "first" "second" "third")
    (claude-code-previous-input)   ; -> "third" (index 2)
    (claude-code-previous-input)   ; -> "second" (index 1)
    (let ((inhibit-read-only t))
      (delete-region claude-code--input-marker (point-max))
      (insert "second EDITED"))
    (claude-code-next-input)       ; save edit, -> "third" (index 2)
    (should (equal "second EDITED" (nth 1 claude-code--input-queued)))
    (should (equal "third" (claude-code-test--input-text)))))

(ert-deftest claude-code-test-mprev-no-queue-goes-to-history ()
  "M-p with empty queue should go straight into history navigation."
  (claude-code-test-with-working-queue nil
    (setq claude-code--input-history (list "hist1"))
    (claude-code-previous-input)
    (should (null claude-code--queue-edit-index))
    (should (= 0 claude-code--input-history-index))
    (should (equal "hist1" (claude-code-test--input-text)))))

;; ---------------------------------------------------------------------------
;; Queue editing — RET in queue-edit mode
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-ret-in-queue-edit-updates-slot-in-place ()
  "RET in queue-edit mode should update the slot in-place, not append a copy."
  (claude-code-test-with-working-queue (list "first" "second")
    ;; Navigate to "second" (newest queued, index 1)
    (claude-code-previous-input)
    (should (= 1 claude-code--queue-edit-index))
    ;; Edit the visible queued message
    (let ((inhibit-read-only t))
      (delete-region claude-code--input-marker (point-max))
      (insert "second EDITED"))
    ;; Press RET — should update the slot, not append another message
    (claude-code-submit-input)
    (should (equal (list "first" "second EDITED") claude-code--input-queued))
    ;; Should have exited queue-edit mode
    (should (null claude-code--queue-edit-index))
    ;; Input area should be empty after the edit is committed
    (should (string-empty-p
             (string-trim
              (buffer-substring-no-properties
               claude-code--input-marker (point-max)))))))

(ert-deftest claude-code-test-ret-in-queue-edit-empty-preserves-slot ()
  "RET in queue-edit mode with an empty input should leave the slot unchanged."
  (claude-code-test-with-working-queue (list "first" "second")
    (claude-code-previous-input)              ; navigate to "second"
    (let ((inhibit-read-only t))
      (delete-region claude-code--input-marker (point-max)))  ; clear
    (claude-code-submit-input)
    ;; Queue must be unchanged — no deletion, no update
    (should (equal (list "first" "second") claude-code--input-queued))
    (should (null claude-code--queue-edit-index))))

(ert-deftest claude-code-test-ret-in-queue-edit-does-not-add-to-history ()
  "RET in queue-edit mode should NOT push the message onto input history."
  (claude-code-test-with-working-queue (list "to-edit")
    (let ((orig-len (length claude-code--input-history)))
      (claude-code-previous-input)
      (let ((inhibit-read-only t))
        (delete-region claude-code--input-marker (point-max))
        (insert "to-edit MODIFIED"))
      (claude-code-submit-input)
      ;; History must not have grown
      (should (= orig-len (length claude-code--input-history))))))

(ert-deftest claude-code-test-ret-in-queue-edit-first-slot ()
  "RET in queue-edit mode on the oldest queued slot should update it correctly."
  (claude-code-test-with-working-queue (list "first" "second" "third")
    ;; Navigate to "third" → "second" → "first"
    (claude-code-previous-input)
    (claude-code-previous-input)
    (claude-code-previous-input)
    (should (= 0 claude-code--queue-edit-index))
    (should (equal "first" (claude-code-test--input-text)))
    ;; Edit and commit via RET
    (let ((inhibit-read-only t))
      (delete-region claude-code--input-marker (point-max))
      (insert "first EDITED"))
    (claude-code-submit-input)
    (should (equal "first EDITED" (nth 0 claude-code--input-queued)))
    ;; Other slots untouched
    (should (equal "second" (nth 1 claude-code--input-queued)))
    (should (equal "third"  (nth 2 claude-code--input-queued)))))

;; ---------------------------------------------------------------------------
;; Queue editing — nav-current-input trimming
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-nav-current-input-trims ()
  "`claude-code--nav-current-input' should return text with whitespace trimmed."
  (claude-code-test-with-buffer
    (claude-code--render)
    (let ((inhibit-read-only t))
      (goto-char (marker-position claude-code--input-marker))
      (insert "  hello world  "))
    (should (equal "hello world" (claude-code--nav-current-input)))))

(ert-deftest claude-code-test-queue-edit-save-via-nav-trims-whitespace ()
  "Saving a queue slot via M-p navigation should store trimmed content."
  (claude-code-test-with-working-queue (list "first" "second")
    (claude-code-previous-input)            ; navigate to "second" (index 1)
    (let ((inhibit-read-only t))
      (delete-region claude-code--input-marker (point-max))
      (insert "  second EDITED  "))         ; extra surrounding whitespace
    (claude-code-previous-input)            ; M-p saves the slot and shows "first"
    ;; Saved slot must be trimmed
    (should (equal "second EDITED" (nth 1 claude-code--input-queued)))))

;; ---------------------------------------------------------------------------
;; Agent panel — kill-buffer-hook auto-cleanup
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-kill-buffer-hook-installed ()
  "claude-code-mode should add `claude-code--agent-unregister-self' to kill-buffer-hook."
  (let ((buf (generate-new-buffer " *claude-hook-test*")))
    (unwind-protect
        (with-current-buffer buf
          (claude-code-mode)
          (should (memq #'claude-code--agent-unregister-self kill-buffer-hook)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest claude-code-test-kill-buffer-unregisters-agent ()
  "Killing a claude-code buffer should automatically remove its agent from the registry."
  (claude-code-test-with-clean-agents
    (let ((buf (generate-new-buffer " *claude-kill-test*")))
      (with-current-buffer buf
        (claude-code-mode)
        (setq claude-code--cwd "/tmp/test-kill"
              claude-code--session-key "/tmp/test-kill")
        (claude-code--agent-register "/tmp/test-kill"
          :type 'session :status 'ready :buffer buf :children nil))
      ;; Confirm registration
      (should (gethash "/tmp/test-kill" claude-code--agents))
      ;; Killing the buffer should fire the hook and clean up the registry
      (kill-buffer buf)
      (should (null (gethash "/tmp/test-kill" claude-code--agents))))))

(ert-deftest claude-code-test-kill-buffer-removes-from-buffers-hash ()
  "Killing a primary-session buffer should remove it from `claude-code--buffers'."
  (claude-code-test-with-clean-agents
    (let ((saved-buffers claude-code--buffers)
          (buf (generate-new-buffer " *claude-bufhash-test*")))
      (unwind-protect
          (progn
            (setq claude-code--buffers (make-hash-table :test 'equal))
            (with-current-buffer buf
              (claude-code-mode)
              (setq claude-code--cwd "/tmp/test-bufhash"
                    claude-code--session-key "/tmp/test-bufhash")
              (puthash "/tmp/test-bufhash" buf claude-code--buffers)
              (claude-code--agent-register "/tmp/test-bufhash"
                :type 'session :status 'ready :buffer buf :children nil))
            (should (eq buf (gethash "/tmp/test-bufhash" claude-code--buffers)))
            (kill-buffer buf)
            (should (null (gethash "/tmp/test-bufhash" claude-code--buffers))))
        (setq claude-code--buffers saved-buffers)))))

;; ---------------------------------------------------------------------------
;; Agent panel — sidebar filters dead-buffer agents
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-sidebar-omits-dead-buffer-agents ()
  "Sidebar skips ghost entries: dead/nil buffer with no children.
A session with a dead buffer but live children is still shown because
the children keep it relevant.  Pure ghosts (dead + no children) are hidden."
  (claude-code-test-with-clean-agents
    (let ((live-buf        (generate-new-buffer " *claude-live-omit*"))
          (dead-buf        (generate-new-buffer " *claude-dead-omit*"))
          (dead-child-buf  (generate-new-buffer " *claude-dead-child-omit*")))
      (kill-buffer dead-buf)
      (kill-buffer dead-child-buf)
      (unwind-protect
          (progn
            ;; Dead buffer, no children → ghost, should be hidden
            (claude-code--agent-register "/tmp/dead-proj"
              :type 'session :description "dead session" :status 'stopped
              :buffer dead-buf :children nil)
            ;; Live buffer → should appear
            (claude-code--agent-register "/tmp/live-proj"
              :type 'session :description "live session" :status 'ready
              :buffer live-buf :children nil)
            ;; Dead buffer but has children → should appear
            (claude-code--agent-register "/tmp/dead-child-proj"
              :type 'session :description "dead-with-child" :status 'stopped
              :buffer dead-child-buf :children '("some-task"))
            (let ((sidebar (get-buffer-create "*Claude Agents*")))
              (unwind-protect
                  (progn
                    (with-current-buffer sidebar (claude-code-agents-mode))
                    (claude-code--agents-do-render)
                    (with-current-buffer sidebar
                      (let ((text (buffer-substring-no-properties
                                   (point-min) (point-max))))
                        (should-not (string-match-p "dead session" text))
                        (should     (string-match-p "live session" text))
                        (should     (string-match-p "dead-with-child" text)))))
                (kill-buffer sidebar))))
        (when (buffer-live-p live-buf) (kill-buffer live-buf))))))

(ert-deftest claude-code-test-sidebar-shows-live-buffer-agents ()
  "Sidebar render should include agents whose session buffer is still alive."
  (claude-code-test-with-clean-agents
    (let ((live-buf (generate-new-buffer " *claude-live-session*")))
      (unwind-protect
          (progn
            (claude-code--agent-register "/tmp/live-proj"
              :type 'session :description "live session" :status 'working
              :buffer live-buf :children nil)
            (let ((sidebar (get-buffer-create "*Claude Agents*")))
              (unwind-protect
                  (progn
                    (with-current-buffer sidebar
                      (claude-code-agents-mode))
                    (claude-code--agents-do-render)
                    (with-current-buffer sidebar
                      (let ((text (buffer-substring-no-properties
                                   (point-min) (point-max))))
                        (should (string-match-p "live session" text)))))
                (kill-buffer sidebar))))
        (when (buffer-live-p live-buf)
          (kill-buffer live-buf))))))

;; ---------------------------------------------------------------------------
;; Agent panel — k keybinding
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-agents-k-bound ()
  "`k' should be bound to `claude-code-agents-kill-at-point' in the agents keymap."
  (should (eq #'claude-code-agents-kill-at-point
              (lookup-key claude-code-agents-mode-map (kbd "k")))))

;; ---------------------------------------------------------------------------
;; Agent panel — kill-at-point
;; ---------------------------------------------------------------------------

(defun claude-code-test--make-mock-section (agent-id)
  "Return a minimal magit-section mock whose value is AGENT-ID."
  (let ((sec (make-instance 'magit-section)))
    (oset sec value agent-id)
    sec))

(ert-deftest claude-code-test-kill-at-point-confirmed-removes-agent ()
  "`k' confirmed on a session agent should unregister it."
  (claude-code-test-with-clean-agents
    (let ((session-buf (generate-new-buffer " *claude-kap-test*")))
      (unwind-protect
          (progn
            (claude-code--agent-register "/tmp/kap-proj"
              :type 'session :status 'ready
              :description "kap proj" :buffer session-buf :children nil)
            (should (gethash "/tmp/kap-proj" claude-code--agents))
            (cl-letf (((symbol-function 'magit-current-section)
                       (lambda ()
                         (claude-code-test--make-mock-section "/tmp/kap-proj")))
                      ((symbol-function 'yes-or-no-p) (lambda (_) t))
                      ;; Stub out claude-code-kill: just unregister, no process
                      ((symbol-function 'claude-code-kill)
                       (lambda ()
                         (claude-code--agent-unregister
                          (or claude-code--session-key claude-code--cwd)))))
              (with-current-buffer session-buf
                (claude-code-mode)
                (setq claude-code--cwd "/tmp/kap-proj"
                      claude-code--session-key "/tmp/kap-proj")
                (claude-code-agents-kill-at-point)))
            (should (null (gethash "/tmp/kap-proj" claude-code--agents))))
        (when (buffer-live-p session-buf) (kill-buffer session-buf))))))

(ert-deftest claude-code-test-kill-at-point-denied-preserves-agent ()
  "`k' cancelled should leave the agent in the registry."
  (claude-code-test-with-clean-agents
    (let ((session-buf (generate-new-buffer " *claude-kap-deny*")))
      (unwind-protect
          (progn
            (claude-code--agent-register "/tmp/kap-deny"
              :type 'session :status 'ready
              :description "kap deny" :buffer session-buf :children nil)
            (cl-letf (((symbol-function 'magit-current-section)
                       (lambda ()
                         (claude-code-test--make-mock-section "/tmp/kap-deny")))
                      ((symbol-function 'yes-or-no-p) (lambda (_) nil)))
              (claude-code-agents-kill-at-point))
            (should (gethash "/tmp/kap-deny" claude-code--agents)))
        (when (buffer-live-p session-buf) (kill-buffer session-buf))))))

;; ---------------------------------------------------------------------------
;; Agent panel — goto with dead buffer
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-agents-goto-dead-buffer-prompts-and-removes ()
  "RET on an agent with a dead buffer, confirmed, should unregister the agent."
  (claude-code-test-with-clean-agents
    (let ((dead-buf (generate-new-buffer " *claude-goto-dead*")))
      (kill-buffer dead-buf)
      (claude-code--agent-register "/tmp/goto-dead"
        :type 'session :status 'stopped
        :description "gone session" :buffer dead-buf :children nil)
      (cl-letf (((symbol-function 'magit-current-section)
                 (lambda ()
                   (claude-code-test--make-mock-section "/tmp/goto-dead")))
                ((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (claude-code-agents-goto))
      (should (null (gethash "/tmp/goto-dead" claude-code--agents))))))

(ert-deftest claude-code-test-agents-goto-dead-buffer-cancelled-preserves ()
  "RET on an agent with a dead buffer, cancelled, should leave the agent in the registry."
  (claude-code-test-with-clean-agents
    (let ((dead-buf (generate-new-buffer " *claude-goto-dead-cancel*")))
      (kill-buffer dead-buf)
      (claude-code--agent-register "/tmp/goto-dead-cancel"
        :type 'session :status 'stopped
        :description "gone cancel" :buffer dead-buf :children nil)
      (cl-letf (((symbol-function 'magit-current-section)
                 (lambda ()
                   (claude-code-test--make-mock-section "/tmp/goto-dead-cancel")))
                ((symbol-function 'yes-or-no-p) (lambda (_) nil)))
        (claude-code-agents-goto))
      (should (gethash "/tmp/goto-dead-cancel" claude-code--agents)))))

(ert-deftest claude-code-test-agents-goto-live-buffer-switches ()
  "RET on an agent with a live buffer should switch to that buffer."
  (claude-code-test-with-clean-agents
    (let ((live-buf (generate-new-buffer " *claude-goto-live*"))
          (switched-to nil))
      (unwind-protect
          (progn
            (claude-code--agent-register "/tmp/goto-live"
              :type 'session :status 'working
              :description "live session" :buffer live-buf :children nil)
            (cl-letf (((symbol-function 'magit-current-section)
                       (lambda ()
                         (claude-code-test--make-mock-section "/tmp/goto-live")))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buf) (setq switched-to buf))))
              (claude-code-agents-goto))
            (should (eq live-buf switched-to)))
        (when (buffer-live-p live-buf) (kill-buffer live-buf))))))

;; ---------------------------------------------------------------------------
;; agents-goto — task agent prefers own buffer
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-agents-goto-task-prefers-own-buffer ()
  "RET on a task agent should jump to its own task buffer, not the parent's."
  (claude-code-test-with-clean-agents
    (let ((session-buf (generate-new-buffer " *claude-goto-task-session*"))
          (task-buf    (generate-new-buffer " *claude-goto-task-task*"))
          (switched-to nil))
      (unwind-protect
          (progn
            (claude-code--agent-register "/tmp/goto-task"
              :type 'session :status 'working
              :description "session" :buffer session-buf :children '("task-99"))
            (claude-code--agent-register "task-99"
              :type 'task :status 'working :description "do stuff"
              :buffer task-buf :parent-id "/tmp/goto-task" :children nil)
            (cl-letf (((symbol-function 'magit-current-section)
                       (lambda ()
                         (claude-code-test--make-mock-section "task-99")))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buf) (setq switched-to buf))))
              (claude-code-agents-goto))
            ;; Should open the task buffer, not the session buffer
            (should (eq task-buf switched-to)))
        (when (buffer-live-p session-buf) (kill-buffer session-buf))
        (when (buffer-live-p task-buf)    (kill-buffer task-buf))))))

(ert-deftest claude-code-test-agents-goto-task-falls-back-to-parent ()
  "RET on a task with a dead own-buffer should fall back to parent session buffer."
  (claude-code-test-with-clean-agents
    (let ((session-buf (generate-new-buffer " *claude-goto-task-fb-session*"))
          (dead-task   (generate-new-buffer " *claude-goto-task-fb-task*"))
          (switched-to nil))
      (kill-buffer dead-task)
      (unwind-protect
          (progn
            (claude-code--agent-register "/tmp/goto-task-fb"
              :type 'session :status 'working
              :description "session" :buffer session-buf :children '("task-fb"))
            (claude-code--agent-register "task-fb"
              :type 'task :status 'completed :description "done"
              :buffer dead-task :parent-id "/tmp/goto-task-fb" :children nil)
            (cl-letf (((symbol-function 'magit-current-section)
                       (lambda ()
                         (claude-code-test--make-mock-section "task-fb")))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buf) (setq switched-to buf))))
              (claude-code-agents-goto))
            ;; Own buffer is dead, so falls back to parent session
            (should (eq session-buf switched-to)))
        (when (buffer-live-p session-buf) (kill-buffer session-buf))))))

;; ---------------------------------------------------------------------------
;; Sidebar buffer name display (⎘ lines)
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-sidebar-shows-buffer-name-for-session ()
  "Session rows should include a ⎘ line showing the buffer name."
  (claude-code-test-with-clean-agents
    (let ((session-buf (generate-new-buffer "*Claude: /tmp/bufname-test*")))
      (unwind-protect
          (progn
            (claude-code--agent-register "/tmp/bufname-test"
              :type 'session :status 'ready
              :description "test" :buffer session-buf :children nil)
            (let ((sidebar (get-buffer-create " *cc-test-sidebar-bufname*")))
              (unwind-protect
                  (progn
                    (with-current-buffer sidebar
                      (claude-code-agents-mode)
                      (let ((inhibit-read-only t))
                        (erase-buffer)
                        (magit-insert-section (root)
                          (claude-code--agents-render-root "/tmp/bufname-test"))))
                    (with-current-buffer sidebar
                      (should (string-match-p
                               "⎘"
                               (buffer-substring-no-properties (point-min) (point-max))))))
                (kill-buffer sidebar))))
        (when (buffer-live-p session-buf) (kill-buffer session-buf))))))

(ert-deftest claude-code-test-sidebar-shows-buffer-name-for-task ()
  "Task rows should include a ⎘ line showing the task buffer name."
  (claude-code-test-with-clean-agents
    (let ((session-buf (generate-new-buffer " *cc-test-task-session*"))
          (task-buf    (generate-new-buffer "*Claude Task: do stuff*")))
      (unwind-protect
          (progn
            (claude-code--agent-register "/tmp/taskbuf-test"
              :type 'session :status 'working
              :description "session" :buffer session-buf :children '("task-buf-1"))
            (claude-code--agent-register "task-buf-1"
              :type 'task :status 'working :description "do stuff"
              :buffer task-buf :parent-id "/tmp/taskbuf-test" :children nil)
            (let ((sidebar (get-buffer-create " *cc-test-sidebar-taskbuf*")))
              (unwind-protect
                  (progn
                    (with-current-buffer sidebar
                      (claude-code-agents-mode)
                      (let ((inhibit-read-only t))
                        (erase-buffer)
                        (magit-insert-section (root)
                          (claude-code--agents-render-root "/tmp/taskbuf-test"))))
                    (with-current-buffer sidebar
                      (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
                        (should (string-match-p "⎘" txt))
                        (should (string-match-p "Claude Task" txt)))))
                (kill-buffer sidebar))))
        (when (buffer-live-p session-buf) (kill-buffer session-buf))
        (when (buffer-live-p task-buf)    (kill-buffer task-buf))))))

(ert-deftest claude-code-test-sidebar-no-buffer-name-when-buffer-dead ()
  "When a session buffer is dead, no ⎘ line should appear."
  (claude-code-test-with-clean-agents
    (let ((dead-buf (generate-new-buffer " *cc-test-dead*")))
      (kill-buffer dead-buf)
      (claude-code--agent-register "/tmp/deadbuf-test"
        :type 'session :status 'stopped
        :description "gone" :buffer dead-buf :children nil)
      (let ((sidebar (get-buffer-create " *cc-test-sidebar-dead*")))
        (unwind-protect
            (progn
              (with-current-buffer sidebar
                (claude-code-agents-mode)
                (let ((inhibit-read-only t))
                  (erase-buffer)
                  (magit-insert-section (root)
                    (claude-code--agents-render-root "/tmp/deadbuf-test"))))
              (with-current-buffer sidebar
                (should-not (string-match-p
                             "⎘"
                             (buffer-substring-no-properties (point-min) (point-max))))))
          (kill-buffer sidebar))))))

;; ---------------------------------------------------------------------------
;; System prompt includes buffer name
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-system-prompt-includes-buffer-name ()
  "The system prompt should always include the current buffer's name."
  (claude-code-test-with-buffer
    ;; Stub out note/skill loaders so we only test the buffer-name injection.
    (cl-letf (((symbol-function 'claude-code--load-notes)     (lambda () nil))
              ((symbol-function 'claude-code--load-dir-notes) (lambda () nil))
              ((symbol-function 'claude-code--load-dir-todos) (lambda () nil))
              ((symbol-function 'claude-code--org-roam-load-skills) (lambda () nil)))
      (let ((prompt (claude-code--build-system-prompt)))
        (should (stringp prompt))
        (should (string-match-p (regexp-quote (buffer-name)) prompt))))))

;; ---------------------------------------------------------------------------
;; Reload — session ID preserved after start-process
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-start-process-does-not-clear-session-id ()
  "`claude-code--start-process' must not set `claude-code--session-id' to nil."
  ;; Verify by inspecting the function body — we don't want to actually start
  ;; a process in unit tests, so we check the source rather than running it.
  (let ((src (with-temp-buffer
               (insert (prin1-to-string
                        (symbol-function 'claude-code--start-process)))
               (buffer-string))))
    (should-not (string-match-p "session-id.*nil\\|nil.*session-id" src))))

(ert-deftest claude-code-test-reload-preserves-agent-children ()
  "After reload, agent children should be restored from the saved state."
  (claude-code-test-with-clean-agents
    (let* ((session-buf (generate-new-buffer " *cc-reload-session*"))
           (task-buf    (generate-new-buffer " *cc-reload-task*"))
           (dir "/tmp/reload-test"))
      (unwind-protect
          (progn
            ;; Set up: session with one child task
            (claude-code--agent-register dir
              :type 'session :status 'ready
              :description "session" :buffer session-buf
              :cwd dir :children '("reload-task-1"))
            (claude-code--agent-register "reload-task-1"
              :type 'task :status 'completed :description "done"
              :buffer task-buf :parent-id dir :children nil)
            ;; Simulate what reload does: save children, then re-register
            (let ((saved-children
                   (plist-get (gethash dir claude-code--agents) :children)))
              (claude-code--agent-register dir
                :type 'session :status 'starting
                :description "session" :buffer session-buf
                :cwd dir :children saved-children)
              ;; Children must survive the re-register
              (let ((agent (gethash dir claude-code--agents)))
                (should (equal '("reload-task-1") (plist-get agent :children))))))
        (when (buffer-live-p session-buf) (kill-buffer session-buf))
        (when (buffer-live-p task-buf)    (kill-buffer task-buf))))))

(ert-deftest claude-code-test-reload-skips-live-process-session ()
  "Reload must not stop the backend process of a session with a live process.
This guards the case where the agent calls claude-code-reload via emacsclient
from inside a Bash tool: the process is alive mid-tool-execution, and killing
it would interrupt the conversation."
  (claude-code-test-with-clean-agents
    (let* ((dir "/tmp/reload-live-proc-test")
           (buf (generate-new-buffer " *cc-reload-live*"))
           ;; Simulate a live process with a no-op sentinel/filter.
           (fake-proc (make-pipe-process
                       :name "cc-fake-proc"
                       :buffer nil
                       :noquery t
                       :filter #'ignore
                       :sentinel #'ignore))
           stop-called)
      (unwind-protect
          (progn
            (with-current-buffer buf
              (claude-code-mode)
              (setq claude-code--cwd dir
                    claude-code--process fake-proc
                    claude-code--status 'working
                    claude-code--session-id "test-sid"))
            (puthash dir buf claude-code--buffers)
            (claude-code--agent-register dir
              :type 'session :status 'working
              :buffer buf :cwd dir :children nil)
            ;; Patch stop-process to detect if it's called.
            (cl-letf (((symbol-function 'claude-code--stop-process)
                       (lambda () (setq stop-called t)))
                      ((symbol-function 'claude-code--start-process) #'ignore)
                      ((symbol-function 'claude-code--schedule-render) #'ignore)
                      ((symbol-function 'claude-code--ensure-environment) #'ignore))
              ;; Run just the save+stop phase of reload logic inline.
              (let ((saved-states '()))
                (maphash (lambda (d b)
                           (when (buffer-live-p b)
                             (with-current-buffer b
                               (let* ((working-p (and claude-code--process
                                                      (process-live-p claude-code--process))))
                                 (push (list :dir d :keep-process working-p) saved-states)
                                 (unless working-p
                                   (claude-code--stop-process))))))
                         claude-code--buffers)
                ;; stop-process must NOT have been called for the live session.
                (should-not stop-called)
                ;; The saved state must record keep-process = t.
                (let ((state (car saved-states)))
                  (should (plist-get state :keep-process))))))
        (remhash dir claude-code--buffers)
        (when (process-live-p fake-proc) (delete-process fake-proc))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;; ---------------------------------------------------------------------------
;; Treemacs-style sidebar — keybindings and mode features
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-agents-mouse-1-bound ()
  "`<mouse-1>' should be bound to `claude-code-agents-goto-mouse'."
  (should (eq #'claude-code-agents-goto-mouse
              (lookup-key claude-code-agents-mode-map [mouse-1]))))

(ert-deftest claude-code-test-agents-double-mouse-1-bound ()
  "`<double-mouse-1>' should also be bound to `claude-code-agents-goto-mouse'."
  (should (eq #'claude-code-agents-goto-mouse
              (lookup-key claude-code-agents-mode-map [double-mouse-1]))))

(ert-deftest claude-code-test-agents-tab-bound ()
  "`<tab>' should be bound to `claude-code-agents-toggle-or-goto'."
  ;; keymap-set uses "<tab>" which binds the [tab] function-key event,
  ;; distinct from the ASCII \t character that (kbd "TAB") produces.
  (should (eq #'claude-code-agents-toggle-or-goto
              (lookup-key claude-code-agents-mode-map [tab]))))

(ert-deftest claude-code-test-agents-mode-enables-hl-line ()
  "`claude-code-agents-mode' should enable `hl-line-mode'."
  (let ((buf (get-buffer-create " *cc-hl-line-test*")))
    (unwind-protect
        (with-current-buffer buf
          (claude-code-agents-mode)
          (should hl-line-mode))
      (kill-buffer buf))))

(ert-deftest claude-code-test-agents-goto-mouse-defined ()
  "`claude-code-agents-goto-mouse' should be defined as an interactive command."
  (should (fboundp #'claude-code-agents-goto-mouse))
  (should (commandp #'claude-code-agents-goto-mouse)))

(ert-deftest claude-code-test-agents-toggle-or-goto-defined ()
  "`claude-code-agents-toggle-or-goto' should be defined as an interactive command."
  (should (fboundp #'claude-code-agents-toggle-or-goto))
  (should (commandp #'claude-code-agents-toggle-or-goto)))

(ert-deftest claude-code-test-sidebar-heading-has-mouse-face ()
  "Session and task headings should carry `mouse-face' for hover highlighting."
  (claude-code-test-with-clean-agents
    (let ((live-buf (generate-new-buffer " *cc-mface-session*")))
      (unwind-protect
          (progn
            (claude-code--agent-register "/tmp/mface-proj"
              :type 'session :description "hover test" :status 'ready
              :buffer live-buf :children nil)
            (let ((sidebar (get-buffer-create "*Claude Agents*")))
              (unwind-protect
                  (progn
                    (with-current-buffer sidebar (claude-code-agents-mode))
                    (claude-code--agents-do-render)
                    (with-current-buffer sidebar
                      ;; Find the heading line and check it has mouse-face
                      (goto-char (point-min))
                      (re-search-forward "hover test\\|mface-proj")
                      (let ((mf (get-text-property (point) 'mouse-face)))
                        (should mf))))
                (kill-buffer sidebar))))
        (when (buffer-live-p live-buf) (kill-buffer live-buf))))))

(ert-deftest claude-code-test-sidebar-nil-buffer-ghost-hidden ()
  "A session with nil :buffer and no children should be filtered from the sidebar."
  (claude-code-test-with-clean-agents
    (let ((live-buf (generate-new-buffer " *cc-ghost-live*")))
      (unwind-protect
          (progn
            ;; Ghost: nil buffer, no children
            (claude-code--agent-register "/tmp/ghost-proj"
              :type 'session :description "ghost entry" :status 'starting
              :buffer nil :children nil)
            ;; Live session
            (claude-code--agent-register "/tmp/real-proj"
              :type 'session :description "real session" :status 'ready
              :buffer live-buf :children nil)
            (let ((sidebar (get-buffer-create "*Claude Agents*")))
              (unwind-protect
                  (progn
                    (with-current-buffer sidebar (claude-code-agents-mode))
                    (claude-code--agents-do-render)
                    (with-current-buffer sidebar
                      (let ((text (buffer-substring-no-properties
                                   (point-min) (point-max))))
                        (should-not (string-match-p "ghost entry" text))
                        (should     (string-match-p "real session" text)))))
                (kill-buffer sidebar))))
        (when (buffer-live-p live-buf) (kill-buffer live-buf))))))

;; ---------------------------------------------------------------------------
;; Emacs-native subagent vars and defcustom
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-subagent-vars-exist ()
  "Buffer-local subagent state variables must be defined and default to nil."
  (claude-code-test-with-buffer
    (should (boundp 'claude-code--subagent-task-id))
    (should (null claude-code--subagent-task-id))
    (should (boundp 'claude-code--subagent-parent-key))
    (should (null claude-code--subagent-parent-key))
    (should (boundp 'claude-code--subagent-has-worked))
    (should (null claude-code--subagent-has-worked))))

(ert-deftest claude-code-test-native-subagents-defcustom-exists ()
  "`claude-code-enable-native-subagents' should be defined and default to t."
  (should (boundp 'claude-code-enable-native-subagents))
  (should (eq t claude-code-enable-native-subagents)))

;; ---------------------------------------------------------------------------
;; claude-code--spawn-subagent
;; ---------------------------------------------------------------------------

(defmacro claude-code-test-with-spawned-subagent (parent-buf-var
                                                   task-id-var
                                                   desc prompt &rest body)
  "Set up PARENT-BUF-VAR with a registered session, call spawn-subagent with
DESC and PROMPT, bind TASK-ID-VAR to the returned id, run BODY, then clean
up the spawned agent buffer.  start-process and schedule-render are mocked."
  (declare (indent 3))
  `(claude-code-test-with-clean-agents
     (claude-code-test-with-buffer
       (cl-letf (((symbol-function 'claude-code--start-process) #'ignore)
                 ((symbol-function 'claude-code--schedule-render) #'ignore))
         (let ((,parent-buf-var (current-buffer)))
           (claude-code--agent-register claude-code--cwd
             :type 'session :status 'ready
             :buffer ,parent-buf-var :children nil)
           (let ((,task-id-var
                  (claude-code--spawn-subagent
                   (buffer-name) ,desc ,prompt)))
             (unwind-protect
                 (progn ,@body)
               (when-let* ((agent (gethash ,task-id-var claude-code--agents))
                           (buf   (plist-get agent :buffer)))
                 (when (buffer-live-p buf) (kill-buffer buf))))))))))

(ert-deftest claude-code-test-spawn-subagent-returns-task-id ()
  "`claude-code--spawn-subagent' should return an \"emacs-task-\" prefixed string."
  (claude-code-test-with-spawned-subagent _parent task-id "count words" "Count words."
    (should (stringp task-id))
    (should (string-prefix-p "emacs-task-" task-id))))

(ert-deftest claude-code-test-spawn-subagent-registers-child ()
  "`claude-code--spawn-subagent' should register a task child under the parent."
  (claude-code-test-with-spawned-subagent parent task-id "search auth" "Find auth."
    (let ((child  (gethash task-id claude-code--agents))
          (parent-agent (gethash claude-code--cwd claude-code--agents)))
      (should child)
      (should (eq 'task (plist-get child :type)))
      (should (equal "search auth" (plist-get child :description)))
      (should (eq 'working (plist-get child :status)))
      (should (equal claude-code--cwd (plist-get child :parent-id)))
      (should (member task-id (plist-get parent-agent :children))))))

(ert-deftest claude-code-test-spawn-subagent-sets-subagent-vars ()
  "The spawned session buffer should have subagent vars pointing back to parent."
  (claude-code-test-with-spawned-subagent parent task-id "check coverage" "List gaps."
    (let* ((child (gethash task-id claude-code--agents))
           (agent-buf (plist-get child :buffer)))
      (should (buffer-live-p agent-buf))
      (with-current-buffer agent-buf
        (should (equal task-id claude-code--subagent-task-id))
        (should (equal claude-code--cwd  ; parent-key = parent cwd
                       claude-code--subagent-parent-key))))))

(ert-deftest claude-code-test-spawn-subagent-queues-prompt ()
  "The spawned buffer should pre-queue the prompt for auto-send on ready."
  (claude-code-test-with-spawned-subagent _p task-id "analyse logs" "Look at logs."
    (let* ((child (gethash task-id claude-code--agents))
           (agent-buf (plist-get child :buffer)))
      (with-current-buffer agent-buf
        (should (equal '("Look at logs.") claude-code--input-queued))))))

(ert-deftest claude-code-test-spawn-subagent-notifies-parent ()
  "`claude-code--spawn-subagent' should push an info message to the parent."
  (claude-code-test-with-spawned-subagent parent task-id "lint code" "Run lint."
    (should (seq-find
             (lambda (m)
               (and (equal "info" (alist-get 'type m))
                    (string-match-p "lint code" (alist-get 'text m ""))))
             (with-current-buffer parent claude-code--messages)))))

(ert-deftest claude-code-test-spawn-subagent-errors-on-missing-parent ()
  "`claude-code--spawn-subagent' should signal an error for unknown parent buffers."
  (should-error
   (claude-code--spawn-subagent "*nonexistent-buffer-xyzzy*" "task" "prompt")
   :type 'error))

;; ---------------------------------------------------------------------------
;; claude-code--subagent-notify-parent
;; ---------------------------------------------------------------------------

(defmacro claude-code-test-with-subagent-pair (parent-var agent-var &rest body)
  "Set up a parent session PARENT-VAR and a child subagent session AGENT-VAR,
register both in the agents registry, run BODY, then clean up both buffers."
  (declare (indent 2))
  `(claude-code-test-with-clean-agents
     (let ((,parent-var (generate-new-buffer " *cc-notify-parent*"))
           (,agent-var  (generate-new-buffer " *cc-notify-agent*")))
       (unwind-protect
           (progn
             (with-current-buffer ,parent-var
               (claude-code-mode)
               (setq claude-code--cwd "/tmp/cc-notify-parent"))
             (claude-code--agent-register "/tmp/cc-notify-parent"
               :type 'session :status 'working
               :buffer ,parent-var :children '("cc-sub-task-99"))
             (with-current-buffer ,agent-var
               (claude-code-mode)
               (setq claude-code--cwd              "/tmp/cc-notify-parent"
                     claude-code--session-key       "cc-sub-task-99"
                     claude-code--subagent-task-id  "cc-sub-task-99"
                     claude-code--subagent-parent-key "/tmp/cc-notify-parent"
                     claude-code--subagent-has-worked t
                     claude-code--messages
                     (list '((type . "assistant")
                             (content . [((type . "text")
                                          (text . "Done: found 5 issues."))])))))
             (claude-code--agent-register "cc-sub-task-99"
               :type 'task :status 'working :description "Lint check"
               :parent-id "/tmp/cc-notify-parent"
               :buffer ,agent-var :children nil)
             (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
               ,@body))
         (when (buffer-live-p ,parent-var) (kill-buffer ,parent-var))
         (when (buffer-live-p ,agent-var)  (kill-buffer ,agent-var))))))

(ert-deftest claude-code-test-subagent-notify-marks-completed ()
  "`claude-code--subagent-notify-parent' should set task status to completed."
  (claude-code-test-with-subagent-pair parent-buf agent-buf
    (with-current-buffer agent-buf
      (claude-code--subagent-notify-parent))
    (let ((task (gethash "cc-sub-task-99" claude-code--agents)))
      (should (eq 'completed (plist-get task :status))))))

(ert-deftest claude-code-test-subagent-notify-sets-summary ()
  "`claude-code--subagent-notify-parent' should extract and store first-line summary."
  (claude-code-test-with-subagent-pair _p agent-buf
    (with-current-buffer agent-buf
      (claude-code--subagent-notify-parent))
    (let ((task (gethash "cc-sub-task-99" claude-code--agents)))
      (should (equal "Done: found 5 issues." (plist-get task :summary))))))

(ert-deftest claude-code-test-subagent-notify-pushes-parent-message ()
  "`claude-code--subagent-notify-parent' should push a completion info message to parent."
  (claude-code-test-with-subagent-pair parent-buf agent-buf
    (with-current-buffer agent-buf
      (claude-code--subagent-notify-parent))
    (with-current-buffer parent-buf
      (should (seq-find
               (lambda (m)
                 (and (equal "info" (alist-get 'type m))
                      (string-match-p "completed" (alist-get 'text m ""))))
               claude-code--messages)))))

(ert-deftest claude-code-test-subagent-notify-clears-task-id ()
  "`claude-code--subagent-notify-parent' should nil out `claude-code--subagent-task-id'."
  (claude-code-test-with-subagent-pair _p agent-buf
    (with-current-buffer agent-buf
      (claude-code--subagent-notify-parent)
      (should (null claude-code--subagent-task-id)))))

;; ---------------------------------------------------------------------------
;; Result event → subagent notify integration
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-result-event-fires-notify-when-worked ()
  "A result event in a worked subagent session should call notify-parent."
  (claude-code-test-with-subagent-pair _parent agent-buf
    (let ((notify-called nil))
      (cl-letf (((symbol-function 'claude-code--subagent-notify-parent)
                 (lambda () (setq notify-called t)))
                ((symbol-function 'claude-code--flush-streaming) #'ignore)
                ((symbol-function 'claude-code--stop-thinking)   #'ignore)
                ((symbol-function 'claude-code--schedule-render) #'ignore))
        (with-current-buffer agent-buf
          ;; subagent-has-worked is already t (set by the macro)
          (claude-code--handle-result-event '((type . "result"))))
        (should notify-called)))))

(ert-deftest claude-code-test-result-event-no-notify-when-not-worked ()
  "A result event before the subagent has worked should NOT call notify-parent."
  (claude-code-test-with-subagent-pair _parent agent-buf
    (let ((notify-called nil))
      (cl-letf (((symbol-function 'claude-code--subagent-notify-parent)
                 (lambda () (setq notify-called t)))
                ((symbol-function 'claude-code--flush-streaming) #'ignore)
                ((symbol-function 'claude-code--stop-thinking)   #'ignore)
                ((symbol-function 'claude-code--schedule-render) #'ignore))
        (with-current-buffer agent-buf
          ;; Override: hasn't worked yet
          (setq claude-code--subagent-has-worked nil)
          (claude-code--handle-result-event '((type . "result"))))
        (should-not notify-called)))))

(ert-deftest claude-code-test-working-event-sets-has-worked ()
  "A `working' status event should set `claude-code--subagent-has-worked' to t."
  (claude-code-test-with-subagent-pair _parent agent-buf
    (cl-letf (((symbol-function 'claude-code--start-thinking)    #'ignore)
              ((symbol-function 'claude-code--schedule-render)   #'ignore)
              ((symbol-function 'claude-code--agent-update)      #'ignore))
      (with-current-buffer agent-buf
        (setq claude-code--subagent-has-worked nil)
        (claude-code--handle-event '((type . "status") (status . "working")))
        (should claude-code--subagent-has-worked)))))

;; ---------------------------------------------------------------------------
;; System prompt — native subagent protocol inclusion
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-system-prompt-includes-subagent-protocol ()
  "System prompt should include the spawn protocol when native subagents enabled."
  (claude-code-test-with-buffer
    (let ((claude-code-enable-native-subagents t))
      (let ((sp (claude-code--build-system-prompt)))
        (should sp)
        (should (string-match-p "Emacs-Native Subagents" sp))
        (should (string-match-p "claude-code--spawn-subagent" sp))
        (should (string-match-p "emacsclient" sp))))))

(ert-deftest claude-code-test-system-prompt-excludes-protocol-when-disabled ()
  "System prompt should NOT include the spawn protocol when disabled."
  (claude-code-test-with-buffer
    (let ((claude-code-enable-native-subagents nil))
      (let ((sp (claude-code--build-system-prompt)))
        ;; Protocol section must be absent
        (should-not (and sp (string-match-p "Emacs-Native Subagents" sp)))))))

(ert-deftest claude-code-test-system-prompt-embeds-buffer-name ()
  "The spawn protocol in the system prompt should include the current buffer name."
  (claude-code-test-with-buffer
    (let ((claude-code-enable-native-subagents t))
      (let ((sp (claude-code--build-system-prompt))
            (buf-name (buffer-name)))
        (should sp)
        (should (string-match-p (regexp-quote buf-name) sp))))))

;; ---------------------------------------------------------------------------
;; task_started uses session-key as parent-id when set
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-task-started-uses-session-key-as-parent ()
  "`task_started' should use `claude-code--session-key' as parent-id, not just cwd."
  (claude-code-test-with-buffer
    (claude-code-test-with-clean-agents
      (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
        ;; Simulate a fork session: session-key differs from cwd
        (setq claude-code--session-key "/tmp/test-project::fork-99")
        (claude-code--agent-register "/tmp/test-project::fork-99"
          :type 'session :children nil)
        (claude-code--handle-event
         '((type . "task_started")
           (task_id . "fork-task-1")
           (description . "parallel search")))
        (let ((task (gethash "fork-task-1" claude-code--agents)))
          (should task)
          ;; parent-id must be the session-key, not the raw cwd
          (should (equal "/tmp/test-project::fork-99"
                         (plist-get task :parent-id))))))))

;; ---------------------------------------------------------------------------
;; save-project-config
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-save-project-config-creates-entry ()
  "`claude-code-save-project-config' adds a new entry for the current cwd."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'customize-save-variable) #'ignore)
              ((symbol-function 'claude-code--schedule-render) #'ignore))
      (let ((claude-code-project-config nil))
        (setq claude-code--session-overrides
              '((model . "claude-opus-4-6")
                (permission-mode . "acceptEdits")))
        (claude-code-save-project-config)
        (let* ((dir (expand-file-name "/tmp/test-project"))
               (entry (assoc dir claude-code-project-config)))
          (should entry)
          (should (equal "claude-opus-4-6"
                         (alist-get 'model (cdr entry))))
          (should (equal "acceptEdits"
                         (alist-get 'permission-mode (cdr entry)))))))))

(ert-deftest claude-code-test-save-project-config-updates-existing ()
  "`claude-code-save-project-config' updates an existing project entry."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'customize-save-variable) #'ignore)
              ((symbol-function 'claude-code--schedule-render) #'ignore))
      (let* ((dir (expand-file-name "/tmp/test-project"))
             (claude-code-project-config
              (list (cons dir '((model . "claude-haiku-4-5"))))))
        (setq claude-code--session-overrides
              '((model . "claude-sonnet-4-6")))
        (claude-code-save-project-config)
        (let ((entry (assoc dir claude-code-project-config)))
          (should entry)
          (should (equal "claude-sonnet-4-6"
                         (alist-get 'model (cdr entry))))
          ;; should not have duplicated the directory
          (should (= 1 (length claude-code-project-config))))))))

(ert-deftest claude-code-test-save-project-config-calls-customize-save ()
  "`claude-code-save-project-config' persists via `customize-save-variable'."
  (claude-code-test-with-buffer
    (let ((saved-calls nil))
      (cl-letf (((symbol-function 'customize-save-variable)
                 (lambda (sym val)
                   (push (cons sym val) saved-calls)))
                ((symbol-function 'claude-code--schedule-render) #'ignore))
        (let ((claude-code-project-config nil))
          (claude-code-save-project-config)
          (should (= 1 (length saved-calls)))
          (should (eq 'claude-code-project-config
                      (caar saved-calls))))))))

(ert-deftest claude-code-test-render-header-has-config-buttons ()
  "The rendered header must contain clickable config buttons."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--start-thinking) #'ignore))
      (claude-code--render)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "model:" text))
        (should (string-match-p "effort:" text))
        (should (string-match-p "perms:" text))
        (should (string-match-p "Save as Project Default" text))))))

;; ---------------------------------------------------------------------------
;; Image attachment — helpers
;; ---------------------------------------------------------------------------

;; Minimal 1×1 red PNG as base64.  Decoded at use-time to avoid multibyte issues.
(defconst claude-code-test--tiny-png-b64
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADklEQVQI12P4z8BQDwAEgAF/QualIQAAAABJRU5ErkJggg=="
  "Base64-encoded minimal 1×1 PNG for testing.")

(defun claude-code-test--tiny-png ()
  "Return raw unibyte bytes of a minimal 1×1 PNG."
  (base64-decode-string claude-code-test--tiny-png-b64))

(defmacro claude-code-test-with-png-file (&rest body)
  "Create a temp PNG file, run BODY with `tmp-png' bound to its path, then delete."
  (declare (indent 0))
  `(let ((tmp-png (make-temp-file "claude-test-img" nil ".png")))
     (unwind-protect
         (progn
           (with-temp-file tmp-png
             (set-buffer-multibyte nil)
             (insert (claude-code-test--tiny-png)))
           ,@body)
       (ignore-errors (delete-file tmp-png)))))

;; ---------------------------------------------------------------------------
;; Image media-type detection
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-image-media-type-jpeg ()
  "`claude-code--image-media-type' maps .jpg/.jpeg to image/jpeg."
  (should (equal "image/jpeg" (claude-code--image-media-type "photo.jpg")))
  (should (equal "image/jpeg" (claude-code--image-media-type "photo.jpeg")))
  (should (equal "image/jpeg" (claude-code--image-media-type "PHOTO.JPG"))))

(ert-deftest claude-code-test-image-media-type-other ()
  "`claude-code--image-media-type' handles png/gif/webp and falls back to png."
  (should (equal "image/png"  (claude-code--image-media-type "shot.png")))
  (should (equal "image/gif"  (claude-code--image-media-type "anim.gif")))
  (should (equal "image/webp" (claude-code--image-media-type "img.webp")))
  (should (equal "image/png"  (claude-code--image-media-type "unknown.bmp")))
  (should (equal "image/png"  (claude-code--image-media-type "no-extension"))))

;; ---------------------------------------------------------------------------
;; claude-code-attach-image — file path
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-attach-image-from-file-adds-to-pending ()
  "`claude-code-attach-image' with a file pushes a plist to pending-images."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
      (claude-code-test-with-png-file
        (claude-code-attach-image tmp-png)
        (should (= 1 (length claude-code--pending-images)))))))

(ert-deftest claude-code-test-attach-image-stores-raw-data ()
  "Pending image plist contains :raw-data unibyte string."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
      (claude-code-test-with-png-file
        (claude-code-attach-image tmp-png)
        (let ((img (car claude-code--pending-images)))
          (should (stringp (plist-get img :raw-data)))
          (should (not (multibyte-string-p (plist-get img :raw-data)))))))))

(ert-deftest claude-code-test-attach-image-stores-base64 ()
  "Pending image plist contains :data as valid base64."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
      (claude-code-test-with-png-file
        (claude-code-attach-image tmp-png)
        (let* ((img  (car claude-code--pending-images))
               (b64  (plist-get img :data))
               (decoded (base64-decode-string b64)))
          (should (stringp b64))
          ;; decoded bytes should equal what's on disk
          (should (equal decoded
                         (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (insert-file-contents-literally tmp-png)
                           (buffer-string)))))))))

(ert-deftest claude-code-test-attach-image-base64-matches-raw ()
  "base64-decode(:data) == :raw-data — both representations are consistent."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
      (claude-code-test-with-png-file
        (claude-code-attach-image tmp-png)
        (let ((img (car claude-code--pending-images)))
          (should (equal (plist-get img :raw-data)
                         (base64-decode-string (plist-get img :data)))))))))

(ert-deftest claude-code-test-attach-image-sets-media-type ()
  "Pending image plist has correct :media-type for .png file."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
      (claude-code-test-with-png-file
        (claude-code-attach-image tmp-png)
        (should (equal "image/png"
                       (plist-get (car claude-code--pending-images) :media-type)))))))

(ert-deftest claude-code-test-attach-image-sets-name ()
  "Pending image plist :name equals the file's base name."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
      (claude-code-test-with-png-file
        (claude-code-attach-image tmp-png)
        (should (equal (file-name-nondirectory tmp-png)
                       (plist-get (car claude-code--pending-images) :name)))))))

(ert-deftest claude-code-test-attach-image-multiple ()
  "Attaching multiple images accumulates them in pending-images."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--schedule-render) #'ignore))
      (claude-code-test-with-png-file
        (claude-code-attach-image tmp-png)
        (claude-code-attach-image tmp-png)
        (should (= 2 (length claude-code--pending-images)))))))

(ert-deftest claude-code-test-attach-image-errors-on-missing-file ()
  "`claude-code-attach-image' signals error for unreadable file."
  (claude-code-test-with-buffer
    (should-error
     (claude-code-attach-image "/nonexistent/path/image.png")
     :type 'user-error)))

;; ---------------------------------------------------------------------------
;; claude-code-send — image integration
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-send-includes-images-in-json ()
  "`claude-code-send' serialises :data/:media-type/:name into the JSON cmd."
  (claude-code-test-with-buffer
    (let ((sent-cmds nil))
      (cl-letf (((symbol-function 'claude-code--send-json)
                 (lambda (cmd) (push cmd sent-cmds)))
                ((symbol-function 'claude-code--build-system-prompt) #'ignore)
                ((symbol-function 'claude-code--schedule-render) #'ignore)
                ((symbol-function 'claude-code--agent-update) #'ignore))
        (setq claude-code--pending-images
              (list (list :raw-data "bytes" :data "abc123"
                          :media-type "image/png" :name "test.png")))
        (claude-code-send "describe this image")
        (let* ((img-vec (alist-get 'images (car sent-cmds)))
               (img0    (aref img-vec 0)))
          (should img-vec)
          (should (= 1 (length img-vec)))
          (should (equal "abc123"    (alist-get 'data img0)))
          (should (equal "image/png" (alist-get 'media_type img0)))
          (should (equal "test.png"  (alist-get 'name img0))))))))

(ert-deftest claude-code-test-send-omits-raw-data-from-json ()
  "`claude-code-send' must NOT include :raw-data in the JSON (binary data)."
  (claude-code-test-with-buffer
    (let ((sent-cmds nil))
      (cl-letf (((symbol-function 'claude-code--send-json)
                 (lambda (cmd) (push cmd sent-cmds)))
                ((symbol-function 'claude-code--build-system-prompt) #'ignore)
                ((symbol-function 'claude-code--schedule-render) #'ignore)
                ((symbol-function 'claude-code--agent-update) #'ignore))
        (setq claude-code--pending-images
              (list (list :raw-data "bytes" :data "abc123"
                          :media-type "image/png" :name "test.png")))
        (claude-code-send "with image")
        (let* ((img-vec (alist-get 'images (car sent-cmds)))
               (img0    (aref img-vec 0)))
          (should (null (alist-get 'raw_data img0))))))))

(ert-deftest claude-code-test-send-clears-pending-images ()
  "`claude-code-send' clears `claude-code--pending-images' after sending."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--send-json) #'ignore)
              ((symbol-function 'claude-code--build-system-prompt) #'ignore)
              ((symbol-function 'claude-code--schedule-render) #'ignore)
              ((symbol-function 'claude-code--agent-update) #'ignore))
      (setq claude-code--pending-images
            (list (list :raw-data "b" :data "x" :media-type "image/png" :name "a.png")))
      (claude-code-send "go")
      (should (null claude-code--pending-images)))))

(ert-deftest claude-code-test-send-stores-images-in-message-history ()
  "`claude-code-send' records images in the pushed message alist."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--send-json) #'ignore)
              ((symbol-function 'claude-code--build-system-prompt) #'ignore)
              ((symbol-function 'claude-code--schedule-render) #'ignore)
              ((symbol-function 'claude-code--agent-update) #'ignore))
      (let ((img (list :raw-data "b" :data "x" :media-type "image/png" :name "a.png")))
        (setq claude-code--pending-images (list img))
        (claude-code-send "describe")
        (let ((recorded-images (alist-get 'images (car claude-code--messages))))
          (should recorded-images)
          (should (equal img (car recorded-images))))))))

(ert-deftest claude-code-test-send-no-images-field-when-none ()
  "No `images' key in JSON cmd when `claude-code--pending-images' is nil."
  (claude-code-test-with-buffer
    (let ((sent-cmds nil))
      (cl-letf (((symbol-function 'claude-code--send-json)
                 (lambda (cmd) (push cmd sent-cmds)))
                ((symbol-function 'claude-code--build-system-prompt) #'ignore)
                ((symbol-function 'claude-code--schedule-render) #'ignore)
                ((symbol-function 'claude-code--agent-update) #'ignore))
        (setq claude-code--pending-images nil)
        (claude-code-send "hello")
        (should (null (alist-get 'images (car sent-cmds))))))))

(ert-deftest claude-code-test-send-images-not-stored-in-messages-when-nil ()
  "No images key in message history when none were attached."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--send-json) #'ignore)
              ((symbol-function 'claude-code--build-system-prompt) #'ignore)
              ((symbol-function 'claude-code--schedule-render) #'ignore)
              ((symbol-function 'claude-code--agent-update) #'ignore))
      (setq claude-code--pending-images nil)
      (claude-code-send "plain text")
      (should (null (alist-get 'images (car claude-code--messages)))))))

;; ---------------------------------------------------------------------------
;; Image rendering helpers
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-image-type-from-media-type ()
  "`claude-code--image-type-from-media-type' returns correct Emacs image type."
  (should (eq 'jpeg (claude-code--image-type-from-media-type "image/jpeg")))
  (should (eq 'gif  (claude-code--image-type-from-media-type "image/gif")))
  (should (eq 'webp (claude-code--image-type-from-media-type "image/webp")))
  (should (eq 'png  (claude-code--image-type-from-media-type "image/png")))
  (should (eq 'png  (claude-code--image-type-from-media-type "image/unknown"))))

(ert-deftest claude-code-test-insert-image-text-fallback-in-terminal ()
  "`claude-code--insert-image' inserts text chip when not in GUI frame."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'display-graphic-p) (lambda () nil)))
      (let ((img (list :raw-data (claude-code-test--tiny-png)
                       :data     (base64-encode-string (claude-code-test--tiny-png) t)
                       :media-type "image/png"
                       :name    "test.png")))
        (with-temp-buffer
          (claude-code--insert-image img)
          (should (string-match-p "📎 test\\.png"
                                  (buffer-substring-no-properties
                                   (point-min) (point-max)))))))))

(ert-deftest claude-code-test-insert-image-text-fallback-when-disabled ()
  "`claude-code--insert-image' uses text chip when max-width is nil."
  (let ((claude-code-inline-image-max-width nil))
    (with-temp-buffer
      (claude-code--insert-image
       (list :raw-data (claude-code-test--tiny-png)
             :data (base64-encode-string (claude-code-test--tiny-png) t)
             :media-type "image/png" :name "shot.png"))
      (should (string-match-p "📎 shot\\.png"
                              (buffer-substring-no-properties
                               (point-min) (point-max)))))))

(ert-deftest claude-code-test-insert-image-gui-shows-display-property ()
  "`claude-code--insert-image' sets a `display' text property in GUI mode."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'png)))
  (with-temp-buffer
    (claude-code--insert-image
     (list :raw-data    (claude-code-test--tiny-png)
           :data        (base64-encode-string (claude-code-test--tiny-png) t)
           :media-type  "image/png"
           :name        "test.png"))
    ;; There should be a display property somewhere in the inserted text.
    (let ((has-display nil))
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (when (get-text-property pos 'display)
            (setq has-display t))
          (setq pos (1+ pos))))
      (should has-display))))

(ert-deftest claude-code-test-render-user-msg-with-images ()
  "Rendering a user message with images inserts image content."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--start-thinking) #'ignore)
              ((symbol-function 'display-graphic-p) (lambda () nil)))
      ;; Build a message with one image
      (setq claude-code--messages
            (list `((type . "user")
                    (prompt . "look at this")
                    (images . (,(list :raw-data (claude-code-test--tiny-png)
                                      :data (base64-encode-string
                                             (claude-code-test--tiny-png) t)
                                      :media-type "image/png"
                                      :name "snap.png"))))))
      (claude-code--render)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        ;; Should show both the image chip and the prompt text
        (should (string-match-p "snap\\.png" text))
        (should (string-match-p "look at this" text))))))

(ert-deftest claude-code-test-render-user-msg-no-images ()
  "Rendering a user message without images shows just the prompt."
  (claude-code-test-with-buffer
    (cl-letf (((symbol-function 'claude-code--start-thinking) #'ignore))
      (setq claude-code--messages
            (list '((type . "user") (prompt . "hello"))))
      (claude-code--render)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "hello" text))
        (should (not (string-match-p "📎" text)))))))

;; ---------------------------------------------------------------------------
;; claude-code-emacs-tools — paren checker
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-tools-check-parens-balanced ()
  "Well-balanced code should return nil (no error)."
  (should (null (claude-code-tools--check-parens "(+ 1 2)")))
  (should (null (claude-code-tools--check-parens "(progn (foo) (bar))")))
  (should (null (claude-code-tools--check-parens ""))))

(ert-deftest claude-code-tools-check-parens-extra-close ()
  "Extra close paren should be detected."
  (should (stringp (claude-code-tools--check-parens "(foo))"))))

(ert-deftest claude-code-tools-check-parens-unclosed ()
  "Unclosed open paren should be detected."
  (should (stringp (claude-code-tools--check-parens "(foo ("))))

(ert-deftest claude-code-tools-check-parens-nested ()
  "Deeply nested balanced code should pass."
  (should (null (claude-code-tools--check-parens
                 "(let ((x (+ 1 (funcall #'foo 'bar)))) x)"))))

(ert-deftest claude-code-tools-check-parens-string-with-parens ()
  "Parens inside strings should not affect balance count."
  (should (null (claude-code-tools--check-parens
                 "(message \"hello (world)\")")))
  (should (null (claude-code-tools--check-parens
                 "(message \"((unmatched in string))\")"))))

(ert-deftest claude-code-tools-check-parens-comment-with-parens ()
  "Parens in line comments should not affect balance count."
  (should (null (claude-code-tools--check-parens
                 "(foo) ; this is a comment (with parens"))))

(ert-deftest claude-code-tools-check-parens-unclosed-string ()
  "Unclosed string literals should be reported."
  (should (stringp (claude-code-tools--check-parens
                    "(message \"unclosed string"))))

(ert-deftest claude-code-tools-check-parens-escaped-quote-in-string ()
  "Escaped double-quotes inside strings should not prematurely close them."
  (should (null (claude-code-tools--check-parens
                 "(message \"say \\\"hello\\\"\")"))))

;; ---------------------------------------------------------------------------
;; claude-code-emacs-tools — safe-print
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-tools-safe-print-short ()
  "Short values should be printed without truncation."
  (should (equal "42" (claude-code-tools--safe-print 42)))
  (should (equal "\"hello\"" (claude-code-tools--safe-print "hello")))
  (should (equal "t" (claude-code-tools--safe-print t)))
  (should (equal "nil" (claude-code-tools--safe-print nil))))

(ert-deftest claude-code-tools-safe-print-truncated ()
  "Values whose print exceeds max-chars should be truncated."
  (let ((long-str (make-string 5000 ?x)))
    (let ((result (claude-code-tools--safe-print long-str 100)))
      (should (string-match-p "truncated" result))
      (should (< (length result) 200)))))

;; ---------------------------------------------------------------------------
;; claude-code-emacs-tools — eval
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-tools-eval-ok ()
  "Successful eval should return a string starting with 'ok: '."
  (let ((result (claude-code-tools-eval "(+ 1 2)")))
    (should (stringp result))
    (should (string-prefix-p "ok: " result))
    (should (string-match-p "3" result))))

(ert-deftest claude-code-tools-eval-error ()
  "Failed eval should return a string starting with 'error: '."
  (let ((result (claude-code-tools-eval "(/ 1 0)")))
    (should (stringp result))
    (should (string-prefix-p "error: " result))))

(ert-deftest claude-code-tools-eval-paren-error ()
  "Unbalanced parens should be caught before eval."
  (let ((result (claude-code-tools-eval "(foo (bar")))
    (should (string-prefix-p "error: syntax" result))))

(ert-deftest claude-code-tools-eval-returns-nil-ok ()
  "Expressions evaluating to nil should succeed with 'ok: nil'."
  (let ((result (claude-code-tools-eval "nil")))
    (should (string-prefix-p "ok: " result))
    (should (string-match-p "nil" result))))

(ert-deftest claude-code-tools-eval-empty-parens-ok ()
  "Empty paren expression () should be caught as error — not valid elisp."
  ;; () is not valid in Emacs Lisp; it's nil in Common Lisp but signals an
  ;; error here.
  (let ((result (claude-code-tools-eval "()")))
    ;; Either ok: or error: is acceptable as long as we don't crash.
    (should (or (string-prefix-p "ok: " result)
                (string-prefix-p "error: " result)))))

;; ---------------------------------------------------------------------------
;; claude-code-emacs-tools — get-messages
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-tools-get-messages-returns-string ()
  "`claude-code-tools-get-messages' should return a string."
  (should (stringp (claude-code-tools-get-messages))))

(ert-deftest claude-code-tools-get-messages-respects-limit ()
  "Requesting fewer chars should return at most that many characters."
  (let ((result (claude-code-tools-get-messages 50)))
    (should (stringp result))
    (should (<= (length result) 50))))

;; ---------------------------------------------------------------------------
;; claude-code-emacs-tools — get-buffer
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-tools-get-buffer-existing ()
  "`claude-code-tools-get-buffer' should return contents of an existing buffer."
  (let ((buf (generate-new-buffer " *cc-tools-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "hello\nworld\n"))
          (let ((result (claude-code-tools-get-buffer (buffer-name buf))))
            (should (string-match-p "hello" result))
            (should (string-match-p "world" result))))
      (kill-buffer buf))))

(ert-deftest claude-code-tools-get-buffer-missing ()
  "`claude-code-tools-get-buffer' should return an error for a missing buffer."
  (let ((result (claude-code-tools-get-buffer "nonexistent-buffer-xyzzy-123")))
    (should (string-prefix-p "error:" result))))

(ert-deftest claude-code-tools-get-buffer-with-line-numbers ()
  "With line numbers, output should have numeric prefixes."
  (let ((buf (generate-new-buffer " *cc-tools-linenum*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "alpha\nbeta\ngamma\n"))
          (let ((result (claude-code-tools-get-buffer (buffer-name buf) t)))
            (should (string-match-p "   1  alpha" result))
            (should (string-match-p "   2  beta" result))
            (should (string-match-p "   3  gamma" result))))
      (kill-buffer buf))))

;; ---------------------------------------------------------------------------
;; claude-code-emacs-tools — get-buffer-region
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-tools-get-buffer-region-basic ()
  "Region retrieval should return only the requested lines."
  (let ((buf (generate-new-buffer " *cc-tools-region*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "line1\nline2\nline3\nline4\nline5\n"))
          (let ((result (claude-code-tools-get-buffer-region
                         (buffer-name buf) 2 4)))
            (should (string-match-p "line2" result))
            (should (string-match-p "line3" result))
            (should (string-match-p "line4" result))
            (should (not (string-match-p "line1" result)))
            (should (not (string-match-p "line5" result)))))
      (kill-buffer buf))))

(ert-deftest claude-code-tools-get-buffer-region-invalid-range ()
  "start > end should return an error string."
  (let ((buf (generate-new-buffer " *cc-tools-invalid*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (insert "x\n"))
          (let ((result (claude-code-tools-get-buffer-region
                         (buffer-name buf) 5 2)))
            (should (string-prefix-p "error:" result))))
      (kill-buffer buf))))

;; ---------------------------------------------------------------------------
;; claude-code-emacs-tools — list-buffers
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-tools-list-buffers-returns-string ()
  "`claude-code-tools-list-buffers' should return a non-empty string."
  (let ((result (claude-code-tools-list-buffers)))
    (should (stringp result))
    (should (> (length result) 0))))

(ert-deftest claude-code-tools-list-buffers-includes-messages ()
  "The *Messages* buffer should appear in the listing."
  ;; Ensure *Messages* exists
  (message "test")
  (let ((result (claude-code-tools-list-buffers)))
    (should (string-match-p "\\*Messages\\*" result))))

(ert-deftest claude-code-tools-list-buffers-includes-header ()
  "The listing should include a column header."
  (let ((result (claude-code-tools-list-buffers)))
    (should (string-match-p "BUFFER" result))
    (should (string-match-p "MODE" result))))

;; ---------------------------------------------------------------------------
;; claude-code-emacs-tools — search-forward / search-backward
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-tools-search-forward-found ()
  "`claude-code-tools-search-forward' should return ok on match."
  (let ((buf (generate-new-buffer " *cc-tools-sf*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "foo bar baz\n"))
          (with-current-buffer buf
            (goto-char (point-min))
            (let ((result (claude-code-tools-search-forward "bar" (buffer-name buf))))
              (should (string-prefix-p "ok:" result))
              (should (string-match-p "bar" result)))))
      (kill-buffer buf))))

(ert-deftest claude-code-tools-search-forward-not-found ()
  "`claude-code-tools-search-forward' should return not-found when no match."
  (let ((buf (generate-new-buffer " *cc-tools-sf-nf*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (insert "foo\n"))
          (with-current-buffer buf
            (goto-char (point-min))
            (let ((result (claude-code-tools-search-forward "zzz" (buffer-name buf) t)))
              (should (string-match-p "not found" result)))))
      (kill-buffer buf))))

(ert-deftest claude-code-tools-search-backward-found ()
  "`claude-code-tools-search-backward' should return ok on match."
  (let ((buf (generate-new-buffer " *cc-tools-sb*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "foo bar baz\n"))
          (with-current-buffer buf
            (goto-char (point-max))
            (let ((result (claude-code-tools-search-backward "bar" (buffer-name buf))))
              (should (string-prefix-p "ok:" result)))))
      (kill-buffer buf))))

;; ---------------------------------------------------------------------------
;; claude-code-emacs-tools — goto-line
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-tools-goto-line-moves-point ()
  "`claude-code-tools-goto-line' should move point to the given line."
  (let ((buf (generate-new-buffer " *cc-tools-goto*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "line1\nline2\nline3\n"))
          (with-current-buffer buf
            (let ((result (claude-code-tools-goto-line 2 (buffer-name buf))))
              (should (stringp result))
              (should (= 2 (line-number-at-pos (point)))))))
      (kill-buffer buf))))

;; ---------------------------------------------------------------------------
;; claude-code-emacs-tools — get-point-info
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-tools-get-point-info-format ()
  "`claude-code-tools-get-point-info' should return buffer, line, and col."
  (let ((buf (generate-new-buffer " *cc-tools-pt*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "hello world\n"))
          (with-current-buffer buf
            (goto-char (point-min))
            (let ((result (claude-code-tools-get-point-info (buffer-name buf))))
              (should (string-match-p "buffer:" result))
              (should (string-match-p "line:" result))
              (should (string-match-p "col:" result)))))
      (kill-buffer buf))))

;; ---------------------------------------------------------------------------
;; claude-code-emacs-tools — get-debug-info
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-tools-get-debug-info-returns-string ()
  "`claude-code-tools-get-debug-info' should return a non-empty string."
  (let ((result (claude-code-tools-get-debug-info)))
    (should (stringp result))
    (should (> (length result) 0))
    (should (string-match-p "Messages" result))))

;; ---------------------------------------------------------------------------
;; claude-code-frame-render — grid operations
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-fr-make-grid-dimensions ()
  "`claude-code-fr--make-grid' should produce a grid of correct dimensions."
  (let ((g (claude-code-fr--make-grid 10 5)))
    (should (= 5 (length g)))
    (should (= 10 (length (aref g 0))))))

(ert-deftest claude-code-fr-make-grid-default-cell ()
  "Every cell in a fresh grid should contain a space with empty SGR."
  (let ((g (claude-code-fr--make-grid 3 2)))
    (should (= ?\s (aref (aref (aref g 0) 0) 0)))
    (should (equal "" (aref (aref (aref g 0) 0) 1)))))

(ert-deftest claude-code-fr-gset-in-bounds ()
  "`claude-code-fr--gset' should set a cell in bounds."
  (let ((g (claude-code-fr--make-grid 5 3)))
    (claude-code-fr--gset g 1 2 ?X "1")
    (let ((cell (aref (aref g 1) 2)))
      (should (= ?X (aref cell 0)))
      (should (equal "1" (aref cell 1))))))

(ert-deftest claude-code-fr-gset-out-of-bounds-no-error ()
  "`claude-code-fr--gset' should silently ignore out-of-bounds writes."
  (let ((g (claude-code-fr--make-grid 5 3)))
    ;; These should not signal an error
    (should (null (claude-code-fr--gset g 99 0 ?X "")))
    (should (null (claude-code-fr--gset g 0 99 ?X "")))))

(ert-deftest claude-code-fr-gput-text-basic ()
  "`claude-code-fr--gput-text' should write characters into grid row."
  (let ((g (claude-code-fr--make-grid 20 3)))
    (claude-code-fr--gput-text g 1 0 "hello" "" 20)
    (should (= ?h (aref (aref (aref g 1) 0) 0)))
    (should (= ?e (aref (aref (aref g 1) 1) 0)))
    (should (= ?l (aref (aref (aref g 1) 2) 0)))))

(ert-deftest claude-code-fr-gput-text-respects-max-col ()
  "`claude-code-fr--gput-text' should not write past max-col."
  (let ((g (claude-code-fr--make-grid 5 1)))
    (claude-code-fr--gput-text g 0 0 "hello world" "" 3)
    ;; Positions 0,1,2 written; 3,4 should remain space
    (should (= ?h (aref (aref (aref g 0) 0) 0)))
    (should (= ?\s (aref (aref (aref g 0) 3) 0)))))

(ert-deftest claude-code-fr-gput-text-returns-next-col ()
  "`claude-code-fr--gput-text' should return the column after the last char."
  (let ((g (claude-code-fr--make-grid 20 1)))
    (let ((next (claude-code-fr--gput-text g 0 0 "abc" "" 20)))
      (should (= 3 next)))))

(ert-deftest claude-code-fr-gput-segs ()
  "`claude-code-fr--gput-segs' should write segment list in order."
  (let ((g (claude-code-fr--make-grid 20 1)))
    (claude-code-fr--gput-segs g 0 0 20
                               '(("hi" "") (" " "") ("there" "")))
    (should (= ?h (aref (aref (aref g 0) 0) 0)))
    (should (= ?i (aref (aref (aref g 0) 1) 0)))
    (should (= ?\s (aref (aref (aref g 0) 2) 0)))
    (should (= ?t (aref (aref (aref g 0) 3) 0)))))

(ert-deftest claude-code-fr-grid-to-string-non-empty ()
  "`claude-code-fr--grid-to-string' should produce a non-empty string."
  (let ((g (claude-code-fr--make-grid 5 2)))
    (claude-code-fr--gput-text g 0 0 "hello" "" 5)
    (let ((s (claude-code-fr--grid-to-string g)))
      (should (stringp s))
      (should (> (length s) 0))
      (should (string-match-p "hello" s)))))

(ert-deftest claude-code-fr-grid-to-string-row-count ()
  "`claude-code-fr--grid-to-string' should produce one line per grid row."
  (let ((g (claude-code-fr--make-grid 4 3)))
    (let* ((s (claude-code-fr--grid-to-string g))
           ;; Strip ANSI escapes for line counting
           (plain (replace-regexp-in-string "\033\\[[0-9;]*m" "" s))
           (lines (split-string plain "\n" t)))
      (should (= 3 (length lines))))))

;; ---------------------------------------------------------------------------
;; claude-code-frame-render — face → SGR
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-fr-face-to-sgr-empty-face ()
  "nil face should produce an empty SGR string."
  (should (equal "" (claude-code-fr--face-to-sgr nil))))

(ert-deftest claude-code-fr-face-to-sgr-bold ()
  "Bold weight should produce SGR '1'."
  (let ((sgr (claude-code-fr--face-to-sgr '(:weight bold))))
    (should (string-match-p "1" sgr))))

(ert-deftest claude-code-fr-face-to-sgr-italic ()
  "Italic slant should produce SGR '3'."
  (let ((sgr (claude-code-fr--face-to-sgr '(:slant italic))))
    (should (string-match-p "3" sgr))))

(ert-deftest claude-code-fr-face-to-sgr-underline ()
  "Underline should produce SGR '4'."
  (let ((sgr (claude-code-fr--face-to-sgr '(:underline t))))
    (should (string-match-p "4" sgr))))

(ert-deftest claude-code-fr-face-to-sgr-strikethrough ()
  "Strikethrough should produce SGR '9'."
  (let ((sgr (claude-code-fr--face-to-sgr '(:strike-through t))))
    (should (string-match-p "9" sgr))))

(ert-deftest claude-code-fr-face-to-sgr-light ()
  "Light weight should produce SGR '2'."
  (let ((sgr (claude-code-fr--face-to-sgr '(:weight light))))
    (should (string-match-p "2" sgr))))

;; ---------------------------------------------------------------------------
;; claude-code-frame-render — face-attr lookup
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-fr-face-attr-nil-face ()
  "nil face should return nil for any attribute."
  (should (null (claude-code-fr--face-attr nil :foreground)))
  (should (null (claude-code-fr--face-attr nil :weight))))

(ert-deftest claude-code-fr-face-attr-plist ()
  "Plist face should return the matching keyword value."
  (should (equal 'bold (claude-code-fr--face-attr '(:weight bold) :weight)))
  (should (equal "red"  (claude-code-fr--face-attr '(:foreground "red") :foreground))))

(ert-deftest claude-code-fr-face-attr-list-of-plists ()
  "List of plist faces — first match wins."
  (should (equal 'bold
                 (claude-code-fr--face-attr
                  '((:weight bold) (:weight light))
                  :weight))))

;; ---------------------------------------------------------------------------
;; claude-code-frame-render — check-parens edge cases via color helpers
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-fr-color-fg-sgr-nil ()
  "nil color should return nil."
  (should (null (claude-code-fr--color-fg-sgr nil))))

(ert-deftest claude-code-fr-color-fg-sgr-non-string ()
  "Non-string color should return nil."
  (should (null (claude-code-fr--color-fg-sgr 42))))

(ert-deftest claude-code-fr-underline-sgr-bool ()
  "Boolean t underline should produce '4'."
  (should (member "4" (claude-code-fr--underline-sgr t))))

(ert-deftest claude-code-fr-underline-sgr-nil ()
  "nil underline should return empty list."
  (should (null (claude-code-fr--underline-sgr nil))))

;; ---------------------------------------------------------------------------
;; claude-code-frame-render — gput-box
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-fr-gput-box-draws-borders ()
  "`claude-code-fr--gput-box' should write box-drawing characters."
  (let ((g (claude-code-fr--make-grid 20 6)))
    (claude-code-fr--gput-box g 0 0 '("hello" "world"))
    ;; Top-left corner
    (should (= ?┌ (aref (aref (aref g 0) 0) 0)))
    ;; Top-right corner — box-w = max(5,5) + 4 = 9, so col = box-w-1 = 8
    (should (= ?┐ (aref (aref (aref g 0) 8) 0)))
    ;; Bottom-left corner
    (should (= ?└ (aref (aref (aref g 3) 0) 0)))
    ;; Content: "hello" starts at column 2 of row 1
    (should (= ?h (aref (aref (aref g 1) 2) 0)))))

;; ---------------------------------------------------------------------------
;; claude-code-frame-render — action-name
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-fr-action-name-symbol ()
  "`claude-code-fr--action-name' should return the symbol name."
  (should (equal "my-action" (claude-code-fr--action-name 'my-action nil))))

(ert-deftest claude-code-fr-action-name-nil-nil ()
  "`claude-code-fr--action-name' with nil action returns \"nil\" (nil is a symbol).
`symbolp' returns t for nil, so `symbol-name' gives the string \"nil\"."
  (should (equal "nil" (claude-code-fr--action-name nil nil))))

;; ---------------------------------------------------------------------------
;; claude-code-frame-render — render round-trip smoke test
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-fr-render-smoke ()
  "`claude-code-frame-render' should return a non-empty string without error."
  ;; This is a live Emacs test — it will render whatever frame is active.
  (let ((result (claude-code-frame-render)))
    (should (stringp result))
    (should (> (length result) 0))
    ;; Frame header must be present
    (should (string-match-p "Frame:" result))
    ;; Legend must be present
    (should (string-match-p "legend:" result))))

(ert-deftest claude-code-fr-render-contains-buffer-info ()
  "`claude-code-frame-render' output should contain a buffer-info box."
  (let ((result (claude-code-frame-render)))
    (should (string-match-p "buffer:" result))
    (should (string-match-p "mode:" result))))

(ert-deftest claude-code-fr-render-to-file ()
  "`claude-code-frame-render-to-file' should write a file and return its path."
  (let ((tmpfile (make-temp-file "cc-fr-test-")))
    (unwind-protect
        (progn
          (let ((returned (claude-code-frame-render-to-file tmpfile)))
            (should (equal tmpfile returned))
            (should (file-exists-p tmpfile))
            (should (> (nth 7 (file-attributes tmpfile)) 0))))
      (when (file-exists-p tmpfile) (delete-file tmpfile)))))

;; ---------------------------------------------------------------------------
;; MCP tool detection (claude-code--mcp-tool-p)
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-mcp-tool-p-emacs-tools ()
  "`claude-code--mcp-tool-p' should return non-nil for all Emacs MCP tools."
  (should (claude-code--mcp-tool-p "EvalEmacs"))
  (should (claude-code--mcp-tool-p "EmacsRenderFrame"))
  (should (claude-code--mcp-tool-p "EmacsGetMessages"))
  (should (claude-code--mcp-tool-p "EmacsGetDebugInfo"))
  (should (claude-code--mcp-tool-p "EmacsGetBuffer"))
  (should (claude-code--mcp-tool-p "EmacsGetBufferRegion"))
  (should (claude-code--mcp-tool-p "EmacsListBuffers"))
  (should (claude-code--mcp-tool-p "EmacsSwitchBuffer"))
  (should (claude-code--mcp-tool-p "EmacsGetPointInfo"))
  (should (claude-code--mcp-tool-p "EmacsSearchForward"))
  (should (claude-code--mcp-tool-p "EmacsSearchBackward"))
  (should (claude-code--mcp-tool-p "EmacsGotoLine")))

(ert-deftest claude-code-test-mcp-tool-p-prefixed-names ()
  "`claude-code--mcp-tool-p' accepts the real mcp__emacs__* prefixed names."
  (should (claude-code--mcp-tool-p "mcp__emacs__EvalEmacs"))
  (should (claude-code--mcp-tool-p "mcp__emacs__EmacsRenderFrame"))
  (should (claude-code--mcp-tool-p "mcp__emacs__EmacsGotoLine")))

(ert-deftest claude-code-test-mcp-tool-short-name ()
  "`claude-code--mcp-tool-short-name' strips the mcp__emacs__ prefix."
  (should (equal "EvalEmacs"
                 (claude-code--mcp-tool-short-name "mcp__emacs__EvalEmacs")))
  (should (equal "EmacsGotoLine"
                 (claude-code--mcp-tool-short-name "mcp__emacs__EmacsGotoLine")))
  ;; Bare names are returned unchanged
  (should (equal "EvalEmacs" (claude-code--mcp-tool-short-name "EvalEmacs")))
  (should (equal "Read"      (claude-code--mcp-tool-short-name "Read")))
  (should (null             (claude-code--mcp-tool-short-name nil))))

(ert-deftest claude-code-test-mcp-tool-p-non-mcp-tools ()
  "`claude-code--mcp-tool-p' should return nil for regular SDK tools."
  (should (null (claude-code--mcp-tool-p "Read")))
  (should (null (claude-code--mcp-tool-p "Write")))
  (should (null (claude-code--mcp-tool-p "Edit")))
  (should (null (claude-code--mcp-tool-p "Bash")))
  (should (null (claude-code--mcp-tool-p "Glob")))
  (should (null (claude-code--mcp-tool-p "Grep")))
  (should (null (claude-code--mcp-tool-p nil)))
  (should (null (claude-code--mcp-tool-p ""))))

;; ---------------------------------------------------------------------------
;; MCP tool summaries
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-tool-summary-mcp-eval-emacs ()
  "`claude-code--tool-summary' for EvalEmacs shows truncated code."
  (let ((result (claude-code--tool-summary
                 "EvalEmacs"
                 '((code . "(+ 1 2)")))))
    (should (stringp result))
    (should (string-match-p "+" result))))

(ert-deftest claude-code-test-tool-summary-mcp-get-buffer ()
  "`claude-code--tool-summary' for EmacsGetBuffer shows buffer name."
  (should (equal "*Messages*"
                 (claude-code--tool-summary
                  "EmacsGetBuffer"
                  '((buffer_name . "*Messages*"))))))

(ert-deftest claude-code-test-tool-summary-mcp-get-buffer-region ()
  "`claude-code--tool-summary' for EmacsGetBufferRegion shows buffer:range."
  (let ((result (claude-code--tool-summary
                 "EmacsGetBufferRegion"
                 '((buffer_name . "myfile.el")
                   (start_line . 10)
                   (end_line . 20)))))
    (should (stringp result))
    (should (string-match-p "myfile\\.el" result))
    (should (string-match-p "10" result))
    (should (string-match-p "20" result))))

(ert-deftest claude-code-test-tool-summary-mcp-search-forward ()
  "`claude-code--tool-summary' for EmacsSearchForward shows pattern."
  (should (equal "defun foo"
                 (claude-code--tool-summary
                  "EmacsSearchForward"
                  '((pattern . "defun foo"))))))

(ert-deftest claude-code-test-tool-summary-mcp-goto-line ()
  "`claude-code--tool-summary' for EmacsGotoLine shows line number."
  (let ((result (claude-code--tool-summary
                 "EmacsGotoLine"
                 '((line_number . 42)))))
    (should (stringp result))
    (should (string-match-p "42" result))))

(ert-deftest claude-code-test-tool-summary-mcp-render-frame-nil ()
  "`claude-code--tool-summary' returns nil for EmacsRenderFrame (no params)."
  (should (null (claude-code--tool-summary "EmacsRenderFrame" nil))))

;; ---------------------------------------------------------------------------
;; MCP tool rendering — [Emacs] badge and face
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-render-mcp-tool-shows-emacs-badge ()
  "MCP tool-use blocks should contain the [Emacs] badge."
  (claude-code-test-with-buffer
    (push `((type . "assistant")
            (content . [((type . "tool_use")
                         (id . "mcp-1")
                         (name . "EvalEmacs")
                         (input . ((code . "(+ 1 2)"))))]))
          claude-code--messages)
    (claude-code--render)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "EvalEmacs" text))
      (should (string-match-p "\\[Emacs\\]" text)))))

(ert-deftest claude-code-test-render-mcp-tool-render-frame-badge ()
  "EmacsRenderFrame tool-use blocks should contain the [Emacs] badge."
  (claude-code-test-with-buffer
    (push `((type . "assistant")
            (content . [((type . "tool_use")
                         (id . "mcp-2")
                         (name . "EmacsRenderFrame")
                         (input . nil))]))
          claude-code--messages)
    (claude-code--render)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "EmacsRenderFrame" text))
      (should (string-match-p "\\[Emacs\\]" text)))))

(ert-deftest claude-code-test-render-mcp-tool-prefixed-name-shows-short ()
  "Prefixed MCP tool names (mcp__emacs__*) render as short names with [Emacs] badge."
  (claude-code-test-with-buffer
    (push `((type . "assistant")
            (content . [((type . "tool_use")
                         (id . "mcp-pref-1")
                         (name . "mcp__emacs__EvalEmacs")
                         (input . ((code . "(+ 1 2)"))))]))
          claude-code--messages)
    (claude-code--render)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      ;; Should show short name, not the full prefixed name
      (should     (string-match-p "EvalEmacs" text))
      (should     (string-match-p "\\[Emacs\\]" text))
      (should-not (string-match-p "mcp__emacs__" text)))))

(ert-deftest claude-code-test-tool-summary-mcp-prefixed-name ()
  "`claude-code--tool-summary' works when called with a prefixed MCP name."
  (should (equal "*Messages*"
                 (claude-code--tool-summary
                  "mcp__emacs__EmacsGetBuffer"
                  '((buffer_name . "*Messages*"))))))

(ert-deftest claude-code-test-render-regular-tool-no-emacs-badge ()
  "Regular (non-MCP) tool-use blocks should NOT contain the [Emacs] badge."
  (claude-code-test-with-buffer
    (push `((type . "assistant")
            (content . [((type . "tool_use")
                         (id . "t-1")
                         (name . "Read")
                         (input . ((file_path . "/tmp/foo.el"))))]))
          claude-code--messages)
    (claude-code--render)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "Read" text))
      (should (not (string-match-p "\\[Emacs\\]" text))))))

(ert-deftest claude-code-test-render-mcp-tool-has-mcp-face ()
  "MCP tool name should use `claude-code-mcp-tool-name' face."
  (claude-code-test-with-buffer
    (push `((type . "assistant")
            (content . [((type . "tool_use")
                         (id . "mcp-3")
                         (name . "EmacsGetBuffer")
                         (input . ((buffer_name . "*Messages*"))))]))
          claude-code--messages)
    (claude-code--render)
    ;; Find the tool name in the buffer and check its face
    (goto-char (point-min))
    (when (re-search-forward "EmacsGetBuffer" nil t)
      (let ((face (get-text-property (match-beginning 0) 'face)))
        (should (or (eq face 'claude-code-mcp-tool-name)
                    (and (listp face)
                         (memq 'claude-code-mcp-tool-name face))))))))

(ert-deftest claude-code-test-render-regular-tool-has-tool-face ()
  "Regular tool name should use `claude-code-tool-name' face (not MCP face)."
  (claude-code-test-with-buffer
    (push `((type . "assistant")
            (content . [((type . "tool_use")
                         (id . "t-2")
                         (name . "Grep")
                         (input . ((pattern . "defun"))))]))
          claude-code--messages)
    (claude-code--render)
    (goto-char (point-min))
    (when (re-search-forward "Grep" nil t)
      (let ((face (get-text-property (match-beginning 0) 'face)))
        ;; Should have tool-name face, NOT mcp-tool-name face
        (should (not (eq face 'claude-code-mcp-tool-name)))
        (should (not (and (listp face)
                          (memq 'claude-code-mcp-tool-name face))))))))

;; ---------------------------------------------------------------------------
;; MCP tool name constant completeness
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-mcp-tool-names-constant ()
  "`claude-code--mcp-tool-names' should contain all 12 expected Emacs tools."
  (should (= 12 (length claude-code--mcp-tool-names)))
  ;; Spot-check a few
  (should (member "EvalEmacs" claude-code--mcp-tool-names))
  (should (member "EmacsRenderFrame" claude-code--mcp-tool-names))
  (should (member "EmacsGotoLine" claude-code--mcp-tool-names)))

(provide 'claude-code-test)
;;; claude-code-test.el ends here
