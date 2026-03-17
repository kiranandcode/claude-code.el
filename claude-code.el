;;; claude-code.el --- Claude AI coding assistant for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2026

;; Author: Kiran G
;; Version: 0.2.0
;; Package-Requires: ((emacs "30.0") (magit-section "4.0.0") (transient "0.9.3"))
;; Keywords: tools ai
;; URL: https://github.com/kiranandcode/claude-code.el

;;; Commentary:

;; Claude Code integration using the Claude Agent SDK.
;;
;; Communicates with a Python backend over JSON-lines stdin/stdout.
;; The backend uses the Agent SDK to run an AI agent with built-in
;; tool access (file read/write, bash, grep, web search, etc.).
;;
;; The conversation is rendered in a magit-section buffer with collapsible
;; thinking blocks, tool-use details, and streaming token output.
;;
;; Quick start:
;;   M-x claude-code
;;   Type your prompt in the input area at the bottom and press RET.
;;   Press `s' to jump to the input area, `C-j' for a newline in the prompt.

;;; Code:

(require 'magit-section)
(require 'transient)
(require 'cl-lib)
(require 'json)
(require 'project)
(require 'seq)

;;;; Customization

(defgroup claude-code nil
  "Claude Agent SDK integration."
  :group 'tools
  :prefix "claude-code-")

(defcustom claude-code-python-command "uv"
  "Command used to invoke the Python backend.
The backend is run as: <python-command> run python3 <script>
from the python/ directory."
  :type 'string
  :group 'claude-code)

(defcustom claude-code-notes-file nil
  "Path to an org file with persistent notes.
Contents are included in every system prompt."
  :type '(choice (const nil) file)
  :group 'claude-code)

(defcustom claude-code-show-thinking nil
  "Whether thinking blocks are expanded by default."
  :type 'boolean
  :group 'claude-code)

(defcustom claude-code-show-tool-details nil
  "Whether tool-use details are expanded by default."
  :type 'boolean
  :group 'claude-code)

;;;; Session Configuration
;;
;; `claude-code-defaults' provides global fallback values.
;; `claude-code-project-config' maps directories to per-project overrides.
;; At query time, the project config is merged on top of the defaults.

(defcustom claude-code-defaults
  '((model            . nil)
    (effort           . nil)
    (permission-mode  . "bypassPermissions")
    (max-turns        . 50)
    (max-budget-usd   . nil)
    (allowed-tools    . ("Read" "Write" "Edit" "Bash" "Glob" "Grep"
                         "WebSearch" "WebFetch"))
    (betas            . nil))
  "Default session configuration used when no project override exists.
Each entry is (KEY . VALUE).  See `claude-code-project-config' for keys."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'claude-code)

(defcustom claude-code-project-config nil
  "Per-project session configuration.
An alist of (DIRECTORY . CONFIG-ALIST).  DIRECTORY is expanded and
matched as a prefix against the session working directory.  The most
specific (longest) match wins.

CONFIG-ALIST entries override `claude-code-defaults'.  Valid keys:

  model            - string or nil (e.g. \"claude-opus-4-6\")
  effort           - nil, \"low\", \"medium\", \"high\", \"max\"
  permission-mode  - \"default\", \"plan\",
                     \"acceptEdits\", \"bypassPermissions\"
  max-turns        - integer
  max-budget-usd   - float or nil
  allowed-tools    - list of tool name strings
  betas            - list of beta feature strings

Example:
  \\='((\"~/work/prod-app\" . ((model . \"claude-opus-4-6\")
                          (effort . \"high\")
                          (permission-mode . \"acceptEdits\")))
    (\"~/scratch\"       . ((model . \"claude-haiku-4-5\")
                          (effort . \"low\"))))"
  :type '(alist :key-type string
                :value-type (alist :key-type symbol
                                   :value-type sexp))
  :group 'claude-code)

;;;; Faces

(defface claude-code-header
  '((t :inherit magit-section-heading :height 1.3))
  "Buffer header."
  :group 'claude-code)

(defface claude-code-separator
  '((t :inherit shadow))
  "Visual separators."
  :group 'claude-code)

(defface claude-code-user-prompt
  '((t :inherit font-lock-keyword-face :weight bold))
  "User prompt label."
  :group 'claude-code)

(defface claude-code-assistant-label
  '((t :inherit font-lock-function-name-face :weight bold))
  "Assistant message label."
  :group 'claude-code)

(defface claude-code-thinking
  '((t :inherit font-lock-comment-face :slant italic))
  "Thinking text."
  :group 'claude-code)

(defface claude-code-tool-name
  '((t :inherit font-lock-type-face :weight bold))
  "Tool names in tool-use blocks."
  :group 'claude-code)

(defface claude-code-tool-input
  '((t :inherit font-lock-string-face))
  "Tool input details."
  :group 'claude-code)

(defface claude-code-result
  '((t :inherit success))
  "Result indicators."
  :group 'claude-code)

(defface claude-code-error
  '((t :inherit error))
  "Error messages."
  :group 'claude-code)

(defface claude-code-status
  '((t :inherit shadow :slant italic))
  "Status messages."
  :group 'claude-code)

(defface claude-code-file-link
  '((t :inherit link))
  "Clickable file paths."
  :group 'claude-code)

(defface claude-code-input-prompt
  '((t :inherit minibuffer-prompt :weight bold))
  "Input prompt at the bottom of the Claude buffer."
  :group 'claude-code)

;;;; Internal State

(defvar claude-code--package-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the claude-code package.")

(defvar claude-code--buffers (make-hash-table :test 'equal)
  "Map of directory -> buffer for active sessions.")

(defvar-local claude-code--process nil
  "Backend Python process.")

(defvar-local claude-code--cwd nil
  "Working directory for this session.")

(defvar-local claude-code--session-id nil
  "Session ID from the Agent SDK.")

(defvar-local claude-code--status 'starting
  "Process status symbol: starting, ready, working, error, stopped.")

(defvar-local claude-code--partial-line ""
  "Incomplete JSON line from process output.")

(defvar-local claude-code--messages '()
  "List of conversation messages (newest first).")

(defvar-local claude-code--streaming-text ""
  "Accumulated streaming text for current assistant response.")

(defvar-local claude-code--streaming-thinking ""
  "Accumulated streaming thinking for current assistant response.")

(defvar-local claude-code--streaming-active nil
  "Whether we are currently receiving streaming deltas.")

(defvar-local claude-code--thinking-timer nil
  "Timer for thinking spinner animation.")

(defvar-local claude-code--thinking-frame 0
  "Current frame of thinking spinner animation.")

(defvar-local claude-code--thinking-overlay nil
  "Overlay displaying the thinking spinner.")

(defvar-local claude-code--render-pending nil
  "Whether a render is scheduled.")

(defvar-local claude-code--session-overrides nil
  "Buffer-local config overrides set via the transient menu.
Merged on top of project config + defaults.")

(defvar-local claude-code--input-marker nil
  "Marker for the start of the user-editable input area at the buffer bottom.")

(defvar claude-code--prompt-history nil
  "History for Claude prompts.")

(defconst claude-code--thinking-frames
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames for the thinking spinner.")

;;;; Process Management

(defun claude-code--backend-script ()
  "Return the path to the Python backend script."
  (expand-file-name "python/claude_code_backend.py"
                    claude-code--package-dir))

(defun claude-code--start-process ()
  "Start the Python backend process."
  (when (and claude-code--process
             (process-live-p claude-code--process))
    (delete-process claude-code--process))
  (let* ((default-directory (expand-file-name "python/" claude-code--package-dir))
         (buf (current-buffer))
         (proc (make-process
                :name (format "claude-sdk-%s" (buffer-name buf))
                :command (list claude-code-python-command
                               "run" "python3"
                               (claude-code--backend-script))
                :filter (lambda (_proc output)
                          (claude-code--process-filter buf output))
                :sentinel (lambda (_proc event)
                            (claude-code--process-sentinel buf event))
                :coding 'utf-8-unix
                :connection-type 'pipe
                :noquery t)))
    (setq claude-code--process proc)
    (setq claude-code--status 'starting)))

(defun claude-code--stop-process ()
  "Stop the backend process."
  (claude-code--stop-thinking)
  (when (and claude-code--process
             (process-live-p claude-code--process))
    (claude-code--send-json '((type . "quit")))
    (sit-for 0.1)
    (when (process-live-p claude-code--process)
      (delete-process claude-code--process)))
  (setq claude-code--process nil)
  (setq claude-code--status 'stopped))

(defun claude-code--send-json (data)
  "Send DATA (an alist) as a JSON line to the backend."
  (when (and claude-code--process
             (process-live-p claude-code--process))
    (process-send-string
     claude-code--process
     (concat (json-encode data) "\n"))))

;;;; Process Filter & Sentinel

(defun claude-code--process-filter (buf output)
  "Handle OUTPUT from the backend for display buffer BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq claude-code--partial-line
            (concat claude-code--partial-line output))
      (let ((lines (split-string claude-code--partial-line "\n")))
        (setq claude-code--partial-line (car (last lines)))
        (dolist (line (butlast lines))
          (when (and line (not (string-empty-p line)))
            (condition-case err
                (claude-code--handle-event
                 (json-parse-string line :object-type 'alist))
              (error
               (message "Claude SDK: parse error: %s"
                        (error-message-string err))))))))))

(defun claude-code--process-sentinel (buf event)
  "Handle process EVENT for display buffer BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (unless (string-match-p "open" event)
        (setq claude-code--status 'stopped)
        (claude-code--stop-thinking)
        (claude-code--schedule-render)))))

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
      ;; Task events
      ("task_started"
       (push `((type . "info")
               (text . ,(format "Subagent started: %s"
                                (alist-get 'description event))))
             claude-code--messages)
       (claude-code--schedule-render))
      ("task_notification"
       (push `((type . "info")
               (text . ,(format "Subagent %s: %s"
                                (alist-get 'status event)
                                (alist-get 'summary event))))
             claude-code--messages)
       (claude-code--schedule-render))
      ;; task_progress, input_json_delta, rate_limit — ignored for now
      )))

(defun claude-code--handle-status-event (event)
  "Handle a status EVENT."
  (let ((status (alist-get 'status event)))
    (pcase status
      ("ready"
       (setq claude-code--status 'ready)
       (claude-code--stop-thinking)
       (claude-code--flush-streaming))
      ("working"
       (setq claude-code--status 'working)
       (claude-code--start-thinking))
      ("cancelled"
       (setq claude-code--status 'ready)
       (claude-code--stop-thinking)
       (claude-code--flush-streaming)
       (push '((type . "info") (text . "Cancelled."))
             claude-code--messages))
      ("error"
       (setq claude-code--status 'error)
       (claude-code--stop-thinking)))
    (claude-code--schedule-render)))

(defun claude-code--handle-system-event (event)
  "Handle a system EVENT."
  (let ((subtype (alist-get 'subtype event))
        (data (alist-get 'data event)))
    (when (equal subtype "init")
      (setq claude-code--session-id
            (alist-get 'session_id data)))))

(defun claude-code--handle-assistant-event (event)
  "Handle a complete assistant EVENT (non-streaming)."
  (claude-code--flush-streaming)
  (push event claude-code--messages)
  (claude-code--schedule-render))

(defun claude-code--handle-result-event (event)
  "Handle a result EVENT."
  (claude-code--flush-streaming)
  (claude-code--stop-thinking)
  (push event claude-code--messages)
  (claude-code--schedule-render))

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
             claude-code--streaming-active t)))))

(defun claude-code--handle-text-delta (event)
  "Handle a text_delta EVENT — append streaming text."
  (let ((text (alist-get 'text event)))
    (when text
      (setq claude-code--streaming-text
            (concat claude-code--streaming-text text))
      (claude-code--schedule-render))))

(defun claude-code--handle-thinking-delta (event)
  "Handle a thinking_delta EVENT — append streaming thinking."
  (let ((thinking (alist-get 'thinking event)))
    (when thinking
      (setq claude-code--streaming-thinking
            (concat claude-code--streaming-thinking thinking))
      ;; Only re-render occasionally for thinking (it's collapsed by default)
      (when (= 0 (mod (length claude-code--streaming-thinking) 200))
        (claude-code--schedule-render)))))

(defun claude-code--handle-block-stop (_event)
  "Handle a content_block_stop EVENT."
  ;; The complete assistant message will arrive soon; nothing to do here.
  nil)

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

;;;; Buffer Rendering

(defun claude-code--render ()
  "Render the conversation buffer."
  ;; Save any text the user has typed in the input area before erasing.
  (let* ((input-active (and claude-code--input-marker
                            (marker-buffer claude-code--input-marker)))
         (saved-input (if input-active
                          (buffer-substring-no-properties
                           claude-code--input-marker (point-max))
                        ""))
         (was-in-input (and input-active
                            (>= (point)
                                (marker-position claude-code--input-marker))))
         (at-end (or was-in-input (>= (point) (point-max))))
         (old-point (point)))
    ;; Remove old thinking overlay
    (when claude-code--thinking-overlay
      (delete-overlay claude-code--thinking-overlay)
      (setq claude-code--thinking-overlay nil))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (magit-insert-section (root)
        (claude-code--render-header)
        (insert "\n")
        ;; Messages are stored newest-first; render oldest-first
        (dolist (msg (reverse claude-code--messages))
          (claude-code--render-message msg))
        ;; Show in-progress streaming content
        (claude-code--render-streaming))
      ;; Thinking spinner overlay (cheap to update, sits at end of buffer)
      (when (eq claude-code--status 'working)
        (let ((ov (make-overlay (point-max) (point-max))))
          (overlay-put ov 'after-string
                       (propertize
                        (format "\n  %s Thinking...\n"
                                (aref claude-code--thinking-frames
                                      (mod claude-code--thinking-frame
                                           (length claude-code--thinking-frames))))
                        'face 'claude-code-thinking))
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
        ;; does not inherit read-only.
        (when (> boundary (point-min))
          (put-text-property (1- boundary) boundary
                             'rear-nonsticky '(read-only)))))
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
  (magit-insert-section (claude-user)
    (magit-insert-heading
      (propertize "▶ You" 'face 'claude-code-user-prompt))
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
  (when claude-code--thinking-overlay
    (delete-overlay claude-code--thinking-overlay)
    (setq claude-code--thinking-overlay nil)))

(defun claude-code--update-thinking-overlay ()
  "Update the thinking spinner overlay text."
  (when claude-code--thinking-overlay
    (overlay-put
     claude-code--thinking-overlay
     'after-string
     (propertize
      (format "\n  %s Thinking...\n"
              (aref claude-code--thinking-frames
                    (mod claude-code--thinking-frame
                         (length claude-code--thinking-frames))))
      'face 'claude-code-thinking))))

;;;; Session Config Lookup

(defun claude-code--session-config ()
  "Return the merged config alist for the current session.
Merge order: defaults < project config < session overrides."
  (let ((base (copy-alist claude-code-defaults))
        (dir (and claude-code--cwd (expand-file-name claude-code--cwd)))
        (best-match nil)
        (best-len 0))
    (when dir
      (dolist (entry claude-code-project-config)
        (let* ((proj-dir (expand-file-name (car entry)))
               (len (length proj-dir)))
          (when (and (string-prefix-p proj-dir dir)
                     (> len best-len))
            (setq best-match (cdr entry)
                  best-len len)))))
    ;; Layer 2: project overrides
    (dolist (override best-match)
      (setf (alist-get (car override) base) (cdr override)))
    ;; Layer 3: session overrides (set via transient mid-session)
    (dolist (override claude-code--session-overrides)
      (setf (alist-get (car override) base) (cdr override)))
    base))

(defun claude-code--config (key)
  "Look up config KEY for the current session."
  (alist-get key (claude-code--session-config)))

;;;; Notes / Org Integration

(defun claude-code--load-notes ()
  "Load notes from the configured org file, or nil."
  (when (and claude-code-notes-file
             (file-exists-p claude-code-notes-file))
    (with-temp-buffer
      (insert-file-contents claude-code-notes-file)
      (buffer-string))))

(defun claude-code--build-system-prompt ()
  "Build the system prompt, including notes if configured."
  (when-let ((notes (claude-code--load-notes)))
    (format "The user has provided the following persistent notes:\n\n%s"
            notes)))

;;;; Interactive Commands

;;;###autoload
(defun claude-code-send (prompt)
  "Send PROMPT to Claude."
  (interactive
   (list (read-string "Claude> " nil 'claude-code--prompt-history)))
  (when (string-empty-p prompt)
    (user-error "Empty prompt"))
  (push `((type . "user") (prompt . ,prompt))
        claude-code--messages)
  (let* ((cfg (claude-code--session-config))
         (cmd `((type . "query")
                (prompt . ,prompt)
                (cwd . ,claude-code--cwd)
                (allowed_tools . ,(vconcat (alist-get 'allowed-tools cfg)))
                (permission_mode . ,(alist-get 'permission-mode cfg))
                (max_turns . ,(alist-get 'max-turns cfg)))))
    (when-let ((v (alist-get 'model cfg)))
      (push `(model . ,v) cmd))
    (when-let ((v (alist-get 'effort cfg)))
      (push `(effort . ,v) cmd))
    (when-let ((v (alist-get 'max-budget-usd cfg)))
      (push `(max_budget_usd . ,v) cmd))
    (when-let ((v (alist-get 'betas cfg)))
      (push `(betas . ,(vconcat v)) cmd))
    (when-let ((sys-prompt (claude-code--build-system-prompt)))
      (push `(system_prompt . ,sys-prompt) cmd))
    (claude-code--send-json cmd))
  (claude-code--schedule-render))

;;;###autoload
(defun claude-code-send-region (start end)
  "Send the region from START to END with a prompt."
  (interactive "r")
  (let* ((region-text (buffer-substring-no-properties start end))
         (file (buffer-file-name))
         (prompt (read-string "Claude (with region)> "
                              nil 'claude-code--prompt-history))
         (full-prompt
          (format "%s\n\nContext from %s:\n```\n%s\n```"
                  prompt (or file "buffer") region-text)))
    (with-current-buffer (claude-code--get-or-create-buffer)
      (claude-code-send full-prompt))))

;;;###autoload
(defun claude-code-send-buffer-file ()
  "Send the current file path as context with a prompt."
  (interactive)
  (let* ((file (or (buffer-file-name) (user-error "Buffer has no file")))
         (prompt (read-string
                  (format "Claude (re: %s)> "
                          (file-name-nondirectory file))
                  nil 'claude-code--prompt-history)))
    (with-current-buffer (claude-code--get-or-create-buffer)
      (claude-code-send (format "%s\n\nRegarding file: %s" prompt file)))))

(defun claude-code-cancel ()
  "Cancel the current query."
  (interactive)
  (claude-code--send-json '((type . "cancel")))
  (claude-code--stop-thinking)
  (setq claude-code--status 'ready)
  (claude-code--schedule-render))

(defun claude-code-clear ()
  "Clear the conversation."
  (interactive)
  (setq claude-code--messages '()
        claude-code--session-id nil
        claude-code--streaming-text ""
        claude-code--streaming-thinking ""
        claude-code--streaming-active nil)
  (claude-code--schedule-render))

(defun claude-code-kill ()
  "Kill the Claude session and buffer."
  (interactive)
  (claude-code--stop-process)
  (when claude-code--cwd
    (remhash claude-code--cwd claude-code--buffers))
  (kill-buffer))

(defun claude-code-open-notes ()
  "Open the notes org file."
  (interactive)
  (if claude-code-notes-file
      (find-file claude-code-notes-file)
    (user-error "Set `claude-code-notes-file' first")))

(defun claude-code-toggle-thinking ()
  "Toggle whether thinking blocks are expanded by default."
  (interactive)
  (setq claude-code-show-thinking (not claude-code-show-thinking))
  (message "Thinking: %s" (if claude-code-show-thinking "visible" "hidden"))
  (claude-code--schedule-render))

(defun claude-code-toggle-tool-details ()
  "Toggle whether tool details are expanded by default."
  (interactive)
  (setq claude-code-show-tool-details
        (not claude-code-show-tool-details))
  (message "Tool details: %s"
           (if claude-code-show-tool-details "visible" "hidden"))
  (claude-code--schedule-render))

;;;; Inline Input Commands

(defun claude-code-submit-input ()
  "Submit the text currently typed in the input area."
  (interactive)
  (when claude-code--input-marker
    (let ((text (string-trim
                 (buffer-substring-no-properties
                  claude-code--input-marker (point-max)))))
      (unless (string-empty-p text)
        ;; Clear the input area before sending so the render shows it clean
        (let ((inhibit-read-only t))
          (delete-region claude-code--input-marker (point-max)))
        (claude-code-send text)))))

(defun claude-code-focus-input ()
  "Move point to the end of the input area, ready to type."
  (interactive)
  (goto-char (point-max)))

(defun claude-code-return ()
  "Submit the input if point is in the input area; otherwise toggle section."
  (interactive)
  (if (and claude-code--input-marker
           (>= (point) (marker-position claude-code--input-marker)))
      (claude-code-submit-input)
    (call-interactively #'magit-section-toggle)))

;;;; Session Config Commands

(defun claude-code-set-model (model)
  "Set MODEL for the current session."
  (interactive
   (list (completing-read
          "Model: "
          '("claude-opus-4-6" "claude-sonnet-4-6" "claude-haiku-4-5")
          nil nil nil nil
          (claude-code--config 'model))))
  (setf (alist-get 'model claude-code--session-overrides)
        (if (string-empty-p model) nil model))
  (claude-code--schedule-render))

(defun claude-code-set-effort (effort)
  "Set EFFORT level for the current session."
  (interactive
   (list (completing-read
          "Effort: "
          '("low" "medium" "high" "max" "nil")
          nil t nil nil
          (or (claude-code--config 'effort) "nil"))))
  (setf (alist-get 'effort claude-code--session-overrides)
        (if (equal effort "nil") nil effort))
  (claude-code--schedule-render))

(defun claude-code-set-permission-mode (mode)
  "Set permission MODE for the current session."
  (interactive
   (list (completing-read
          "Permission mode: "
          '("default" "plan" "acceptEdits" "bypassPermissions")
          nil t nil nil
          (claude-code--config 'permission-mode))))
  (setf (alist-get 'permission-mode claude-code--session-overrides)
        mode)
  (claude-code--schedule-render))

;;;; Transient Menu

(transient-define-prefix claude-code-menu ()
  "Claude Code command menu."
  ["Send"
   ("s" "Focus input area" claude-code-focus-input)
   ("r" "Send region" claude-code-send-region)
   ("f" "Send file context" claude-code-send-buffer-file)]
  ["Control"
   ("c" "Cancel" claude-code-cancel)
   ("C" "Clear conversation" claude-code-clear)
   ("k" "Kill session" claude-code-kill)]
  ["Session"
   ("m" "Set model" claude-code-set-model)
   ("e" "Set effort" claude-code-set-effort)
   ("p" "Set permission mode" claude-code-set-permission-mode)]
  ["View"
   ("t" "Toggle thinking" claude-code-toggle-thinking)
   ("T" "Toggle tool details" claude-code-toggle-tool-details)
   ("n" "Open notes file" claude-code-open-notes)])

;;;; Keymap

(defvar-keymap claude-code-mode-map
  :doc "Keymap for Claude Code mode."
  :parent magit-section-mode-map
  "s"   #'claude-code-focus-input
  "r"   #'claude-code-send-region
  "c"   #'claude-code-cancel
  "C"   #'claude-code-clear
  "k"   #'claude-code-kill
  "n"   #'claude-code-open-notes
  "?"   #'claude-code-menu
  "q"   #'quit-window
  "G"   #'claude-code--render
  "RET" #'claude-code-return
  "C-j" #'newline)

;;;; Major Mode

(define-derived-mode claude-code-mode magit-section-mode "Claude"
  "Major mode for Claude Code interaction.
\\{claude-code-mode-map}"
  :group 'claude-code
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  ;; Allow typing in the input area at the bottom of the buffer.
  ;; magit-section-mode (via special-mode) sets buffer-read-only t; we
  ;; override that here and rely on the render function to keep the
  ;; conversation content visually stable via inhibit-read-only.
  (setq-local buffer-read-only nil)
  (visual-line-mode 1)
  (goto-address-mode 1))

;;;; Entry Points

(defun claude-code--buffer-name (dir)
  "Generate a buffer name for DIR."
  (format "*Claude: %s*" (abbreviate-file-name dir)))

(defun claude-code--get-or-create-buffer (&optional dir)
  "Get or create a Claude buffer for DIR."
  (let* ((directory (or dir
                        (when-let ((proj (project-current)))
                          (project-root proj))
                        default-directory))
         (existing (gethash directory claude-code--buffers)))
    (if (and existing (buffer-live-p existing))
        existing
      (let ((buf (get-buffer-create
                  (claude-code--buffer-name directory))))
        (puthash directory buf claude-code--buffers)
        (with-current-buffer buf
          (claude-code-mode)
          (setq claude-code--cwd directory)
          (claude-code--start-process)
          (claude-code--schedule-render))
        buf))))

;;;###autoload
(defun claude-code (&optional directory)
  "Open Claude Code for DIRECTORY (defaults to project root)."
  (interactive)
  (pop-to-buffer (claude-code--get-or-create-buffer directory)))

;;;###autoload
(defun claude-code-quick (prompt)
  "Send PROMPT to Claude without switching buffers."
  (interactive "sClaude> ")
  (let ((buf (claude-code--get-or-create-buffer)))
    (with-current-buffer buf
      (claude-code-send prompt))
    (message "Sent: %s" (truncate-string-to-width prompt 60))))

;;;; Development / Reload

;;;###autoload
(defun claude-code-reload ()
  "Reload `claude-code.el' from source, restart backend, keep conversation.
Designed for dogfooding: edit the source, hit the keybinding, see changes."
  (interactive)
  (let ((source-file (expand-file-name "claude-code.el"
                                       claude-code--package-dir))
        ;; Save conversation state from every live Claude buffer
        (saved-states '()))
    (maphash (lambda (dir buf)
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (push (list :dir dir
                               :messages claude-code--messages
                               :session-id claude-code--session-id
                               :session-overrides claude-code--session-overrides
                               :streaming-text claude-code--streaming-text
                               :streaming-thinking claude-code--streaming-thinking
                               :streaming-active claude-code--streaming-active)
                         saved-states)
                   ;; Kill the old backend process
                   (claude-code--stop-process))))
             claude-code--buffers)
    ;; Re-evaluate the source file
    (load source-file nil t)
    ;; Restore each buffer with saved state
    (dolist (state saved-states)
      (let* ((dir (plist-get state :dir))
             (buf (gethash dir claude-code--buffers)))
        (when (and buf (buffer-live-p buf))
          (with-current-buffer buf
            ;; Re-activate the mode (picks up new keymap, render fns, etc.)
            (claude-code-mode)
            (setq claude-code--cwd dir)
            ;; Restore conversation
            (setq claude-code--messages (plist-get state :messages)
                  claude-code--session-id (plist-get state :session-id)
                  claude-code--session-overrides (plist-get state :session-overrides)
                  claude-code--streaming-text (plist-get state :streaming-text)
                  claude-code--streaming-thinking (plist-get state :streaming-thinking)
                  claude-code--streaming-active (plist-get state :streaming-active))
            ;; Start a fresh backend
            (claude-code--start-process)
            (claude-code--schedule-render)))))
    (message "claude-code reloaded (%d buffer%s)"
             (length saved-states)
             (if (= 1 (length saved-states)) "" "s"))))

(provide 'claude-code)
;;; claude-code.el ends here
