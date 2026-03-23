;;; claude-code-render.el --- Buffer rendering for claude-code.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Renders the conversation buffer using magit-section: header, messages
;; (user/assistant/result/error/info), content blocks (text/thinking/tool-use),
;; streaming preview, and the thinking spinner animation.

;;; Code:

(require 'claude-code-vars)
(require 'claude-code-config)
(require 'claude-code-agents)
(require 'claude-code-diff)
(require 'magit-section)

(declare-function claude-code--schedule-render "claude-code-commands")
(declare-function claude-code--fork-at-msg "claude-code-commands")
(declare-function claude-code-new-session "claude-code-commands")
(declare-function claude-code-reset "claude-code-commands")
(declare-function claude-code-cancel "claude-code-commands")
(declare-function claude-code-save-project-config "claude-code-commands")
(declare-function claude-code-set-permission-mode "claude-code-commands")
(declare-function claude-code-set-effort "claude-code-commands")
(declare-function claude-code-set-model "claude-code-commands")

;;;; Image Rendering Helpers

(defun claude-code--image-type-from-media-type (media-type)
  "Return the Emacs image type symbol for MEDIA-TYPE string."
  (pcase media-type
    ("image/jpeg" 'jpeg)
    ("image/gif"  'gif)
    ("image/webp" 'webp)
    (_            'png)))

(defun claude-code--insert-image (img &optional max-width)
  "Insert IMG (a pending-image plist) inline if running in a GUI frame.
MAX-WIDTH caps the display width in pixels (default: `claude-code-inline-image-max-width').
Falls back to a text chip when not in GUI mode or image display is disabled."
  (let* ((max-w   (or max-width claude-code-inline-image-max-width))
         (raw     (plist-get img :raw-data))
         (name    (plist-get img :name))
         (mtype   (plist-get img :media-type))
         (itype   (claude-code--image-type-from-media-type mtype)))
    (if (and max-w
             raw
             (display-graphic-p)
             (image-type-available-p itype))
        (condition-case err
            (let* ((image    (create-image raw itype t :max-width max-w))
                   (size     (image-size image t))
                   (display  (propertize " " 'display image
                                         'help-echo name)))
              (insert display)
              (insert (propertize (format " %s (%dx%d)"
                                          name
                                          (car size) (cdr size))
                                  'face 'shadow)))
          (error
           (insert (propertize (format "  📎 %s [display error: %s]"
                                       name (error-message-string err))
                               'face 'claude-code-result))))
      ;; Text fallback for terminal / disabled inline display.
      (insert (propertize (format "  📎 %s" name)
                          'face 'claude-code-result)))))

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
        ;; Messages are stored newest-first; render oldest-first.
        ;; Consecutive assistant messages are grouped under one heading.
        (let ((pending-assistant nil))
          (dolist (msg (reverse claude-code--messages))
            (let ((type (alist-get 'type msg)))
              (if (equal type "assistant")
                  (push msg pending-assistant)
                (progn
                  (when pending-assistant
                    (claude-code--render-assistant-group
                     (nreverse pending-assistant))
                    (setq pending-assistant nil))
                  (claude-code--render-message msg)))))
          (when pending-assistant
            (claude-code--render-assistant-group
             (nreverse pending-assistant))))
        ;; Show in-progress streaming content
        (claude-code--render-streaming)
        ;; Pinned spawned-agents panel (below all output, above input)
        (claude-code--render-subagents-panel))
      ;; Apply invisible overlays to all sections that were inserted with
      ;; hide=t.  magit-insert-section sets the `hidden' slot but does NOT
      ;; create the overlay — that only happens when magit-section-hide is
      ;; called explicitly (normally by magit-refresh).  Since we drive
      ;; rendering ourselves we must do this walk after the tree is built.
      (when (and (boundp 'magit-root-section) magit-root-section)
        (cl-labels ((apply-hide (sec)
          (when (oref sec hidden)
            (magit-section-hide sec))
          (dolist (child (oref sec children))
            (apply-hide child))))
          (apply-hide magit-root-section)))
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
      ;; Show pending image attachment chips (inline thumbnail in GUI, text in terminal).
      (when claude-code--pending-images
        (dolist (img claude-code--pending-images)
          (insert "  ")
          (claude-code--insert-image img 200)   ; smaller thumbnail in chip
          (insert "  ")
          (insert-button "[×]"
                         'action (let ((img img))
                                   (lambda (_btn)
                                     (setq claude-code--pending-images
                                           (delete img claude-code--pending-images))
                                     (claude-code--schedule-render)))
                         'help-echo "Remove this attachment"
                         'face 'claude-code-action-button
                         'follow-link t)
          (insert "\n")))
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
    ;; Show active config as clickable buttons
    (let ((model (alist-get 'model cfg))
          (effort (alist-get 'effort cfg))
          (mode (alist-get 'permission-mode cfg)))
      (insert "  ")
      (insert (propertize "model:" 'face 'shadow))
      (insert " ")
      (insert-button (format "[%s]" (or model "default"))
                     'action (lambda (_btn)
                               (call-interactively #'claude-code-set-model))
                     'help-echo "Click to change model (or press 'm' in menu)"
                     'face 'claude-code-config-button
                     'follow-link t)
      (insert "  ")
      (insert (propertize "effort:" 'face 'shadow))
      (insert " ")
      (insert-button (format "[%s]" (or effort "none"))
                     'action (lambda (_btn)
                               (call-interactively #'claude-code-set-effort))
                     'help-echo "Click to change effort level (or press 'e' in menu)"
                     'face 'claude-code-config-button
                     'follow-link t)
      (insert "  ")
      (insert (propertize "perms:" 'face 'shadow))
      (insert " ")
      (insert-button (format "[%s]" (or mode "default"))
                     'action (lambda (_btn)
                               (call-interactively #'claude-code-set-permission-mode))
                     'help-echo "Click to change permission mode (or press 'p' in menu)"
                     'face 'claude-code-config-button
                     'follow-link t)
      (insert "  ")
      (insert-button "[↓ Save as Project Default]"
                     'action (lambda (_btn)
                               (call-interactively #'claude-code-save-project-config))
                     'help-echo "Save current model/effort/perms as project-level defaults"
                     'face 'claude-code-action-button
                     'follow-link t)
      (insert "\n"))
    (insert (propertize (make-string 70 ?─) 'face 'claude-code-separator))
    (insert "\n")
    ;; Action buttons: Cancel (when working), Reset, New Session
    (insert "  ")
    (when (eq claude-code--status 'working)
      (insert-button "[Cancel]"
                     'action (lambda (_btn) (claude-code-cancel))
                     'help-echo "Cancel the current query (key: c)"
                     'face 'claude-code-action-button
                     'follow-link t)
      (insert "  "))
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

(defun claude-code--splice-heading-button (text face help-echo action)
  "Splice a button with TEXT into the current magit section heading.
Must be called immediately after `magit-insert-heading' while point is
at the start of the section body.  Inserts TEXT at the end of the
preceding heading line (before its trailing newline) as a clickable
button with FACE, HELP-ECHO, and ACTION.  This bypasses the magit
section keymap that `magit-insert-heading' stamps onto heading text."
  (save-excursion
    (forward-line -1)
    (end-of-line)
    (insert "  ")
    (let ((btn-start (point)))
      (insert text)
      (make-text-button btn-start (point)
                        'action    action
                        'help-echo help-echo
                        'face      face
                        'follow-link t))))

(defun claude-code--render-user-msg (msg)
  "Render a user MSG."
  ;; Store MSG as the section value so `claude-code-fork' can retrieve it.
  (magit-insert-section (claude-user msg)
    (magit-insert-heading
      (propertize "▶ You" 'face 'claude-code-user-prompt))
    (claude-code--splice-heading-button
     "[fork]" 'claude-code-action-button
     "Fork conversation at this message"
     (lambda (_btn) (claude-code--fork-at-msg msg)))
    ;; Render attached images (full-width inline in GUI, text chips in terminal).
    (when-let ((images (alist-get 'images msg)))
      (dolist (img images)
        (insert "  ")
        (claude-code--insert-image img)
        (insert "\n")))
    (insert "  " (alist-get 'prompt msg) "\n\n")))

(defun claude-code--render-assistant-group (msgs)
  "Render a list of consecutive assistant MSGS under a single ◀ Assistant heading."
  (magit-insert-section (claude-assistant nil nil)
    (magit-insert-heading
      (propertize "◀ Assistant" 'face 'claude-code-assistant-label))
    (dolist (msg msgs)
      (let ((content (alist-get 'content msg)))
        ;; json-parse-string returns vectors for arrays
        (when (vectorp content)
          (setq content (append content nil)))
        (dolist (block content)
          (claude-code--render-content-block block))))
    ;; Append a "✎ Modified:" summary line for any Edit/Write tools used.
    (when claude-code-show-edit-diff
      (let ((edited-files
             (cl-loop for msg in msgs
                      for content = (alist-get 'content msg)
                      when content
                      append (claude-code--collect-edit-files content))))
        (when edited-files
          (claude-code--render-edit-summary (delete-dups edited-files)))))
    (insert "\n")))

(defun claude-code--render-assistant-msg (msg)
  "Render a single assistant MSG.  Use `claude-code--render-assistant-group' for
grouped rendering; this entry point is kept for ad-hoc use."
  (claude-code--render-assistant-group (list msg)))

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
  "Render a collapsible tool-use BLOCK.
Edit and Write tool blocks are rendered as inline diff sections (see
`claude-code-diff.el') when `claude-code-show-edit-diff' is non-nil.
Emacs-native MCP tools (EvalEmacs, EmacsRenderFrame, etc.) are rendered
with a distinct face and an [Emacs] badge so they are visually distinct
from regular built-in tools."
  (let* ((name      (alist-get 'name block))
         (input     (alist-get 'input block))
         (is-mcp    (claude-code--mcp-tool-p name))
         (disp-name (if is-mcp (claude-code--mcp-tool-short-name name) name))
         (summary   (claude-code--tool-summary name input))
         (name-face (if is-mcp 'claude-code-mcp-tool-name 'claude-code-tool-name)))
    (cond
     ;; Edit tool with diff rendering
     ((and (equal name "Edit")
           (listp input)
           claude-code-show-edit-diff)
      (claude-code--render-edit-diff-section block))
     ;; Write tool with content preview
     ((and (equal name "Write")
           (listp input)
           claude-code-show-edit-diff)
      (claude-code--render-write-diff-section block))
     ;; All other tools: default collapsible JSON view
     (t
      (magit-insert-section (claude-tool-use nil
                                             (not claude-code-show-tool-details))
        (magit-insert-heading
          (concat "  "
                  (propertize (format "⚙ %s" disp-name) 'face name-face)
                  (when is-mcp
                    (propertize " [Emacs]" 'face 'claude-code-mcp-badge))
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
          (insert "\n")))))))

(defun claude-code--tool-result-text (raw)
  "Extract a plain string from a tool-result content value RAW.
Built-in tools return a plain string; MCP tools return a vector of
{type, text} content-block objects.  Both forms are normalised here."
  (cond
   ((null raw) nil)
   ((stringp raw) raw)
   ;; MCP / list format: [{type: "text", text: "..."}, ...]
   ((or (vectorp raw) (listp raw))
    (let* ((items (if (vectorp raw) (append raw nil) raw))
           (texts (delq nil (mapcar (lambda (b) (alist-get 'text b)) items))))
      (mapconcat #'identity texts "\n")))
   (t nil)))

(defun claude-code--pop-output-buffer (content label)
  "Display CONTENT in a fresh `view-mode' buffer named after LABEL.
`q' kills the buffer; it is not left lingering in the buffer list."
  (let ((buf (generate-new-buffer (format "*Claude %s*" label))))
    (with-current-buffer buf
      (insert content)
      (goto-char (point-min))
      ;; Pass #'kill-buffer as exit-action so `q' kills rather than buries.
      (view-mode-enter nil #'kill-buffer))
    (pop-to-buffer buf)))

(defun claude-code--render-tool-result (block)
  "Render a tool result BLOCK.
Content may be a plain string (built-in tools) or a vector of
{type, text} content objects (MCP tools); both are handled via
`claude-code--tool-result-text'.  A \\='[view]\\=' button in the heading
opens the full output in a dedicated `view-mode' buffer even when the
section is collapsed."
  (let* ((raw      (alist-get 'content block))
         (is-error (alist-get 'is_error block))
         (content  (claude-code--tool-result-text raw)))
    (when (and content (not (string-empty-p content)))
      (let* ((face  (if is-error 'claude-code-error 'shadow))
             (label (if is-error "Tool error" "Tool result")))
        (magit-insert-section (claude-tool-result nil t)
          (magit-insert-heading
            (propertize (if is-error "  ✗ Tool error" "  ↳ Tool result")
                        'face face))
          (claude-code--splice-heading-button
           "[view]" 'claude-code-file-link
           (format "Open full output in *Claude %s*" label)
           (lambda (_btn) (claude-code--pop-output-buffer content label)))
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

;;;; MCP Tool Helpers

;; Names of the Emacs-native MCP tools exposed by the Python backend.
;; Keep in sync with EMACS_TOOL_NAMES in claude_code_backend.py.
(defconst claude-code--mcp-tool-names
  '("EvalEmacs"
    "EmacsRenderFrame"
    "EmacsGetMessages"
    "EmacsGetDebugInfo"
    "EmacsGetBuffer"
    "EmacsGetBufferRegion"
    "EmacsListBuffers"
    "EmacsSwitchBuffer"
    "EmacsGetPointInfo"
    "EmacsSearchForward"
    "EmacsSearchBackward"
    "EmacsGotoLine")
  "Names of Emacs-native MCP tools registered by the Python backend.")

(defun claude-code--mcp-tool-short-name (name)
  "Return the short name for tool NAME, stripping any \"mcp__emacs__\" prefix.
E.g. \"mcp__emacs__EvalEmacs\" -> \"EvalEmacs\", \"Read\" -> \"Read\"."
  (if (and name (string-prefix-p "mcp__emacs__" name))
      (substring name (length "mcp__emacs__"))
    name))

(defun claude-code--mcp-tool-p (name)
  "Return non-nil if tool NAME is an Emacs-native MCP tool.
Accepts both prefixed (\"mcp__emacs__EvalEmacs\") and bare (\"EvalEmacs\") forms."
  (and name (member (claude-code--mcp-tool-short-name name)
                    claude-code--mcp-tool-names)))

(defun claude-code--tool-summary (name input)
  "Generate a short summary for tool NAME with INPUT.
NAME may be a prefixed MCP name (\"mcp__emacs__EvalEmacs\") or bare."
  (when (listp input)
    (pcase (claude-code--mcp-tool-short-name name)
      ;; Built-in tools
      ("Read"  (alist-get 'file_path input))
      ("Write" (alist-get 'file_path input))
      ("Edit"  (alist-get 'file_path input))
      ("Bash"  (when-let ((cmd (alist-get 'command input)))
                 (truncate-string-to-width cmd 60)))
      ("Glob"  (alist-get 'pattern input))
      ("Grep"  (alist-get 'pattern input))
      ;; Emacs MCP tools
      ("EvalEmacs"
       (when-let ((code (alist-get 'code input)))
         (truncate-string-to-width
          (replace-regexp-in-string "\n" " " code) 50)))
      ("EmacsGetBuffer"       (alist-get 'buffer_name input))
      ("EmacsGetBufferRegion"
       (when-let ((buf (alist-get 'buffer_name input)))
         (format "%s:%s-%s" buf
                 (alist-get 'start_line input)
                 (alist-get 'end_line input))))
      ("EmacsSwitchBuffer"    (alist-get 'buffer_name input))
      ("EmacsSearchForward"   (alist-get 'pattern input))
      ("EmacsSearchBackward"  (alist-get 'pattern input))
      ("EmacsGotoLine"
       (when-let ((line (alist-get 'line_number input)))
         (format "line %d" line)))
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
