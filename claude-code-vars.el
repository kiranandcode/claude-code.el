;;; claude-code-vars.el --- Internal variables for claude-code.el -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2026

;;; Commentary:
;; Internal variables, faces, and customizations for claude-code.

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
  permission-mode  - \"default\", \"plan\", \"acceptEdits\",
                     \"bypassPermissions\", \"askConfirmation\"
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

;;;; Permission Confirmation Mode

;; Per-session "don't ask again" patterns.  Each entry is a plist:
;;   (:tool-name TOOL :pattern REGEXP)
;; where REGEXP is matched against the primary argument (command string
;; for Bash, file path for Edit/Write/MultiEdit, first value otherwise).
(defvar-local claude-code--permission-patterns nil
  "Session-scoped list of always-allow patterns for the ask-permission system.
Each entry is a plist (:tool-name NAME :pattern REGEXP).
When a permission_request arrives, its primary argument is matched against
every pattern whose :tool-name equals the tool.  A match auto-approves
the call without showing the approval widget.
Manage with `claude-code-edit-permission-rules'.")

(defun claude-code--tool-input-primary-string (tool-name tool-input)
  "Return the primary matchable string from TOOL-INPUT for TOOL-NAME.
For Bash this is the command string; for file-touching tools it is the
path; for other tools it is the first value in the input map.
Returns nil when TOOL-INPUT is absent or null.
Used for permission-pattern matching and pre-filling always-allow prompts."
  (when (and tool-input (not (eq tool-input :null)))
    (let ((input (cond
                  ((listp tool-input) tool-input)
                  ((hash-table-p tool-input)
                   (let (pairs)
                     (maphash (lambda (k v) (push (cons k v) pairs)) tool-input)
                     pairs)))))
      (pcase tool-name
        ("Bash"
         (format "%s"
                 (or (alist-get 'command input)
                     (alist-get "command" input nil nil #'equal)
                     "")))
        ((or "Write" "Edit" "MultiEdit")
         (format "%s"
                 (or (alist-get 'path input)
                     (alist-get "path" input nil nil #'equal)
                     "")))
        (_
         (when-let ((pair (car input)))
           (format "%s" (cdr pair))))))))

;; The currently pending permission request (or nil).
;; Set when a `permission_request' event arrives; cleared when the user
;; responds or when the status transitions away from `working'.
(defvar-local claude-code--pending-permission nil
  "Pending permission request from the backend, or nil.
When non-nil this is an alist from `json-parse-string' with keys:
  type       = \"permission_request\"
  request_id = unique string
  tool_name  = e.g. \"Bash\", \"Read\", \"Edit\"
  tool_input = alist of tool arguments (may be nil)
  description= short human-readable description (may be nil)")

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

(defface claude-code-mcp-tool-name
  '((t :inherit font-lock-builtin-face :weight bold))
  "Tool names for Emacs-native MCP tools (EvalEmacs, EmacsRenderFrame, etc.).
Rendered with a distinct colour and an [Emacs] badge to distinguish them
from regular built-in tools (Read, Write, Bash, …)."
  :group 'claude-code)

(defface claude-code-mcp-badge
  '((t :inherit (shadow) :height 0.85))
  "The [Emacs] badge shown after MCP tool names."
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

(defface claude-code-action-button
  '((t :inherit button))
  "Clickable action buttons (Reset, New Session, Fork) in the Claude buffer."
  :group 'claude-code)

(defface claude-code-config-button
  '((t :inherit (font-lock-variable-name-face button) :underline nil))
  "Clickable config value buttons (model, effort, permission mode) in the header."
  :group 'claude-code)

(defface claude-code-permission-prompt
  '((t :inherit warning :weight bold))
  "Face for the tool-approval prompt header."
  :group 'claude-code)

(defface claude-code-permission-allow
  '((t :inherit success :weight bold))
  "Face for Allow / Always-Allow buttons in the tool-approval prompt."
  :group 'claude-code)

(defface claude-code-permission-deny
  '((t :inherit error :weight bold))
  "Face for Deny buttons in the tool-approval prompt."
  :group 'claude-code)

;;;; Permission Confirmation Faces

(defface claude-code-confirm-heading
  '((t :inherit warning :weight bold))
  "Heading line of the permission confirmation widget."
  :group 'claude-code)

(defface claude-code-confirm-tool
  '((t :inherit font-lock-type-face :weight bold))
  "Tool name in the permission confirmation widget."
  :group 'claude-code)

(defface claude-code-confirm-command
  '((t :inherit font-lock-string-face))
  "Command/input text in the permission confirmation widget."
  :group 'claude-code)

(defface claude-code-confirm-description
  '((t :inherit font-lock-comment-face :slant italic))
  "Description text in the permission confirmation widget."
  :group 'claude-code)

(defface claude-code-confirm-option-selected
  '((t :inherit success :weight bold))
  "The highlighted (cursor) option in the confirmation widget."
  :group 'claude-code)

(defface claude-code-confirm-option
  '((t :inherit shadow))
  "Non-selected option in the confirmation widget."
  :group 'claude-code)

(defface claude-code-confirm-separator
  '((t :inherit claude-code-separator))
  "Separator lines around the confirmation widget."
  :group 'claude-code)

;;;; Internal State

(defvar claude-code--package-dir nil
  "Directory containing the claude-code package source files.")
;; Always recompute with a bare setq — defvar is a no-op when the variable is
;; already bound, so it would never update after a first load.  Using setq
;; here ensures every claude-code-reload recomputes the correct directory.
;; We resolve through the claude-code.el symlink that straight.el creates back
;; to the real source tree, so reload always finds every subfile even when
;; straight has only copied a subset of files into its build cache.
(setq claude-code--package-dir
      (let* ((dir (file-name-directory
                   (or load-file-name buffer-file-name default-directory)))
             (main (expand-file-name "claude-code.el" dir)))
        (if (file-symlink-p main)
            (file-name-directory (file-truename main))
          dir)))

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

(defcustom claude-code-inline-image-max-width 480
  "Maximum pixel width for images displayed inline in the conversation.
Applies to both pending-image chips in the input area and images in
past conversation turns.  Set to nil to disable inline display entirely
even in GUI Emacs (images will show as text chips instead)."
  :type '(choice integer (const nil))
  :group 'claude-code)

(defvar-local claude-code--pending-images nil
  "List of images queued for the next prompt.
Each element is a plist with keys:
  :data       - base64-encoded string (used when building JSON for the backend)
  :raw-data   - unibyte string of raw image bytes (used for inline display)
  :media-type - MIME type string e.g. \"image/png\"
  :name       - display name string e.g. \"screenshot.png\"
Cleared after each send.")

(defvar-local claude-code--session-key nil
  "Key used to register this session in `claude-code--agents'.
For primary sessions this equals `claude-code--cwd'; for secondary or
forked sessions it is a unique string so the primary entry is not clobbered.")

(defsubst claude-code--effective-session-key ()
  "Return the agent-registry key for the current session.
Uses `claude-code--session-key' when set (fork / new-session buffers),
falling back to `claude-code--cwd' for primary sessions."
  (or claude-code--session-key claude-code--cwd))

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

(defvar claude-code--prompt-history nil
  "History for Claude prompts.")

(defconst claude-code--thinking-frames
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Frames for the thinking spinner.")

;;;; Slash Commands

(defconst claude-code--slash-commands
  '(("/clear"         . "Clear the conversation history")
    ("/reset"         . "Hard-reset: clear messages and restart the backend")
    ("/new"           . "Open a new independent session for this directory")
    ("/model"         . "Set the model for this session")
    ("/effort"        . "Set the thinking effort level")
    ("/notes"         . "Open the global notes file")
    ("/project-notes" . "Open or create project context notes")
    ("/todos"         . "Open or create project TODO list")
    ("/rules"         . "View/edit session permission rules")
    ("/inspect"       . "Show session state")
    ("/stats"         . "Show token/cost usage statistics")
    ("/help"          . "Show the command menu"))
  "Slash commands available in the Claude input area.")

;;;; Queuing & Stats State

(defvar-local claude-code--input-queued nil
  "List of input strings queued to send, oldest first.
Each entry is dispatched in FIFO order as the agent becomes ready.")

(defvar-local claude-code--pending-input nil
  "Input text to restore into the input area on the next render.
Used by `claude-code-reload' to survive the mode reinitialization.")

(defvar-local claude-code--input-history nil
  "List of previously submitted inputs in this session, most recent first.")

(defvar-local claude-code--input-history-index -1
  "Index into `claude-code--input-history' during history navigation.
-1 means not currently navigating (fresh input).")

(defvar-local claude-code--input-history-saved nil
  "Text saved before history navigation began; restored when cycling past the end.")

(defvar-local claude-code--queue-edit-index nil
  "Non-nil while navigating the queue with M-p/M-n.
An integer index into `claude-code--input-queued'; edits to the input area
are written back to that slot before moving to the next.")

(defvar-local claude-code--query-start-time nil
  "Float time when the current query started (set when status → working).")

(defvar-local claude-code--thinking-block-start-time nil
  "Float time when the current thinking block started streaming, or nil.")

(defvar-local claude-code--thinking-elapsed-sec 0.0
  "Accumulated completed-thinking-block time in seconds for the current query.")

(defvar-local claude-code--streaming-char-count 0
  "Total characters received from text/thinking deltas this query.
Used as a rough token-count approximation in the thinking spinner.")

;;;; Tool-Call Permission State

(defcustom claude-code-ask-permission-tools
  '("Bash" "Write" "Edit" "MultiEdit")
  "Tool names for which Emacs should prompt for approval before execution.
Each tool call for a listed tool will pause and show an inline approval
widget before Claude can proceed.  Set to nil to never prompt (equivalent
to `bypassPermissions' behaviour).

Note: this only takes effect when `permission-mode' is not
\"bypassPermissions\".  With bypassPermissions the SDK skips all permission
checks; the Emacs-side ask-permission feature overrides this to \"default\"
for the listed tools automatically."
  :type '(repeat string)
  :group 'claude-code)

(defvar-local claude-code--pending-permission nil
  "Alist describing the current pending permission request, or nil.
Keys: request-id, tool-name, tool-input.
Present between receipt of a `permission_request' event and the user's
response; cleared after the user approves or denies.")

(defvar-local claude-code--always-allowed-tools nil
  "List of tool names always-allowed in this session (Emacs-side mirror).
Used to display an indicator in the header.  The Python backend maintains
its own set which governs actual enforcement.")

(defvar-local claude-code--ask-permission-override 'unset
  "Buffer-local on/off override for the ask-permission feature.
`unset' means follow the global `claude-code-ask-permission-tools':
  non-nil list → on; nil list → off.
`t'   forces the feature ON for this session.
`nil' forces the feature OFF for this session.")

;;;; Emacs-Native Subagent State

(defcustom claude-code-enable-native-subagents t
  "When non-nil, include the Emacs-native subagent spawning protocol in the
system prompt.  Claude can then delegate subtasks via `emacsclient' calls
that create full session buffers visible in the *Claude Agents* sidebar,
instead of relying on the opaque CLI sidechain mechanism."
  :type 'boolean
  :group 'claude-code)

(defvar-local claude-code--subagent-task-id nil
  "Task ID if this session was spawned via `claude-code--spawn-subagent'.
Nil for normal (non-subagent) sessions.")

(defvar-local claude-code--subagent-parent-key nil
  "Parent session key when this session is an Emacs-native subagent.
Used by the result-event handler to fire completion notifications back to
the parent session.")

(defvar-local claude-code--subagent-has-worked nil
  "Non-nil once this subagent session has transitioned through `working'.
Guards the completion notification so it only fires after the first real
turn, not on the initial startup `ready' event.")

(provide 'claude-code-vars)
;;; claude-code-vars.el ends here
