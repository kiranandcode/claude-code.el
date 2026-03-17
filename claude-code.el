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

(defcustom claude-code-org-roam-project-dir-property "CLAUDE_PROJECT_DIR"
  "Org property used to identify per-project context notes in org-roam.
An org-roam note with this property set to the expanded path of a project
directory is included in the system prompt whenever Claude runs in that
directory.  Create and edit such a note with `claude-code-open-dir-notes'."
  :type 'string
  :group 'claude-code)

(defcustom claude-code-org-roam-project-todos-property "CLAUDE_PROJECT_TODOS"
  "Org property used to identify per-project TODO notes in org-roam.
An org-roam note with this property set to the expanded path of a project
directory is included in the system prompt whenever Claude runs in that
directory.  Create and edit such a note with `claude-code-open-dir-todos'."
  :type 'string
  :group 'claude-code)

(defcustom claude-code-org-roam-skills-hub-title "Claude Code Skills"
  "Title of the org-roam hub note that indexes all Claude Code skills.
This note is created automatically by `claude-code-org-roam-visit-skills-hub'
if it does not yet exist."
  :type 'string
  :group 'claude-code)

(defcustom claude-code-org-roam-skill-tag "claude_skill"
  "Filetag added to every org-roam skill note created by claude-code.
Set to nil to omit the filetag."
  :type '(choice (const nil) string)
  :group 'claude-code)

(defcustom claude-code-org-roam-skill-property "CLAUDE_SKILL"
  "Org property set to \"t\" in the PROPERTIES drawer of every skill note.
Used to identify skill nodes when building the system prompt."
  :type 'string
  :group 'claude-code)

(defcustom claude-code-show-thinking nil
  "Whether thinking blocks are expanded by default."
  :type 'boolean
  :group 'claude-code)

(defcustom claude-code-show-tool-details nil
  "Whether tool-use details are expanded by default."
  :type 'boolean
  :group 'claude-code)

(defcustom claude-code-agents-sidebar-width 40
  "Width of the agent sidebar window."
  :type 'integer
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
  "List of conversation messages (newest first).
Each element is an alist with at least a `type' key.  Types include:
  \"user\"      — user prompt (has `prompt' key)
  \"assistant\" — assistant turn (has `content' vector of blocks)
  \"result\"    — query result (has `total_cost_usd', `num_turns', etc.)
  \"error\"     — error (has `message' key)
  \"info\"      — informational (has `text' key)")

(defvar-local claude-code--last-query-cmd nil
  "The last JSON command alist sent to the backend.
Useful for debugging — inspect with:
  (with-current-buffer \"*Claude: ...*\" claude-code--last-query-cmd)")

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

(defun claude-code--input-area-p ()
  "Return non-nil if point is in the input area."
  (and claude-code--input-marker
       (marker-buffer claude-code--input-marker)
       (>= (point) (marker-position claude-code--input-marker))))

(defun claude-code--self-insert-or-undefined ()
  "Self-insert in the input area, signal undefined otherwise.
Overrides `suppress-keymap' from `special-mode' so that printable
characters work in the input area."
  (interactive)
  (if (claude-code--input-area-p)
      (call-interactively #'self-insert-command)
    (user-error "%s is undefined" (key-description (this-command-keys)))))

(defmacro claude-code--def-key-command (name cmd doc)
  "Define NAME as a command that self-inserts in input, else run CMD.
DOC is the docstring."
  `(defun ,name ()
     ,doc
     (interactive)
     (if (claude-code--input-area-p)
         (call-interactively #'self-insert-command)
       (call-interactively ,cmd))))

(claude-code--def-key-command claude-code-key-focus-input
  #'claude-code-focus-input "Focus input or self-insert.")
(claude-code--def-key-command claude-code-key-send-region
  #'claude-code-send-region "Send region or self-insert.")
(claude-code--def-key-command claude-code-key-cancel
  #'claude-code-cancel "Cancel or self-insert.")
(claude-code--def-key-command claude-code-key-clear
  #'claude-code-clear "Clear or self-insert.")
(claude-code--def-key-command claude-code-key-kill
  #'claude-code-kill "Kill or self-insert.")
(claude-code--def-key-command claude-code-key-restart
  #'claude-code-restart "Restart or self-insert.")
(claude-code--def-key-command claude-code-key-open-notes
  #'claude-code-open-notes "Open notes or self-insert.")
(claude-code--def-key-command claude-code-key-open-dir-notes
  #'claude-code-open-dir-notes "Open dir notes or self-insert.")
(claude-code--def-key-command claude-code-key-open-dir-todos
  #'claude-code-open-dir-todos "Open dir todos or self-insert.")
(claude-code--def-key-command claude-code-key-agents-toggle
  #'claude-code-agents-toggle "Toggle agents or self-insert.")
(claude-code--def-key-command claude-code-key-sync
  #'claude-code-sync "Sync or self-insert.")
(claude-code--def-key-command claude-code-key-menu
  #'claude-code-menu "Menu or self-insert.")
(claude-code--def-key-command claude-code-key-quit
  #'quit-window "Quit or self-insert.")
(claude-code--def-key-command claude-code-key-render
  #'claude-code--render "Re-render or self-insert.")

(defun claude-code-key-space ()
  "Self-insert in input area, scroll up in conversation."
  (interactive)
  (if (claude-code--input-area-p)
      (call-interactively #'self-insert-command)
    (call-interactively #'scroll-up-command)))

(defvar claude-code--prompt-history nil
  "History for Claude prompts.")

(defconst claude-code--thinking-frames
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames for the thinking spinner.")

;;;; Slash Commands

(defconst claude-code--slash-commands
  '(("/clear"         . "Clear the conversation history")
    ("/model"         . "Set the model for this session")
    ("/effort"        . "Set the thinking effort level")
    ("/notes"         . "Open the global notes file")
    ("/project-notes" . "Open or create project context notes")
    ("/todos"         . "Open or create project TODO list")
    ("/inspect"       . "Show session state")
    ("/help"          . "Show the command menu"))
  "Slash commands available in the Claude input area.")

;;;; Queuing & Stats State

(defvar-local claude-code--input-queued nil
  "Non-nil when the input area has been queued to send on next ready status.")

(defvar-local claude-code--query-start-time nil
  "Float time when the current query started (set when status → working).")

(defvar-local claude-code--thinking-block-start-time nil
  "Float time when the current thinking block started streaming, or nil.")

(defvar-local claude-code--thinking-elapsed-sec 0.0
  "Accumulated completed-thinking-block time in seconds for the current query.")

(defvar-local claude-code--streaming-char-count 0
  "Total characters received from text/thinking deltas this query.
Used as a rough token-count approximation in the thinking spinner.")

;;;; UV Environment Management

(defun claude-code--python-dir ()
  "Return the path to the python/ subdirectory."
  (expand-file-name "python/" claude-code--package-dir))

(defun claude-code--uv-available-p ()
  "Return non-nil if the configured Python command is on PATH."
  (executable-find claude-code-python-command))

(defun claude-code--venv-ready-p ()
  "Return non-nil if the Python virtual environment exists."
  (file-directory-p
   (expand-file-name ".venv" (claude-code--python-dir))))

(defun claude-code--run-uv-sync ()
  "Run `uv sync' in the python directory.
Shows output in *claude-code-setup* on failure."
  (message "claude-code: running uv sync...")
  (let* ((default-directory (claude-code--python-dir))
         (buf (get-buffer-create "*claude-code-setup*")))
    (with-current-buffer buf (erase-buffer))
    (let ((result (call-process claude-code-python-command nil buf nil "sync")))
      (if (= result 0)
          (progn
            (when (get-buffer-window buf)
              (delete-window (get-buffer-window buf)))
            (kill-buffer buf)
            (message "claude-code: Python environment ready."))
        (pop-to-buffer buf)
        (user-error
         "claude-code: `uv sync' failed (exit %d).  See *claude-code-setup*"
         result)))))

(defun claude-code--ensure-environment ()
  "Ensure uv is installed and the Python venv is ready.
Signals an error if uv is not found.  Runs `uv sync' if the
virtual environment does not exist yet."
  (unless (claude-code--uv-available-p)
    (user-error
     "claude-code: `%s' not found.  Install uv: https://docs.astral.sh/uv/"
     claude-code-python-command))
  (unless (claude-code--venv-ready-p)
    (claude-code--run-uv-sync)))

;;;###autoload
(defun claude-code-sync ()
  "Force-sync the Python environment by running `uv sync'."
  (interactive)
  (unless (claude-code--uv-available-p)
    (user-error
     "claude-code: `%s' not found.  Install uv: https://docs.astral.sh/uv/"
     claude-code-python-command))
  (claude-code--run-uv-sync))

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

(defun claude-code--agent-root-ids ()
  "Return a list of root agent IDs."
  (let (roots)
    (maphash (lambda (id agent)
               (when (claude-code--agent-root-p agent)
                 (push id roots)))
             claude-code--agents)
    (nreverse roots)))

;;;; Process Management

(defun claude-code--backend-script ()
  "Return the path to the Python backend script."
  (expand-file-name "python/claude_code_backend.py"
                    claude-code--package-dir))

(defun claude-code--start-process ()
  "Start the Python backend process.
Ensures the Python environment is set up before launching."
  (claude-code--ensure-environment)
  (when (and claude-code--process
             (process-live-p claude-code--process))
    (delete-process claude-code--process))
  ;; Clear stale session ID — old sessions can't be resumed across
  ;; backend restarts and will cause the Agent SDK to crash.
  (setq claude-code--session-id nil)
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
  "Send DATA (an alist) as a JSON line to the backend.
If the process is dead, restart it automatically before sending."
  (unless (and claude-code--process
               (process-live-p claude-code--process))
    (message "claude-code: backend not running, restarting...")
    (claude-code--start-process)
    ;; Wait for the process to emit the initial "ready" status.
    (let ((waited 0))
      (while (and (< waited 5)
                  (not (eq claude-code--status 'ready)))
        (sit-for 0.5)
        (cl-incf waited 0.5))))
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
            (if (not (eq (aref line 0) ?{))
                ;; Not JSON — log it but don't crash
                (message "Claude SDK: non-JSON line: %S"
                         (substring line 0 (min 200 (length line))))
              (condition-case err
                  (claude-code--handle-event
                   (json-parse-string line :object-type 'alist))
                (error
                 (message "Claude SDK: parse error on: %S — %s"
                          (substring line 0 (min 200 (length line)))
                          (error-message-string err)))))))))))

(defun claude-code--process-sentinel (buf event)
  "Handle process EVENT for display buffer BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (unless (string-match-p "open" event)
        (setq claude-code--status 'stopped)
        (setq claude-code--process nil)
        (claude-code--stop-thinking)
        (when claude-code--cwd
          (claude-code--agent-update claude-code--cwd :status 'stopped))
        (push `((type . "info")
                (text . ,(format "Backend process exited: %s  Press R to restart."
                                 (string-trim event))))
              claude-code--messages)
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
      ;; Task / subagent events
      ("task_started"
       (let ((task-id (alist-get 'task_id event))
             (desc (alist-get 'description event)))
         (when task-id
           (claude-code--agent-register
            task-id
            :type 'task :description desc :status 'working
            :parent-id claude-code--cwd :cwd claude-code--cwd
            :children nil)
           (claude-code--agent-add-child claude-code--cwd task-id))
         (push `((type . "info")
                 (text . ,(format "Subagent started: %s" desc)))
               claude-code--messages)
         (claude-code--schedule-render)))
      ("task_progress"
       (let ((task-id (alist-get 'task_id event)))
         (when task-id
           (claude-code--agent-update
            task-id
            :description (alist-get 'description event)
            :last-tool (alist-get 'last_tool_name event)
            :status 'working))))
      ("task_notification"
       (let ((task-id (alist-get 'task_id event))
             (status (alist-get 'status event))
             (summary (alist-get 'summary event)))
         (when task-id
           (claude-code--agent-update
            task-id
            :status (intern (or status "completed"))
            :summary summary))
         (push `((type . "info")
                 (text . ,(format "Subagent %s: %s" status summary)))
               claude-code--messages)
         (claude-code--schedule-render)))
      ;; input_json_delta, rate_limit — ignored for now
      )))

(defun claude-code--handle-status-event (event)
  "Handle a status EVENT."
  (let ((status (alist-get 'status event)))
    (pcase status
      ("ready"
       (setq claude-code--status 'ready)
       (claude-code--stop-thinking)
       (claude-code--flush-streaming)
       (setq claude-code--query-start-time nil)
       (setq claude-code--thinking-block-start-time nil)
       ;; Auto-send queued input, if any.
       (when claude-code--input-queued
         (let ((queued claude-code--input-queued))
           (setq claude-code--input-queued nil)
           (when (and claude-code--input-marker
                      (marker-buffer claude-code--input-marker))
             (let ((inhibit-read-only t))
               (delete-region claude-code--input-marker (point-max))))
           (claude-code--dispatch-input queued)))
       (when claude-code--cwd
         (claude-code--agent-update claude-code--cwd :status 'ready)))
      ("working"
       (setq claude-code--status 'working)
       (setq claude-code--query-start-time (float-time)
             claude-code--streaming-char-count 0
             claude-code--thinking-elapsed-sec 0.0
             claude-code--thinking-block-start-time nil)
       (claude-code--start-thinking)
       (when claude-code--cwd
         (claude-code--agent-update claude-code--cwd :status 'working)))
      ("cancelled"
       (setq claude-code--status 'ready)
       (claude-code--stop-thinking)
       (claude-code--flush-streaming)
       (setq claude-code--query-start-time nil
             claude-code--thinking-block-start-time nil
             claude-code--input-queued nil)
       (when claude-code--cwd
         (claude-code--agent-update claude-code--cwd :status 'ready))
       (push '((type . "info") (text . "Cancelled."))
             claude-code--messages))
      ("error"
       (setq claude-code--status 'error)
       (claude-code--stop-thinking)
       (setq claude-code--query-start-time nil
             claude-code--thinking-block-start-time nil)
       (when claude-code--cwd
         (claude-code--agent-update claude-code--cwd :status 'error))))
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
                       (propertize (claude-code--thinking-overlay-string)
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
          (concat stats-line
                  (format "  ⏳ queued: %s\n"
                          (truncate-string-to-width
                           claude-code--input-queued 60 nil nil "…")))
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
  (when claude-code--thinking-overlay
    (delete-overlay claude-code--thinking-overlay)
    (setq claude-code--thinking-overlay nil)))

(defun claude-code--update-thinking-overlay ()
  "Update the thinking spinner overlay text."
  (when claude-code--thinking-overlay
    (overlay-put
     claude-code--thinking-overlay
     'after-string
     (propertize (claude-code--thinking-overlay-string)
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

(defun claude-code--org-roam-find-project-notes-node (dir)
  "Return the best-matching org-roam project-notes node for DIR, or nil.
Performs longest-prefix matching: a node whose
`claude-code-org-roam-project-dir-property' is a prefix of DIR's expanded
path is considered a match, and the most specific (longest) match wins.
This lets a single note cover an entire directory tree (e.g. a note for
\"~/org\" also matches \"~/org/roam\" and any subdirectory)."
  (when (claude-code--org-roam-available-p)
    (let ((target    (file-name-as-directory (expand-file-name dir)))
          (best-node nil)
          (best-len  0))
      (dolist (node (org-roam-node-list))
        (when-let ((prop (cdr (assoc claude-code-org-roam-project-dir-property
                                    (org-roam-node-properties node)))))
          (let ((prop-dir (file-name-as-directory (expand-file-name prop))))
            (when (and (string-prefix-p prop-dir target)
                       (> (length prop-dir) best-len))
              (setq best-node node
                    best-len  (length prop-dir))))))
      best-node)))

(defun claude-code--load-dir-notes ()
  "Load per-project context from the org-roam project-notes node, or nil.
Finds a node for `claude-code--cwd' via
`claude-code-org-roam-project-dir-property' and returns its body text."
  (when (and (claude-code--org-roam-available-p) claude-code--cwd)
    (when-let ((node (claude-code--org-roam-find-project-notes-node
                      claude-code--cwd)))
      (claude-code--org-roam-node-body node))))

(defun claude-code--org-roam-find-project-todos-node (dir)
  "Return the best-matching org-roam project-todos node for DIR, or nil.
Uses the same longest-prefix matching as
`claude-code--org-roam-find-project-notes-node' but queries
`claude-code-org-roam-project-todos-property' instead."
  (when (claude-code--org-roam-available-p)
    (let ((target    (file-name-as-directory (expand-file-name dir)))
          (best-node nil)
          (best-len  0))
      (dolist (node (org-roam-node-list))
        (when-let ((prop (cdr (assoc claude-code-org-roam-project-todos-property
                                    (org-roam-node-properties node)))))
          (let ((prop-dir (file-name-as-directory (expand-file-name prop))))
            (when (and (string-prefix-p prop-dir target)
                       (> (length prop-dir) best-len))
              (setq best-node node
                    best-len  (length prop-dir))))))
      best-node)))

(defun claude-code--load-dir-todos ()
  "Load per-project TODOs from the org-roam project-todos node, or nil.
Finds a node for `claude-code--cwd' via
`claude-code-org-roam-project-todos-property' and returns its body text.
Returns nil if the body is empty or contains only template boilerplate."
  (when (and (claude-code--org-roam-available-p) claude-code--cwd)
    (when-let ((node (claude-code--org-roam-find-project-todos-node
                      claude-code--cwd)))
      (let* ((body (claude-code--org-roam-node-body node))
             ;; Strip comment lines and empty TODO headlines
             (cleaned (with-temp-buffer
                        (insert body)
                        (goto-char (point-min))
                        ;; Remove comment lines (# ...)
                        (flush-lines "^#[[:space:]]" (point-min) (point-max))
                        ;; Remove empty TODO headlines (* TODO\s*$)
                        (goto-char (point-min))
                        (flush-lines "^\\*+[[:space:]]+\\(TODO\\|NEXT\\|DONE\\|CANCELLED\\)[[:space:]]*$"
                                     (point-min) (point-max))
                        (string-trim (buffer-string)))))
        (unless (string-empty-p cleaned)
          cleaned)))))

;;;; Org-Roam Skills Integration

(defun claude-code--org-roam-available-p ()
  "Return non-nil if org-roam is loaded and `org-roam-directory' is usable."
  (and (featurep 'org-roam)
       (bound-and-true-p org-roam-directory)
       (file-directory-p org-roam-directory)))

(defun claude-code--org-roam-slugify (title)
  "Convert TITLE to a filesystem-safe slug for use in file names."
  (let* ((s (downcase title))
         (s (replace-regexp-in-string "[^a-z0-9]+" "-" s))
         (s (string-trim s "-")))
    s))

(defun claude-code--org-roam-find-node-by-title (title)
  "Return the first org-roam node whose title equals TITLE, or nil."
  (seq-find (lambda (node)
              (equal (org-roam-node-title node) title))
            (org-roam-node-list)))

(defun claude-code--org-roam-new-node-file (title extra-properties body)
  "Create a new org-roam node file and register it in the database.
TITLE is the node title; EXTRA-PROPERTIES is an alist of additional
PROPERTIES-drawer entries; BODY is optional text appended after the
front-matter.  Returns a cons cell (FILE . ID)."
  (require 'org-id)
  (unless (claude-code--org-roam-available-p)
    (user-error "org-roam is not available; install and configure it first"))
  (let* ((id   (org-id-new))
         (slug (claude-code--org-roam-slugify title))
         (file (expand-file-name
                (format "%s-%s.org"
                        (format-time-string "%Y%m%d%H%M%S") slug)
                org-roam-directory))
         (is-skill (assoc claude-code-org-roam-skill-property
                          extra-properties)))
    (with-temp-file file
      (insert ":PROPERTIES:\n"
              (format ":ID:       %s\n" id))
      (dolist (prop extra-properties)
        (insert (format ":%s: %s\n" (car prop) (cdr prop))))
      (insert ":END:\n"
              (format "#+title: %s\n" title))
      (when (and is-skill claude-code-org-roam-skill-tag)
        (insert (format "#+filetags: :%s:\n"
                        claude-code-org-roam-skill-tag)))
      (when body
        (insert "\n" body "\n")))
    (with-current-buffer (find-file-noselect file)
      (org-roam-db-update-file))
    (cons file id)))

(defun claude-code--org-roam-node-body (node)
  "Return the body text of NODE, stripping org front-matter."
  (with-temp-buffer
    (insert-file-contents (org-roam-node-file node))
    (goto-char (point-min))
    ;; Skip :PROPERTIES: ... :END: drawer.
    (when (looking-at ":PROPERTIES:")
      (re-search-forward "^:END:" nil t)
      (forward-line 1))
    ;; Skip #+keyword: lines.
    (while (looking-at "#\\+")
      (forward-line 1))
    ;; Skip leading blank lines.
    (while (looking-at "^[[:space:]]*$")
      (forward-line 1))
    (buffer-substring-no-properties (point) (point-max))))

(defun claude-code--org-roam-skills-hub-node ()
  "Return the org-roam skills hub node, creating it if it does not exist."
  (unless (claude-code--org-roam-available-p)
    (user-error "org-roam is not available; install and configure it first"))
  (or (claude-code--org-roam-find-node-by-title
       claude-code-org-roam-skills-hub-title)
      (progn
        (claude-code--org-roam-new-node-file
         claude-code-org-roam-skills-hub-title
         '(("CLAUDE_SKILLS_HUB" . "t"))
         "Index of Claude Code skills.  Each skill is an org-roam note\n\
linked from here and carries the CLAUDE_SKILL property.\n\n* Skills\n")
        ;; Sync DB so the new node is immediately queryable.
        (org-roam-db-sync)
        (claude-code--org-roam-find-node-by-title
         claude-code-org-roam-skills-hub-title))))

(defun claude-code--org-roam-load-skills ()
  "Return a formatted string of all org-roam skill note bodies, or nil.
Skill nodes are identified by having `claude-code-org-roam-skill-property'
set to \"t\" in their PROPERTIES drawer."
  (when (claude-code--org-roam-available-p)
    (let ((skill-nodes
           (seq-filter
            (lambda (node)
              (equal "t"
                     (cdr (assoc claude-code-org-roam-skill-property
                                 (org-roam-node-properties node)))))
            (org-roam-node-list))))
      (when skill-nodes
        (concat
         "The user has defined the following Claude Code skills:\n\n"
         (mapconcat
          (lambda (node)
            (format "--- Skill: %s ---\n%s"
                    (org-roam-node-title node)
                    (claude-code--org-roam-node-body node)))
          skill-nodes
          "\n"))))))

(defun claude-code--build-system-prompt ()
  "Build the system prompt from notes, dir context, todos, and org-roam skills."
  (let ((parts nil))
    (when-let ((notes (claude-code--load-notes)))
      (push (format "The user has provided the following persistent notes:\n\n%s"
                    notes)
            parts))
    (when-let ((dir-notes (claude-code--load-dir-notes)))
      (push (format "The following context is specific to the current project \
directory (%s):\n\n%s"
                    (abbreviate-file-name claude-code--cwd)
                    dir-notes)
            parts))
    (when-let ((dir-todos (claude-code--load-dir-todos)))
      (push (format "The following TODO list is for the current project \
directory (%s):\n\n%s"
                    (abbreviate-file-name claude-code--cwd)
                    dir-todos)
            parts))
    (when-let ((skills (claude-code--org-roam-load-skills)))
      (push skills parts))
    (when parts
      (mapconcat #'identity (nreverse parts) "\n\n"))))

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
  (when claude-code--cwd
    (claude-code--agent-update
     claude-code--cwd
     :description (truncate-string-to-width prompt 60)))
  (let* ((cwd (or claude-code--cwd default-directory))
         (cfg (claude-code--session-config))
         (cmd `((type . "query")
                (prompt . ,prompt)
                (cwd . ,cwd)
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
    ;; Resume the existing session so Claude retains conversation history.
    (when claude-code--session-id
      (push `(resume . ,claude-code--session-id) cmd))
    (setq claude-code--last-query-cmd cmd)
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
  "Cancel the current query.
Also clears any queued message — the text remains in the input area
so it can be edited and re-submitted."
  (interactive)
  (claude-code--send-json '((type . "cancel")))
  (claude-code--stop-thinking)
  (setq claude-code--status 'ready
        claude-code--input-queued nil)
  (claude-code--schedule-render))

(defun claude-code-clear ()
  "Clear the conversation."
  (interactive)
  ;; Clear subagents from registry
  (when claude-code--cwd
    (when-let ((agent (gethash claude-code--cwd claude-code--agents)))
      (dolist (child-id (plist-get agent :children))
        (remhash child-id claude-code--agents))
      (puthash claude-code--cwd
               (plist-put agent :children nil)
               claude-code--agents)
      (run-hooks 'claude-code-agents-update-hook)))
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
    (claude-code--agent-unregister claude-code--cwd)
    (remhash claude-code--cwd claude-code--buffers))
  (kill-buffer))

(defun claude-code-restart ()
  "Restart the backend process, preserving conversation history.
Use this when the backend crashes or stops responding."
  (interactive)
  (claude-code--stop-process)
  ;; Ensure cwd is set (may have been lost during a bad reload)
  (unless claude-code--cwd
    (setq claude-code--cwd
          (or (when-let ((proj (project-current)))
                (project-root proj))
              default-directory)))
  ;; Clear stale session — will be set fresh by the new process
  (setq claude-code--session-id nil)
  (claude-code--start-process)
  (push '((type . "info") (text . "Backend restarted."))
        claude-code--messages)
  (claude-code--schedule-render)
  (message "claude-code: backend restarted"))

(defun claude-code-open-notes ()
  "Open the notes org file."
  (interactive)
  (if claude-code-notes-file
      (find-file claude-code-notes-file)
    (user-error "Set `claude-code-notes-file' first")))

;;;###autoload
(defun claude-code-open-dir-notes ()
  "Open the org-roam project-context note for the current session directory.
If no such note exists yet, create one with a starter template and open it.
The note body is included in every system prompt when Claude runs in this
directory.  It is stored in org-roam (not in the project directory itself)
and identified by having `claude-code-org-roam-project-dir-property' set to
the expanded project path."
  (interactive)
  (unless (claude-code--org-roam-available-p)
    (user-error "org-roam is not available; install and configure it first"))
  (let* ((dir    (expand-file-name (or claude-code--cwd default-directory)))
         (abbrev (abbreviate-file-name dir))
         (title  (format "Project context: %s" abbrev))
         (node   (claude-code--org-roam-find-project-notes-node dir)))
    (if node
        (org-roam-node-visit node)
      ;; Create a new project-notes node with a useful template.
      (let* ((body
              (concat
               "# This file is included in every Claude system prompt when working\n"
               "# in this directory.  Edit it to give Claude persistent knowledge\n"
               "# about this project.\n"
               "\n"
               "* About this project\n"
               "\n"
               (format "Add context about %s here.\n" abbrev)))
             (result (claude-code--org-roam-new-node-file
                      title
                      `((,claude-code-org-roam-project-dir-property . ,dir))
                      body))
             (file (car result)))
        (message "Created project notes for %s — edit to add context" abbrev)
        (find-file file)))))

;;;###autoload
(defun claude-code-open-dir-todos ()
  "Open the org-roam project-TODO note for the current session directory.
If no such note exists yet, create one with a starter template.
The note body is included in every system prompt when Claude runs in this
directory, letting the agent read and update project tasks.  It is stored
in org-roam (not in the project repository) and identified by having
`claude-code-org-roam-project-todos-property' set to the expanded project path."
  (interactive)
  (unless (claude-code--org-roam-available-p)
    (user-error "org-roam is not available; install and configure it first"))
  (let* ((dir    (expand-file-name (or claude-code--cwd default-directory)))
         (abbrev (abbreviate-file-name dir))
         (title  (format "Project TODOs: %s" abbrev))
         (node   (claude-code--org-roam-find-project-todos-node dir)))
    (if node
        (org-roam-node-visit node)
      (let* ((body (concat
                    "# Per-project TODO list — included in every Claude system prompt.\n"
                    "# Use standard org TODO keywords: TODO, NEXT, DONE, CANCELLED.\n"
                    "# Empty headlines (e.g. '* TODO') are filtered out automatically.\n"
                    "# Delete these comment lines once you've added real tasks.\n"))
             (result (claude-code--org-roam-new-node-file
                      title
                      `((,claude-code-org-roam-project-todos-property . ,dir))
                      body))
             (file (car result)))
        (message "Created project TODOs for %s — add tasks here" abbrev)
        (find-file file)))))

;;;###autoload
(defun claude-code-org-roam-visit-skills-hub ()
  "Open the org-roam skills hub note, creating it if it does not exist.
The hub note is titled `claude-code-org-roam-skills-hub-title' and lists
all Claude Code skill notes as org-roam links."
  (interactive)
  (when-let ((node (claude-code--org-roam-skills-hub-node)))
    (org-roam-node-visit node)))

;;;###autoload
(defun claude-code-org-roam-add-skill (name description)
  "Create a new Claude Code skill as an org-roam note and link it to the hub.
NAME is the skill title shown in the hub index and system prompt.
DESCRIPTION is the skill body (instructions, context, etc.).

The created note has the `claude-code-org-roam-skill-property' property set
to \"t\" and the `claude-code-org-roam-skill-tag' filetag applied, making it
discoverable by `claude-code--org-roam-load-skills' at prompt-build time."
  (interactive
   (list (read-string "Skill name: ")
         (read-string "Skill description: ")))
  (unless (claude-code--org-roam-available-p)
    (user-error "org-roam is not available; install and configure it first"))
  (when (string-empty-p name)
    (user-error "Skill name must not be empty"))
  ;; Create the skill node.
  (let* ((result (claude-code--org-roam-new-node-file
                  name
                  `((,claude-code-org-roam-skill-property . "t"))
                  description))
         (skill-file (car result))
         (skill-id   (cdr result))
         (hub-node   (claude-code--org-roam-skills-hub-node)))
    ;; Append a link to the hub note.
    (with-current-buffer (find-file-noselect (org-roam-node-file hub-node))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert (format "- [[id:%s][%s]]\n" skill-id name))
      (save-buffer)
      (org-roam-db-update-file))
    (find-file skill-file)
    (message "Skill \"%s\" created and linked in the skills hub." name)))

(defun claude-code-inspect ()
  "Show session state in a temporary buffer for debugging.
Accessible via `M-x claude-code-inspect' or from emacsclient:
  emacsclient --eval \\='(claude-code-inspect)\\='"
  (interactive)
  (let ((buf (current-buffer)))
    (unless (eq major-mode 'claude-code-mode)
      ;; Try to find a Claude buffer
      (setq buf (or (seq-find (lambda (b) (with-current-buffer b
                                            (eq major-mode 'claude-code-mode)))
                              (buffer-list))
                    (user-error "No claude-code buffer found"))))
    (with-current-buffer buf
      (let* ((user-msgs (seq-filter
                         (lambda (m) (equal "user" (alist-get 'type m)))
                         claude-code--messages))
             (result-msgs (seq-filter
                           (lambda (m) (equal "result" (alist-get 'type m)))
                           claude-code--messages))
             (total-cost (apply #'+ (mapcar
                                     (lambda (m) (or (alist-get 'total_cost_usd m) 0))
                                     result-msgs)))
             (text (format "claude-code session state
══════════════════════════════════════
  buffer:     %s
  cwd:        %s
  status:     %s
  session-id: %s
  process:    %s
  messages:   %d total, %d user, %d results
  cost:       $%.4f

Last query command keys: %S
Has system prompt: %s
Has resume: %s

User prompts (newest first):
%s"
                           (buffer-name) (or claude-code--cwd default-directory) claude-code--status
                           claude-code--session-id
                           (and claude-code--process (process-status claude-code--process))
                           (length claude-code--messages) (length user-msgs) (length result-msgs)
                           total-cost
                           (when claude-code--last-query-cmd
                             (mapcar #'car claude-code--last-query-cmd))
                           (if (alist-get 'system_prompt claude-code--last-query-cmd) "yes" "no")
                           (if (alist-get 'resume claude-code--last-query-cmd) "yes" "no")
                           (mapconcat
                            (lambda (m)
                              (format "  - %s" (truncate-string-to-width
                                                (alist-get 'prompt m) 80)))
                            (seq-take user-msgs 20) "\n"))))
        (with-current-buffer (get-buffer-create "*claude-code-inspect*")
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert text))
          (goto-char (point-min))
          (special-mode)
          (pop-to-buffer (current-buffer)))))))

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

;;;; Slash Command Dispatch

(defun claude-code--dispatch-input (text)
  "Route TEXT: handle a /slash command or send as a regular Claude prompt."
  (if (string-prefix-p "/" text)
      (claude-code--run-slash-command text)
    (claude-code-send text)))

(defun claude-code--run-slash-command (text)
  "Parse and execute a slash command from TEXT."
  (let ((cmd (car (split-string (string-trim text)))))
    (pcase cmd
      ("/clear"         (call-interactively #'claude-code-clear))
      ("/model"         (call-interactively #'claude-code-set-model))
      ("/effort"        (call-interactively #'claude-code-set-effort))
      ("/notes"         (call-interactively #'claude-code-open-notes))
      ("/project-notes" (call-interactively #'claude-code-open-dir-notes))
      ("/todos"         (call-interactively #'claude-code-open-dir-todos))
      ("/inspect"       (call-interactively #'claude-code-inspect))
      ("/help"          (call-interactively #'claude-code-menu))
      (_                (message "Unknown slash command: %s  (try /help)" cmd)))))

(defun claude-code--slash-command-capf ()
  "Completion-at-point function for /slash commands in the Claude input area.
Activates when point is in the input area and the input starts with /."
  (when (claude-code--input-area-p)
    (let* ((marker-pos (marker-position claude-code--input-marker))
           (input      (buffer-substring-no-properties marker-pos (point))))
      ;; Only complete when the whole input so far is /word (no spaces yet).
      (when (string-match "\\`/\\([a-z-]*\\)\\'" input)
        (list (1+ marker-pos)          ; beg: just after the /
              (point)                  ; end
              (mapcar (lambda (entry) (substring (car entry) 1))
                      claude-code--slash-commands)
              :annotation-function
              (lambda (cand)
                (let ((full (concat "/" cand)))
                  (concat "  "
                          (or (cdr (assoc full claude-code--slash-commands))
                              ""))))
              :exit-function
              (lambda (_cand _status)
                ;; Re-insert the leading / that we stripped from the table.
                (let ((inhibit-read-only t))
                  (goto-char (marker-position claude-code--input-marker))
                  (unless (looking-at "/")
                    (insert "/"))))
              :exclusive 'no)))))

;;;; Inline Input Commands

(defun claude-code-submit-input ()
  "Submit the text currently typed in the input area.
If the agent is working, queue the message to be sent automatically when
it becomes ready — the text is left in the input area so it can be edited
or cancelled (press `c' to cancel the queue)."
  (interactive)
  (when claude-code--input-marker
    (let ((text (string-trim
                 (buffer-substring-no-properties
                  claude-code--input-marker (point-max)))))
      (unless (string-empty-p text)
        (if (eq claude-code--status 'working)
            ;; Queue: keep text in input area, show indicator in spinner.
            (progn
              (setq claude-code--input-queued text)
              (claude-code--update-thinking-overlay))
          ;; Ready: clear input area and dispatch.
          (let ((inhibit-read-only t))
            (delete-region claude-code--input-marker (point-max)))
          (claude-code--dispatch-input text))))))

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
   ("k" "Kill session" claude-code-kill)
   ("R" "Restart backend" claude-code-restart)
   ("S" "Sync Python env" claude-code-sync)]
  ["Session"
   ("m" "Set model" claude-code-set-model)
   ("e" "Set effort" claude-code-set-effort)
   ("p" "Set permission mode" claude-code-set-permission-mode)]
  ["View"
   ("t" "Toggle thinking" claude-code-toggle-thinking)
   ("T" "Toggle tool details" claude-code-toggle-tool-details)
   ("n" "Open notes file" claude-code-open-notes)
   ("a" "Agent sidebar" claude-code-agents-toggle)]
  ["Notes & Skills (org-roam)"
   ("d" "Project notes" claude-code-open-dir-notes)
   ("o" "Project TODOs" claude-code-open-dir-todos)
   ("N" "Visit skills hub" claude-code-org-roam-visit-skills-hub)
   ("A" "Add skill note" claude-code-org-roam-add-skill)])

;;;; Keymap

(defvar-keymap claude-code-mode-map
  :doc "Keymap for Claude Code mode."
  :parent magit-section-mode-map
  ;; Single-letter keys are conditional: they self-insert in the input
  ;; area and run commands elsewhere.
  "s"   #'claude-code-key-focus-input
  "r"   #'claude-code-key-send-region
  "c"   #'claude-code-key-cancel
  "C"   #'claude-code-key-clear
  "k"   #'claude-code-key-kill
  "R"   #'claude-code-key-restart
  "n"   #'claude-code-key-open-notes
  "d"   #'claude-code-key-open-dir-notes
  "o"   #'claude-code-key-open-dir-todos
  "a"   #'claude-code-key-agents-toggle
  "S"   #'claude-code-key-sync
  "?"   #'claude-code-key-menu
  "q"   #'claude-code-key-quit
  "G"   #'claude-code-key-render
  "SPC" #'claude-code-key-space
  "RET" #'claude-code-return
  "C-j" #'newline
  "DEL" #'claude-code-key-delete-backward
  "TAB" #'claude-code-key-tab)

(defun claude-code-key-delete-backward ()
  "Delete backward in input area, scroll down elsewhere."
  (interactive)
  (if (claude-code--input-area-p)
      (unless (<= (point) (marker-position claude-code--input-marker))
        (call-interactively #'backward-delete-char-untabify))
    (call-interactively #'scroll-down-command)))

(defun claude-code-key-tab ()
  "Insert tab in input area, toggle section elsewhere."
  (interactive)
  (if (claude-code--input-area-p)
      (insert "\t")
    (call-interactively #'magit-section-toggle)))

;; Override `suppress-keymap' from `special-mode': bind all printable
;; ASCII characters so they self-insert in the input area.  We skip
;; only the keys that have explicit `claude-code-key-*' wrappers.
(let ((explicit-keys (mapcar #'car
                             (seq-filter
                              (lambda (entry)
                                (and (consp entry)
                                     (symbolp (cdr entry))
                                     (string-prefix-p "claude-code-key-"
                                                      (symbol-name (cdr entry)))))
                              (cdr claude-code-mode-map)))))
  (dotimes (i 95)
    (let ((ch (+ i 32)))
      (unless (memq ch explicit-keys)
        (define-key claude-code-mode-map (char-to-string ch)
                    #'claude-code--self-insert-or-undefined)))))

;;;; Major Mode

(define-derived-mode claude-code-mode magit-section-mode "Claude"
  "Major mode for Claude Code interaction.
\\{claude-code-mode-map}"
  :group 'claude-code
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  ;; Needed by outline-minor-mode and other modes that check comment-start.
  (setq-local comment-start "# ")
  (setq-local comment-start-skip "#+\\s-*")
  ;; Allow typing in the input area at the bottom of the buffer.
  ;; magit-section-mode (via special-mode) sets buffer-read-only t; we
  ;; override that here and rely on the render function to keep the
  ;; conversation content visually stable via inhibit-read-only.
  (setq-local buffer-read-only nil)
  ;; Disable font-lock (we handle all faces via text properties).
  ;; This prevents jit-lock from crashing during redisplay when
  ;; the buffer is erased and rewritten by the render function.
  (font-lock-mode -1)
  (visual-line-mode 1)
  ;; Slash-command completion via CAPF (company picks this up automatically
  ;; via company-capf when company-mode is active in the session).
  (add-hook 'completion-at-point-functions
            #'claude-code--slash-command-capf nil t))

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
          (claude-code--agent-register
           directory
           :type 'session
           :description (abbreviate-file-name directory)
           :status 'starting
           :buffer buf
           :cwd directory
           :children nil)
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
            ;; Re-register as root agent
            (claude-code--agent-register
             dir
             :type 'session
             :description (abbreviate-file-name dir)
             :status 'starting
             :buffer buf
             :cwd dir
             :children nil)
            ;; Start a fresh backend
            (claude-code--start-process)
            (claude-code--schedule-render)))))
    (message "claude-code reloaded (%d buffer%s)"
             (length saved-states)
             (if (= 1 (length saved-states)) "" "s"))))

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
            (let ((roots (claude-code--agent-root-ids)))
              (if (null roots)
                  (insert (propertize "  No active sessions\n" 'face 'shadow))
                (dolist (root-id roots)
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
          (when (and buf (buffer-live-p buf))
            (pop-to-buffer buf)))))))

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

(provide 'claude-code)
;;; claude-code.el ends here
