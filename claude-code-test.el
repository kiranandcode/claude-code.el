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
          claude-code--input-queued "my queued message")
    (let ((s (claude-code--thinking-overlay-string)))
      (should (string-match-p "queued" s))
      (should (string-match-p "my queued message" s)))))

(ert-deftest claude-code-test-thinking-overlay-queued-truncated ()
  "Queued messages longer than 60 chars should be truncated in the overlay."
  (claude-code-test-with-buffer
    (setq claude-code--query-start-time nil
          claude-code--streaming-char-count 0
          claude-code--thinking-elapsed-sec 0.0
          claude-code--thinking-block-start-time nil
          claude-code--input-queued (make-string 80 ?x))
    (let ((s (claude-code--thinking-overlay-string)))
      (should (string-match-p "queued" s))
      (should (not (string-match-p (make-string 80 ?x) s))))))

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
  "Submitting while working should queue the text, not send it."
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
        (should (equal "my queued message" claude-code--input-queued))
        (should (null sent-text))
        ;; Text must remain in input area
        (should (string-match-p
                 "my queued message"
                 (buffer-substring-no-properties
                  claude-code--input-marker (point-max))))))))

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
  "Cancel should clear `claude-code--input-queued'."
  (claude-code-test-with-buffer
    (setq claude-code--input-queued "pending message")
    (cl-letf (((symbol-function 'claude-code--send-json) #'ignore)
              ((symbol-function 'claude-code--stop-thinking) #'ignore)
              ((symbol-function 'claude-code--schedule-render) #'ignore))
      (claude-code-cancel)
      (should (null claude-code--input-queued)))))

(ert-deftest claude-code-test-ready-status-auto-sends-queue ()
  "When status becomes ready, a queued message should be dispatched."
  (claude-code-test-with-buffer
    (claude-code-test-with-clean-agents
      (claude-code--render)
      (setq claude-code--input-queued "auto-send me")
      (let ((dispatched nil))
        (cl-letf (((symbol-function 'claude-code--stop-thinking) #'ignore)
                  ((symbol-function 'claude-code--flush-streaming) #'ignore)
                  ((symbol-function 'claude-code--schedule-render) #'ignore)
                  ((symbol-function 'claude-code--dispatch-input)
                   (lambda (text) (setq dispatched text))))
          (claude-code--handle-status-event '((status . "ready")))
          (should (equal "auto-send me" dispatched))
          (should (null claude-code--input-queued)))))))

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

(provide 'claude-code-test)
;;; claude-code-test.el ends here
