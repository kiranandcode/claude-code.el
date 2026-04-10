;;; claude-code-commands.el --- Interactive commands and major mode for claude-code.el -*- lexical-binding: t; -*-

;;; Commentary:

;; All user-facing interactive commands, input handling, slash commands,
;; session config setters, the transient menu, keymap, major mode
;; definition, and the main entry points.

;;; Code:

(require 'claude-code-vars)
(require 'claude-code-agents)
(require 'claude-code-process)
(require 'claude-code-config)
(require 'claude-code-events)

(declare-function org-roam-node-file "ext:org-roam")
(declare-function org-roam-node-visit "ext:org-roam")
(declare-function org-roam-db-update-file "ext:org-roam")
(require 'claude-code-render)
(require 'claude-code-export)
;; IMPORTANT: claude-code-emacs-tools and claude-code-frame-render must be
;; required here, NOT only from the top-level claude-code.el.  The user-
;; facing entry point `claude-code' is autoloaded, which means starting a
;; session via `M-x claude-code' loads this file (claude-code-commands.el)
;; via the autoload but does NOT load the top-level claude-code.el.  Without
;; these requires, `claude-code-tools-eval' and friends would be undefined
;; when the Python backend tries to call them through emacsclient or the
;; MCP socket — every MCP tool call would fail with "Symbol's function
;; definition is void: claude-code-tools-eval" until the user explicitly
;; ran `M-x claude-code-reload'.
(require 'claude-code-emacs-tools)
(require 'claude-code-frame-render)
(require 'magit-section)
(require 'transient)

;; org-roam is optional; declare its symbols to suppress byte-compiler warnings.
(declare-function org-roam-node-file "org-roam-node")
(declare-function org-roam-node-visit "org-roam")
(declare-function org-roam-db-update-file "org-roam-db")

;;;; Interactive Commands

;;;###autoload
(defun claude-code--collect-eval-results ()
  "Collect unsent eval-result messages and format them as context.
Replaces each collected eval-result message with an eval-result-sent
message so it is only included once.
Returns a string to prepend to the next prompt, or nil."
  (let (results)
    (setq claude-code--messages
          (mapcar (lambda (msg)
                    (if (equal (alist-get 'type msg) "eval-result")
                        (progn (push msg results)
                               ;; Replace with sent variant
                               (cons (cons 'type "eval-result-sent")
                                     (cdr msg)))
                      msg))
                  claude-code--messages))
    (when results
      (mapconcat
       (lambda (msg)
         (format "[Eval result for `%s`]: %s%s"
                 (truncate-string-to-width (alist-get 'code msg) 60)
                 (if (alist-get 'errorp msg) "ERROR: " "")
                 (alist-get 'value msg)))
       results "\n"))))

(defun claude-code-send (prompt)
  "Send PROMPT to Claude.
Any @file-path tokens in PROMPT are expanded to fenced code blocks containing
the file's contents before the message is dispatched.  Unsent inline eval
results are automatically prepended as context."
  (interactive
   (list (read-string "Claude> " nil 'claude-code--prompt-history)))
  (when (string-empty-p prompt)
    (user-error "Empty prompt"))
  ;; Expand @-mentions before dispatching so Claude sees the actual content.
  (setq prompt (claude-code--expand-at-mentions prompt))
  ;; Prepend any inline eval results from code blocks the user evaluated.
  (when-let ((eval-ctx (claude-code--collect-eval-results)))
    (setq prompt (concat eval-ctx "\n\n" prompt)))
  (let* ((cwd    (or claude-code--cwd default-directory))
         (cfg    (claude-code--session-config))
         ;; Capture and clear pending images atomically before any async work.
         (images (prog1 claude-code--pending-images
                   (setq claude-code--pending-images nil)))
         (cmd    `((type . "query")
                   (prompt . ,prompt)
                   (cwd . ,cwd)
                   (allowed_tools . ,(vconcat (alist-get 'allowed-tools cfg)))
                   (permission_mode . ,(alist-get 'permission-mode cfg))
                   (max_turns . ,(alist-get 'max-turns cfg))
                   ,@(when (claude-code--ask-permission-active-p)
                       `((ask_permission_tools
                          . ,(vconcat claude-code-ask-permission-tools)))))))
    ;; Record in local message history (images stored for inline rendering).
    (push `((type . "user") (prompt . ,prompt) (images . ,images))
          claude-code--messages)
    (when claude-code--cwd
      (claude-code--agent-update
       claude-code--cwd
       :description (truncate-string-to-width prompt 60)))
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
    ;; Attach pending images as base64 content blocks (only :data, not :raw-data).
    (when images
      (push `(images . ,(vconcat
                         (mapcar (lambda (img)
                                   `((data       . ,(plist-get img :data))
                                     (media_type . ,(plist-get img :media-type))
                                     (name       . ,(plist-get img :name))))
                                 images)))
            cmd))
    ;; Resume the existing session so Claude retains conversation history.
    (when claude-code--session-id
      (push `(resume . ,claude-code--session-id) cmd))
    (setq claude-code--last-query-cmd cmd)
    (claude-code--send-json cmd))
  (claude-code--schedule-render))

(defun claude-code--image-media-type (filename-or-data)
  "Guess image media type from FILENAME-OR-DATA (a filename string)."
  (let ((ext (downcase (or (file-name-extension filename-or-data) ""))))
    (pcase ext
      ("jpg"  "image/jpeg")
      ("jpeg" "image/jpeg")
      ("png"  "image/png")
      ("gif"  "image/gif")
      ("webp" "image/webp")
      (_      "image/png"))))

(defun claude-code-attach-image (source)
  "Attach an image to the next prompt.
With prefix arg (or when clipboard has no image), prompts for a file.
Otherwise tries the clipboard first.

SOURCE is either a file path string or the symbol `clipboard'."
  (interactive
   (list (if (or current-prefix-arg
                 (null (ignore-errors
                         (gui-get-selection 'CLIPBOARD 'image/png))))
             (read-file-name "Attach image: " nil nil t)
           'clipboard)))
  (let (raw-data media-type name)
    (if (eq source 'clipboard)
        (let ((raw (gui-get-selection 'CLIPBOARD 'image/png)))
          (unless raw
            (user-error "No image found on clipboard"))
          ;; `gui-get-selection' on macOS NS sometimes returns a string
          ;; with the multibyte flag set even though the bytes themselves
          ;; are raw image data.  `base64-encode-string' refuses multibyte
          ;; input ("multibyte character in data"), so force-coerce to
          ;; unibyte first.  `string-make-unibyte' is the right tool here:
          ;; it preserves the byte representation regardless of the source
          ;; multibyte flag.
          (setq raw-data   (string-make-unibyte raw)
                media-type "image/png"
                name       "clipboard.png"))
      ;; File path
      (unless (file-readable-p source)
        (user-error "Cannot read file: %s" source))
      (setq media-type (claude-code--image-media-type source)
            name       (file-name-nondirectory source)
            raw-data   (with-temp-buffer
                         (set-buffer-multibyte nil)
                         (insert-file-contents-literally source)
                         (buffer-string))))
    ;; Store both raw bytes (for inline display) and base64 (for JSON).
    (push (list :raw-data   raw-data
                :data       (base64-encode-string raw-data t)
                :media-type media-type
                :name       name)
          claude-code--pending-images)
    (message "Attached image: %s (%s)" name media-type)
    (claude-code--schedule-render)))

(defun claude-code--image-file-p (filename)
  "Return non-nil if FILENAME has a recognized image extension."
  (let ((ext (downcase (or (file-name-extension filename) ""))))
    (member ext '("png" "jpg" "jpeg" "gif" "webp"))))

(defun claude-code--dnd-handle-drop (event)
  "Handle a drag-n-drop EVENT in a Claude buffer.
Image files are attached to the next prompt; non-image files fall
through to the default handler (`ns-drag-n-drop' on macOS,
`dnd-handle-one-url' elsewhere)."
  (interactive "e")
  (let* ((data  (caddr event))            ; (TYPE OPERATIONS . OBJECTS)
         (type  (car data))
         (objects (cddr data))
         (handled nil))
    ;; Try to attach any image files from the drop
    (dolist (obj objects)
      (let ((file (cond
                   ;; macOS NS: type is 'file and obj is a bare path
                   ((and (eq type 'file) (stringp obj) (file-name-absolute-p obj))
                    obj)
                   ;; X11/GTK: obj is a file: URI
                   ((and (stringp obj) (string-match "\\`file:" obj))
                    (or (dnd-get-local-file-name obj t) obj))
                   (t nil))))
        (when (and file (file-readable-p file) (claude-code--image-file-p file))
          (claude-code-attach-image file)
          (setq handled t))))
    ;; If we didn't handle everything as images, let the default handler
    ;; deal with non-image files.
    (unless handled
      (if (fboundp 'ns-drag-n-drop)
          (ns-drag-n-drop event)
        ;; Generic fallback for X11/GTK
        (dolist (obj objects)
          (dnd-handle-one-url (selected-window) 'private
                              (if (eq type 'file)
                                  (concat "file:" obj)
                                obj)))))))

(defvar-local claude-code--last-yanked-image-hash nil
  "MD5 of the last clipboard image already attached via yank-or-paste.
Prevents the same image from being re-attached on every subsequent yank
when the user wants to yank text after pasting an image.")

(defun claude-code-yank-or-paste-image ()
  "Yank text, or if the clipboard contains a NEW image, attach it.
In the input area: if the clipboard contains an image we have not yet
attached this session, attach it.  Otherwise fall through to the normal
`yank' command.  Tracking the image's MD5 prevents re-attaching the same
image every time the user yanks text after pasting an image."
  (interactive)
  (let* ((clip-image (and (claude-code--input-area-p)
                          (ignore-errors
                            (gui-get-selection 'CLIPBOARD 'image/png))))
         (clip-hash  (and clip-image
                          (md5 (string-make-unibyte clip-image)))))
    (cond
     ;; New image on clipboard — attach it once.
     ((and clip-hash
           (not (equal clip-hash claude-code--last-yanked-image-hash)))
      (setq claude-code--last-yanked-image-hash clip-hash)
      (claude-code-attach-image 'clipboard))
     ;; Anything else — normal yank
     (t (yank)))))

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
  "Cancel the current query and clear all queued messages."
  (interactive)
  (claude-code--send-json '((type . "cancel")))
  (claude-code--stop-thinking)
  (setq claude-code--status 'ready
        claude-code--input-queued nil
        claude-code--queue-edit-index nil)
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
  (let ((key (claude-code--effective-session-key)))
    (when key
      (claude-code--agent-unregister key)
      ;; Only remove from the primary-session hash when this buffer owns that slot.
      (when (eq (gethash claude-code--cwd claude-code--buffers) (current-buffer))
        (remhash claude-code--cwd claude-code--buffers))))
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

(defun claude-code-reset ()
  "Hard-reset: clear all messages and restart the backend.
Unlike `claude-code-clear', this also restarts the Python process so you get a
truly blank slate.  Prompts for confirmation; the operation is irreversible."
  (interactive)
  (when (yes-or-no-p "Reset conversation? All messages will be cleared and the backend restarted. ")
    ;; Clear subagents from registry (same as claude-code-clear).
    (when claude-code--cwd
      (when-let ((agent (gethash (claude-code--effective-session-key)
                                 claude-code--agents)))
        (dolist (child-id (plist-get agent :children))
          (remhash child-id claude-code--agents))
        (puthash (claude-code--effective-session-key)
                 (plist-put agent :children nil)
                 claude-code--agents)
        (run-hooks 'claude-code-agents-update-hook)))
    (setq claude-code--messages '()
          claude-code--session-id nil
          claude-code--streaming-text ""
          claude-code--streaming-thinking ""
          claude-code--streaming-active nil)
    (claude-code--stop-process)
    (claude-code--start-process)
    (claude-code--schedule-render)
    (message "claude-code: conversation reset")))

(defun claude-code-new-session ()
  "Open a new independent Claude session for the current session's directory.
Creates a fresh buffer and backend process alongside the existing conversation,
leaving the current buffer and its history untouched."
  (interactive)
  (let* ((cwd (or claude-code--cwd default-directory))
         (base-name (claude-code--buffer-name cwd))
         ;; generate-new-buffer-name appends <2>, <3>, … to avoid collisions.
         (buf-name (generate-new-buffer-name base-name))
         ;; Use a time-based suffix so the agent key is globally unique.
         (agent-key (format "%s::%s" cwd (format-time-string "%s%N")))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (claude-code-mode)
      (setq claude-code--cwd cwd
            claude-code--session-key agent-key)
      (claude-code--agent-register
       agent-key
       :type 'session
       :description (format "%s (new)" (abbreviate-file-name cwd))
       :status 'starting
       :buffer buf
       :cwd cwd
       :children nil)
      (claude-code--start-process)
      (claude-code--schedule-render))
    (pop-to-buffer buf)))

(defun claude-code-fork ()
  "Fork the conversation at the user message at point.
Creates a new buffer pre-loaded with the conversation history up to and
including the selected user message, then starts a fresh backend process.
Point must be on a ▶ You message heading (not in the input area)."
  (interactive)
  (let* ((section (magit-current-section))
         (type    (and section (oref section type))))
    (unless (eq type 'claude-user)
      (user-error "Move point to a '▶ You' message to fork from there"))
    (let* ((target-msg   (oref section value))
           (pos          (cl-position target-msg claude-code--messages :test #'eq))
           ;; claude-code--messages is newest-first.  nthcdr pos gives the
           ;; target message plus everything older — exactly what we want.
           (forked-msgs  (copy-sequence (nthcdr pos claude-code--messages)))
           (cwd          (or claude-code--cwd default-directory))
           (base-name    (claude-code--buffer-name cwd))
           (buf-name     (generate-new-buffer-name base-name))
           (agent-key    (format "%s::%s" cwd (format-time-string "%s%N")))
           (buf          (get-buffer-create buf-name)))
      (let ((parent-key (claude-code--effective-session-key))
            (fork-label (truncate-string-to-width
                         (alist-get 'prompt target-msg) 60)))
        (with-current-buffer buf
          (claude-code-mode)
          (setq claude-code--cwd        cwd
                claude-code--session-id nil        ; fresh backend session
                claude-code--session-key agent-key
                claude-code--messages   forked-msgs)
          (claude-code--agent-register
           agent-key
           :type 'session
           :description (format "⑂ %s" fork-label)
           :status 'starting
           :buffer buf
           :parent-id parent-key
           :fork-point fork-label
           :cwd cwd
           :children nil)
          ;; Link fork as child of the parent session.
          (when parent-key
            (claude-code--agent-add-child parent-key agent-key))
          (claude-code--start-process)
          (claude-code--schedule-render))
        (pop-to-buffer buf)
        (message "Forked at: %s" fork-label)))))

(defun claude-code--fork-at-msg (msg)
  "Fork the conversation at MSG without requiring point on a section.
This is the action used by the [fork] button rendered next to each user
message; it shares the same branching logic as `claude-code-fork' but
accepts the target message alist directly."
  (let* ((pos          (cl-position msg claude-code--messages :test #'eq))
         ;; claude-code--messages is newest-first; nthcdr gives target + older.
         (forked-msgs  (copy-sequence (nthcdr pos claude-code--messages)))
         (cwd          (or claude-code--cwd default-directory))
         (parent-key   (claude-code--effective-session-key))
         (fork-label   (truncate-string-to-width
                        (alist-get 'prompt msg) 60))
         (base-name    (claude-code--buffer-name cwd))
         (buf-name     (generate-new-buffer-name base-name))
         (agent-key    (format "%s::%s" cwd (format-time-string "%s%N")))
         (buf          (get-buffer-create buf-name)))
    (with-current-buffer buf
      (claude-code-mode)
      (setq claude-code--cwd        cwd
            claude-code--session-id nil
            claude-code--session-key agent-key
            claude-code--messages   forked-msgs)
      (claude-code--agent-register
       agent-key
       :type 'session
       :description (format "⑂ %s" fork-label)
       :status 'starting
       :buffer buf
       :parent-id parent-key
       :fork-point fork-label
       :cwd cwd
       :children nil)
      ;; Link fork as child of the parent session.
      (when parent-key
        (claude-code--agent-add-child parent-key agent-key))
      (claude-code--start-process)
      (claude-code--schedule-render))
    (pop-to-buffer buf)
    (message "Forked at: %s" fork-label)))

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

;;;; Code Block Copy

(defun claude-code-copy-code-block ()
  "Copy the code block at point to the kill ring.
Reads the `claude-code-code-content' text property placed on code body
lines by `claude-code--insert-code-block'.  Signals an error when point
is not inside a code block."
  (interactive)
  (if-let ((code (get-text-property (point) 'claude-code-code-content)))
      (progn
        (kill-new code)
        (message "Copied %d chars to kill ring" (length code)))
    (user-error "No code block at point (move point into the code body)")))

(claude-code--def-key-command claude-code-key-copy-code-block
  #'claude-code-copy-code-block
  "Copy code block at point, or self-insert in input area.")

;;;; Inline Eval of Emacs Lisp Code Blocks

(defun claude-code-eval-code-block (&optional code-override)
  "Evaluate the Emacs Lisp code block at point and record the result.
The result (or error) is pushed into `claude-code--messages' as an
\"eval-result\" entry and rendered inline.  On the next turn the result
is automatically included as context for Claude.

When CODE-OVERRIDE is non-nil (e.g. called from the [eval] button),
use it directly instead of reading the text property at point."
  (interactive)
  (let* ((code (or code-override
                   (get-text-property (point) 'claude-code-code-content)))
         (lang (or (get-text-property (point) 'claude-code-code-lang) "")))
    (unless code
      (user-error "No code block at point (move point into the code body)"))
    ;; Only eval Emacs Lisp
    (unless (or code-override  ; button already validated
                (memq (claude-code--mode-for-lang lang)
                      '(emacs-lisp-mode lisp-interaction-mode)))
      (user-error "Only Emacs Lisp code blocks can be evaluated (this block is %s)"
                  (if (string-empty-p lang) "unlabelled" lang)))
    (let (value errorp)
      (condition-case err
          (setq value (prin1-to-string (eval (read (format "(progn %s)" code)) t)))
        (error
         (setq value (error-message-string err)
               errorp t)))
      ;; Record in conversation history
      (push `((type . "eval-result")
              (code . ,code)
              (value . ,value)
              (errorp . ,errorp))
            claude-code--messages)
      (claude-code--schedule-render)
      (if errorp
          (message "Eval error: %s" value)
        (message "Eval ⇒ %s" (truncate-string-to-width value 80))))))

(claude-code--def-key-command claude-code-key-eval-code-block
  #'claude-code-eval-code-block
  "Evaluate Emacs Lisp code block at point, or self-insert in input area.")

;;;; Tool-Call Permission Commands

(defun claude-code--ask-permission-active-p ()
  "Return non-nil if ask-permission is on for the current session.
Checks the buffer-local override first, then falls back to whether
`claude-code-ask-permission-tools' is non-nil."
  (pcase claude-code--ask-permission-override
    ('unset (not (null claude-code-ask-permission-tools)))
    (v      v)))

(defun claude-code-toggle-ask-permission ()
  "Toggle ask-permission on/off for the current session.
When toggled off the backend bypasses approval prompts for this session;
when toggled on it asks before running any tool in
`claude-code-ask-permission-tools'."
  (interactive)
  (setq claude-code--ask-permission-override
        (not (claude-code--ask-permission-active-p)))
  (message "claude-code: ask-permission %s"
           (if claude-code--ask-permission-override "on" "off"))
  (claude-code--schedule-render))

(defun claude-code--respond-to-permission (decision)
  "Send DECISION to the backend for the pending tool permission request.
DECISION is one of \"allow\", \"deny\", or \"always_allow\".
Clears `claude-code--pending-permission' and re-renders."
  (unless claude-code--pending-permission
    (user-error "No pending permission request"))
  (let* ((req-id    (alist-get 'request-id claude-code--pending-permission))
         (tool-name (alist-get 'tool-name  claude-code--pending-permission)))
    (when (equal decision "always_allow")
      (cl-pushnew tool-name claude-code--always-allowed-tools :test #'equal))
    (setq claude-code--pending-permission nil)
    (claude-code--send-json `((type       . "permission_response")
                              (request_id . ,req-id)
                              (decision   . ,decision)))
    (claude-code--schedule-render)))

(defun claude-code-approve-tool ()
  "Approve the pending tool call (allow once)."
  (interactive)
  (claude-code--respond-to-permission "allow"))

(defun claude-code-always-allow-tool ()
  "Approve and add a session pattern so similar calls auto-approve in future.
Prompts for a regexp in the minibuffer, pre-filled with the actual command
or path quoted as a literal regexp.  Edit to generalise — e.g. widen
`git status' to `git .*' — then RET to confirm.  C-g to cancel entirely.

The pattern is stored in `claude-code--permission-patterns' for the
lifetime of this session; manage all rules with
`claude-code-edit-permission-rules'."
  (interactive)
  (unless claude-code--pending-permission
    (user-error "No pending permission request"))
  (let* ((tool-name  (alist-get 'tool-name  claude-code--pending-permission))
         (tool-input (alist-get 'tool-input claude-code--pending-permission))
         (base-str   (or (claude-code--tool-input-primary-string tool-name tool-input) ""))
         (pattern    (read-string
                      (format "Always-allow pattern for %s (regexp, RET to accept): "
                              tool-name)
                      (regexp-quote base-str))))
    (push `(:tool-name ,tool-name :pattern ,pattern)
          claude-code--permission-patterns)
    (message "claude-code: added rule — %s ~= /%s/  (M-x claude-code-edit-permission-rules to manage)"
             tool-name pattern))
  ;; Also tell Python to always-allow for the rest of this query so
  ;; subsequent calls in the same response skip the Emacs round-trip.
  (claude-code--respond-to-permission "always_allow"))

(defun claude-code-deny-tool ()
  "Deny the pending tool call."
  (interactive)
  (claude-code--respond-to-permission "deny"))

;;;; Permission Rules Buffer

(defvar-local claude-code--rules-parent-buffer nil
  "Claude session buffer whose `claude-code--permission-patterns' is being edited.
Set when the rules-edit buffer is opened from a Claude session.")

(defvar claude-code-rules-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'claude-code-rules-apply)
    (define-key map (kbd "C-c C-k") #'claude-code-rules-discard)
    (define-key map (kbd "q")       #'claude-code-rules-discard)
    map)
  "Keymap for `claude-code-rules-mode'.")

(define-derived-mode claude-code-rules-mode text-mode "Claude-Rules"
  "Major mode for editing Claude Code session permission rules.

Each non-comment line defines one always-allow rule in the form:

  TOOL-NAME   REGEXP

TOOL-NAME is the exact tool name (e.g. Bash, Edit, Write, MultiEdit).
REGEXP is matched (via `string-match-p') against the primary argument:
  Bash       — the shell command string
  Edit/Write — the file path
  Other      — the first input value

Lines starting with # are comments.  Blank lines are ignored.

\\{claude-code-rules-mode-map}"
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (font-lock-mode -1))

(defun claude-code--rules-to-string (patterns)
  "Serialise PATTERNS list to human-readable text for the rules buffer."
  (mapconcat (lambda (pat)
               (format "%-12s %s"
                       (plist-get pat :tool-name)
                       (plist-get pat :pattern)))
             patterns
             "\n"))

(defun claude-code--string-to-rules (text)
  "Parse TEXT from the rules buffer into a `claude-code--permission-patterns' list."
  (let (result)
    (dolist (line (split-string text "\n"))
      (setq line (string-trim line))
      (unless (or (string-empty-p line) (string-prefix-p "#" line))
        (when (string-match "^\\([^ \t]+\\)[ \t]+\\(.*\\)$" line)
          (push `(:tool-name ,(match-string 1 line)
                  :pattern   ,(string-trim (match-string 2 line)))
                result))))
    (nreverse result)))

(defun claude-code-rules-apply ()
  "Apply edits in the rules buffer back to the parent Claude session.
Parses the buffer contents and updates `claude-code--permission-patterns'
in the session buffer.  Closes the rules buffer."
  (interactive)
  (unless (buffer-live-p claude-code--rules-parent-buffer)
    (user-error "Parent Claude session buffer is no longer live"))
  (let ((rules (claude-code--string-to-rules (buffer-string))))
    (with-current-buffer claude-code--rules-parent-buffer
      (setq claude-code--permission-patterns rules)
      ;; Keep the always-allowed-tools mirror in sync with the new pattern set.
      (setq claude-code--always-allowed-tools
            (seq-uniq (mapcar (lambda (p) (plist-get p :tool-name)) rules)
                      #'equal)))
    (message "claude-code: %d permission rule%s applied"
             (length rules) (if (= 1 (length rules)) "" "s")))
  (quit-window t))

(defun claude-code-rules-discard ()
  "Discard unsaved edits and close the rules buffer."
  (interactive)
  (quit-window t))

(defun claude-code-edit-permission-rules ()
  "Open a buffer to view and edit the current session's permission rules.

Rules are plain-text lines of the form:

  TOOL-NAME   REGEXP

Examples:
  Bash    git .*
  Bash    cargo (build|test|check)
  Edit    src/.*\\.el
  Read    .*

Press C-c C-c to apply changes, q or C-c C-k to discard."
  (interactive)
  (let ((parent   (current-buffer))
        (patterns claude-code--permission-patterns)
        (cwd      claude-code--cwd))
    (let ((buf (get-buffer-create
                (format "*Claude Permission Rules: %s*"
                        (or cwd "session")))))
      (pop-to-buffer buf)
      (claude-code-rules-mode)
      (setq claude-code--rules-parent-buffer parent)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "# Permission rules for %s\n" (buffer-name parent)))
        (insert "# Format: TOOL-NAME  REGEXP  (one rule per line, # = comment)\n")
        (insert "# C-c C-c to apply · q or C-c C-k to discard\n\n")
        (let ((body (claude-code--rules-to-string patterns)))
          (unless (string-empty-p body)
            (insert body)
            (insert "\n"))))
      ;; Position point on the first real rule, or at end for an empty list.
      (goto-char (point-min))
      (unless (re-search-forward "^[^#\n]" nil t)
        (goto-char (point-max))))))

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
      ("/reset"         (call-interactively #'claude-code-reset))
      ("/new"           (call-interactively #'claude-code-new-session))
      ("/model"         (call-interactively #'claude-code-set-model))
      ("/effort"        (call-interactively #'claude-code-set-effort))
      ("/notes"         (call-interactively #'claude-code-open-notes))
      ("/project-notes" (call-interactively #'claude-code-open-dir-notes))
      ("/todos"         (call-interactively #'claude-code-open-dir-todos))
      ("/rules"         (call-interactively #'claude-code-edit-permission-rules))
      ("/inspect"       (call-interactively #'claude-code-inspect))
      ("/stats"         (call-interactively #'claude-code-stats))
      ("/export"        (call-interactively #'claude-code-export))
      ("/shell"         (call-interactively #'claude-code-send-shell-output))
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

;;;; @-mention File Completion

(defun claude-code--lang-for-file (file)
  "Return a Markdown language identifier string for FILE's extension."
  (let ((ext (downcase (or (file-name-extension file) ""))))
    (pcase ext
      ("el"   "elisp")
      ("py"   "python")
      ("js"   "javascript")
      ("ts"   "typescript")
      ("tsx"  "typescript")
      ("jsx"  "javascript")
      ("rb"   "ruby")
      ("rs"   "rust")
      ("go"   "go")
      ("sh"   "bash")
      ("bash" "bash")
      ("zsh"  "bash")
      ("fish" "fish")
      ("c"    "c")
      ("h"    "c")
      ("cpp"  "cpp")
      ("cc"   "cpp")
      ("cs"   "csharp")
      ("java" "java")
      ("kt"   "kotlin")
      ("swift" "swift")
      ("html" "html")
      ("css"  "css")
      ("scss" "scss")
      ("json" "json")
      ("yaml" "yaml")
      ("yml"  "yaml")
      ("toml" "toml")
      ("md"   "markdown")
      ("org"  "org")
      ("sql"  "sql")
      ("nix"  "nix")
      ("lua"  "lua")
      ("vim"  "vim")
      (_      ""))))

(defun claude-code--expand-at-mentions (text)
  "Replace @file-path tokens in TEXT with fenced file contents.
Each @path is replaced with a Markdown fenced block containing the file's
content.  Paths are resolved relative to `claude-code--cwd'.  If the file
cannot be read, the @path token is left unchanged."
  (let ((cwd (or claude-code--cwd default-directory)))
    (replace-regexp-in-string
     "@\\([^[:space:]\n]+\\)"
     (lambda (match)
       (let* ((path-raw (match-string 1 match))
              (abs-path (expand-file-name path-raw cwd)))
         (if (file-readable-p abs-path)
             (let* ((lang (claude-code--lang-for-file abs-path))
                    (content (with-temp-buffer
                               (insert-file-contents abs-path)
                               (buffer-string))))
               (format "@%s\n```%s\n%s\n```" path-raw lang content))
           ;; File not readable — leave the token intact.
           match)))
     text
     t t)))

(defun claude-code--at-mention-capf ()
  "Completion-at-point function for @file-path mentions in the Claude input area.
Activates when point is preceded by @ followed by a partial file path."
  (when (claude-code--input-area-p)
    (let* ((end        (point))
           (line-start (save-excursion (beginning-of-line) (point)))
           ;; Limit search to within the input area.
           (input-start (marker-position claude-code--input-marker))
           (search-start (max line-start input-start))
           (before     (buffer-substring-no-properties search-start end)))
      ;; Only activate when there's a bare @ (possibly with a partial path) at
      ;; the end of what has been typed so far on this line.
      (when (string-match "@\\([^[:space:]\n]*\\)\\'" before)
        (let* ((partial   (match-string 1 before))
               (at-offset (match-beginning 0))
               ;; beg points just after the @, so completions replace the partial path.
               (path-beg  (+ search-start at-offset 1))
               (cwd       (or claude-code--cwd default-directory))
               ;; Split partial into dir portion + file name prefix.
               (dir-part  (or (file-name-directory partial) ""))
               (file-pfx  (file-name-nondirectory partial))
               (abs-dir   (expand-file-name dir-part cwd))
               (all-files (when (file-directory-p abs-dir)
                            (file-name-all-completions file-pfx abs-dir)))
               ;; Re-prepend the typed directory so completions are full rel-paths.
               (candidates (mapcar (lambda (f) (concat dir-part f)) all-files)))
          (when candidates
            (list path-beg end candidates
                  :annotation-function
                  (lambda (cand)
                    (if (string-suffix-p "/" cand) "  [dir]" "  [file]"))
                  :company-prefix-length (length partial)
                  :exclusive 'no)))))))

;;;; Shell Output Capture

(defun claude-code--shell-buffer-candidates ()
  "Return an alist of (DISPLAY-NAME . BUFFER) for shell-like buffers.
Covers `vterm-mode', `eshell-mode', `shell-mode', `term-mode',
`comint-mode' and derived modes."
  (let (result)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (derived-mode-p 'vterm-mode 'eshell-mode 'shell-mode
                              'term-mode 'comint-mode 'compilation-mode)
          (push (cons (buffer-name buf) buf) result))))
    (nreverse result)))

(defun claude-code--capture-shell-output (buf &optional max-lines)
  "Capture the last MAX-LINES lines (default 200) from shell buffer BUF."
  (let ((n (or max-lines 200)))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-max))
        (forward-line (- n))
        (buffer-substring-no-properties (point) (point-max))))))

;;;###autoload
(defun claude-code-send-shell-output (buf-name &optional lines)
  "Send the last LINES (default 200) of shell buffer BUF-NAME to Claude.
Interactively prompts for a shell buffer.  The output is prepended as
context to the next prompt, or sent immediately with a default question."
  (interactive
   (let* ((candidates (claude-code--shell-buffer-candidates)))
     (unless candidates
       (user-error "No shell/terminal buffers found"))
     (list (completing-read "Shell buffer: "
                            (mapcar #'car candidates) nil t)
           nil)))
  (let* ((buf (get-buffer buf-name))
         (output (claude-code--capture-shell-output buf lines))
         (prompt (read-string
                  "Prompt (empty = just send output): "
                  nil 'claude-code--prompt-history))
         (context (format "Output from %s:\n```\n%s\n```\n\n%s"
                          buf-name
                          (string-trim output)
                          (if (string-empty-p prompt)
                              "What do you see in this output? Any errors or issues?"
                            prompt))))
    (claude-code-send context)))

;;;; Inline Input Commands

(defun claude-code-submit-input ()
  "Submit the text currently typed in the input area.
If the agent is working, append the message to the FIFO queue and clear
the input area so a new message can be typed.  Queued messages are sent
in order as the agent becomes ready.  Press `c' to cancel the queue.

When navigating the queue with \\[claude-code-previous-input], pressing
RET updates the displayed queue slot in-place and returns to fresh
input — it does not enqueue a second copy of the message."
  (interactive)
  (when claude-code--input-marker
    (let ((text (string-trim
                 (buffer-substring-no-properties
                  claude-code--input-marker (point-max)))))
      (cond
       ;; In queue-edit mode: update the slot in-place, exit navigation.
       ;; Do NOT re-enqueue or dispatch — the edited message will be sent
       ;; in its original turn when the agent becomes ready.
       (claude-code--queue-edit-index
        (unless (string-empty-p text)
          (setf (nth claude-code--queue-edit-index claude-code--input-queued)
                text))
        (setq claude-code--queue-edit-index nil
              claude-code--input-history-index -1
              claude-code--input-history-saved nil)
        (let ((inhibit-read-only t))
          (delete-region claude-code--input-marker (point-max)))
        (claude-code--update-thinking-overlay))
       ;; Normal mode: submit as a new message.
       ((not (string-empty-p text))
        ;; Record in per-buffer history and reset navigation state.
        (push text claude-code--input-history)
        (setq claude-code--input-history-index -1
              claude-code--input-history-saved nil)
        (if (eq claude-code--status 'working)
            ;; Queue: append to FIFO list and clear input area.
            (progn
              (setq claude-code--input-queued
                    (nconc claude-code--input-queued (list text)))
              (let ((inhibit-read-only t))
                (delete-region claude-code--input-marker (point-max)))
              (claude-code--update-thinking-overlay))
          ;; Ready: clear input area and dispatch.
          (let ((inhibit-read-only t))
            (delete-region claude-code--input-marker (point-max)))
          (claude-code--dispatch-input text)))))))

(defun claude-code-focus-input ()
  "Move point to the end of the input area, ready to type."
  (interactive)
  (goto-char (point-max)))

(defun claude-code--replace-input (text)
  "Replace the contents of the input area with TEXT."
  (let ((inhibit-read-only t))
    (delete-region claude-code--input-marker (point-max))
    (insert text))
  (goto-char (point-max)))

(defun claude-code--nav-current-input ()
  "Return the current text in the input area, trimmed."
  (when claude-code--input-marker
    (string-trim
     (buffer-substring-no-properties claude-code--input-marker (point-max)))))

(defun claude-code--nav-save-queue-edit ()
  "Write the current input text back to the queue slot being navigated."
  (when (and claude-code--queue-edit-index
             claude-code--input-queued
             (< claude-code--queue-edit-index (length claude-code--input-queued)))
    (setf (nth claude-code--queue-edit-index claude-code--input-queued)
          (or (claude-code--nav-current-input) ""))))

(defun claude-code-previous-input ()
  "Replace the input area with the previous (older) input.
Navigation layers, from newest to oldest:
  fresh input → queued messages (newest first) → submitted history
Each queued slot is editable; edits are saved back to the queue slot
when you navigate away.  \\[claude-code-next-input] reverses direction."
  (interactive)
  (unless (claude-code--input-area-p)
    (goto-char (point-max)))
  (when claude-code--input-marker
    (cond
     ;; Currently navigating the queue: move to older slot or enter history.
     (claude-code--queue-edit-index
      (claude-code--nav-save-queue-edit)
      (if (> claude-code--queue-edit-index 0)
          (progn
            (setq claude-code--queue-edit-index
                  (1- claude-code--queue-edit-index))
            (claude-code--replace-input
             (nth claude-code--queue-edit-index claude-code--input-queued)))
        ;; Past oldest queued: enter history navigation.
        (setq claude-code--queue-edit-index nil)
        (let ((new-index 0))
          (when (< new-index (length claude-code--input-history))
            (setq claude-code--input-history-index new-index)
            (claude-code--replace-input
             (nth new-index claude-code--input-history))))))
     ;; In history navigation: move to older entry.
     ((>= claude-code--input-history-index 0)
      (let ((new-index (1+ claude-code--input-history-index)))
        (when (< new-index (length claude-code--input-history))
          (setq claude-code--input-history-index new-index)
          (claude-code--replace-input
           (nth new-index claude-code--input-history)))))
     ;; At fresh input: snapshot it, then enter queue or history navigation.
     (t
      (setq claude-code--input-history-saved
            (buffer-substring-no-properties
             claude-code--input-marker (point-max)))
      (if claude-code--input-queued
          ;; Enter queue at the newest (last) slot.
          (let ((last-idx (1- (length claude-code--input-queued))))
            (setq claude-code--queue-edit-index last-idx)
            (claude-code--replace-input
             (nth last-idx claude-code--input-queued)))
        ;; No queue: go straight into history.
        (when claude-code--input-history
          (setq claude-code--input-history-index 0)
          (claude-code--replace-input
           (car claude-code--input-history))))))))

(defun claude-code-next-input ()
  "Replace the input area with the next (more recent) input.
Reverses \\[claude-code-previous-input]: moves from history → queue → fresh
input.  Edits to queued slots are saved back before moving on."
  (interactive)
  (when claude-code--input-marker
    (cond
     ;; In queue navigation: move to newer slot or back to fresh input.
     (claude-code--queue-edit-index
      (claude-code--nav-save-queue-edit)
      (let ((last-idx (1- (length claude-code--input-queued))))
        (if (< claude-code--queue-edit-index last-idx)
            (progn
              (setq claude-code--queue-edit-index
                    (1+ claude-code--queue-edit-index))
              (claude-code--replace-input
               (nth claude-code--queue-edit-index claude-code--input-queued)))
          ;; Past newest queued: back to fresh input.
          (setq claude-code--queue-edit-index nil
                claude-code--input-history-index -1)
          (claude-code--replace-input
           (or claude-code--input-history-saved "")))))
     ;; In history navigation: move to newer entry or back to fresh input.
     ((>= claude-code--input-history-index 0)
      (let ((new-index (1- claude-code--input-history-index)))
        (setq claude-code--input-history-index new-index)
        (if (= new-index -1)
            (claude-code--replace-input
             (or claude-code--input-history-saved ""))
          (claude-code--replace-input
           (nth new-index claude-code--input-history))))))))

(defun claude-code-return ()
  "Submit input, open ediff for edit diffs, or toggle section.

In the input area: submit the prompt.
On a `claude-edit-diff' section: open a side-by-side ediff comparison
  in a new tab (identical to clicking the [ediff] button).
On a `claude-edit-diff' section that is a Write (no old-string): open
  the file directly.
Elsewhere: toggle the magit section at point."
  (interactive)
  (cond
   ;; Input area → submit
   ((and claude-code--input-marker
         (>= (point) (marker-position claude-code--input-marker)))
    (claude-code-submit-input))
   ;; Edit/Write diff section → open ediff (or file for Write)
   ((when-let* ((sec (magit-current-section))
                (_ (eq (oref sec type) 'claude-edit-diff))
                (val (oref sec value)))
      (claude-code--open-ediff (plist-get val :file-path)
                               (plist-get val :old-string)
                               (plist-get val :new-string))
      t))
   ;; Default → toggle section
   (t
    (call-interactively #'magit-section-toggle))))

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

(defun claude-code-save-project-config ()
  "Save the current model/effort/permission-mode as project-level defaults.
Updates `claude-code-project-config' for the session's working directory and
persists the change via `customize-save-variable'."
  (interactive)
  (let* ((dir (expand-file-name (or claude-code--cwd default-directory)))
         (cfg (claude-code--session-config))
         (project-alist (list (cons 'model           (alist-get 'model cfg))
                              (cons 'effort          (alist-get 'effort cfg))
                              (cons 'permission-mode (alist-get 'permission-mode cfg)))))
    (if-let ((entry (assoc dir claude-code-project-config)))
        (setcdr entry project-alist)
      (push (cons dir project-alist) claude-code-project-config))
    (customize-save-variable 'claude-code-project-config claude-code-project-config)
    (message "Saved project config for %s" (abbreviate-file-name dir))
    (claude-code--schedule-render)))

;;;; Transient Menu

(transient-define-prefix claude-code-menu ()
  "Claude Code command menu."
  ["Send"
   ("s" "Focus input area" claude-code-focus-input)
   ("r" "Send region" claude-code-send-region)
   ("f" "Send file context" claude-code-send-buffer-file)
   ("i" "Attach image (clipboard or file)" claude-code-attach-image)]
  ["Permission"
   :if (lambda () (not (null claude-code--pending-permission)))
   ("y" "Allow tool call" claude-code-approve-tool)
   ("Y" "Always allow tool" claude-code-always-allow-tool)
   ("n" "Deny tool call" claude-code-deny-tool)]
  ["Control"
   ("c" "Cancel" claude-code-cancel)
   ("C" "Clear conversation" claude-code-clear)
   ("W" "Reset (clear + restart)" claude-code-reset)
   ("N" "New session (same dir)" claude-code-new-session)
   ("k" "Kill session" claude-code-kill)
   ("R" "Restart backend" claude-code-restart)
   ("S" "Sync Python env" claude-code-sync)]
  ["Session"
   ("m" "Set model" claude-code-set-model)
   ("e" "Set effort" claude-code-set-effort)
   ("p" "Set permission mode" claude-code-set-permission-mode)
   ("A" "Toggle ask-permission" claude-code-toggle-ask-permission)
   ("E" "Edit permission rules" claude-code-edit-permission-rules)
   ("P" "Save as project default" claude-code-save-project-config)]
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

;;;; Context-Aware Key Commands
;;
;; These wrap interactive commands so they self-insert in the input area
;; and run their command when point is in the conversation above.

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
(claude-code--def-key-command claude-code-key-approve-tool
  #'claude-code-approve-tool "Approve pending tool call or self-insert.")
(claude-code--def-key-command claude-code-key-always-allow-tool
  #'claude-code-always-allow-tool "Always-allow pending tool or self-insert.")

(defun claude-code-key-deny-or-notes ()
  "Deny a pending tool call if one is pending; open notes otherwise.
Self-inserts in the input area."
  (interactive)
  (cond
   ((claude-code--input-area-p) (call-interactively #'self-insert-command))
   (claude-code--pending-permission (claude-code-deny-tool))
   (t (call-interactively #'claude-code-open-notes))))

(defun claude-code-key-space ()
  "Self-insert in input area, scroll up in conversation."
  (interactive)
  (if (claude-code--input-area-p)
      (call-interactively #'self-insert-command)
    (call-interactively #'scroll-up-command)))

(defun claude-code-key-shift-space ()
  "Self-insert a space in the input area, scroll down in conversation.
Prevents S-SPC from triggering scroll-down while typing."
  (interactive)
  (if (claude-code--input-area-p)
      (insert " ")
    (call-interactively #'scroll-down-command)))

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
  "n"   #'claude-code-key-deny-or-notes
  "w"   #'claude-code-key-copy-code-block
  "e"   #'claude-code-key-eval-code-block
  "d"   #'claude-code-key-open-dir-notes
  "o"   #'claude-code-key-open-dir-todos
  "a"   #'claude-code-key-agents-toggle
  "S"   #'claude-code-key-sync
  "?"   #'claude-code-key-menu
  "q"   #'claude-code-key-quit
  "G"   #'claude-code-key-render
  "y"     #'claude-code-key-approve-tool
  "Y"     #'claude-code-key-always-allow-tool
  "SPC"   #'claude-code-key-space
  "S-SPC" #'claude-code-key-shift-space
  "RET" #'claude-code-return
  "C-j" #'newline
  "DEL" #'claude-code-key-delete-backward
  "TAB" #'claude-code-key-tab
  "M-p" #'claude-code-previous-input
  "M-n" #'claude-code-next-input
  "C-c i" #'claude-code-attach-image
  "C-y"   #'claude-code-yank-or-paste-image
  "C-w" #'claude-code-kill-region-or-copy
  "<drag-n-drop>" #'claude-code--dnd-handle-drop)

(defun claude-code-kill-region-or-copy (beg end &optional yank-handler)
  "Copy or kill the region, depending on where it falls.
If the region is entirely within the editable input area (at or after
`claude-code--input-marker'), perform a normal `kill-region' so the user can
cut text they are composing.  Otherwise the region overlaps the read-only
conversation area, so fall back to `kill-ring-save' (copy without cutting)
and briefly message the user."
  (interactive "r")
  (let ((input-start (and (markerp claude-code--input-marker)
                          (marker-position claude-code--input-marker))))
    (if (and input-start (>= beg input-start))
        ;; Entirely in the editable input area — normal kill.
        (kill-region beg end yank-handler)
      ;; Overlaps read-only conversation content — copy only.
      (kill-ring-save beg end)
      (message "Conversation is read-only; copied to kill ring"))))

(defun claude-code-key-delete-backward ()
  "Delete backward in input area, scroll down elsewhere."
  (interactive)
  (if (claude-code--input-area-p)
      (unless (<= (point) (marker-position claude-code--input-marker))
        (call-interactively #'backward-delete-char-untabify))
    (call-interactively #'scroll-down-command)))

(defun claude-code-key-tab ()
  "Complete slash command in input area when applicable, insert tab otherwise.
Outside the input area, toggle the magit section at point."
  (interactive)
  (cond
   ((and (claude-code--input-area-p)
         (string-match "\\`/"
                       (buffer-substring-no-properties
                        (marker-position claude-code--input-marker)
                        (point-max))))
    (completion-at-point))
   ((claude-code--input-area-p)
    (insert "\t"))
   (t
    (call-interactively #'magit-section-toggle))))

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
  ;; Sticky header-line: always visible at top of window regardless of scroll.
  (setq-local header-line-format '(:eval (claude-code--build-header-line)))
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
  ;; Slash-command and @-mention completion via CAPF (company picks these up
  ;; automatically via company-capf when company-mode is active).
  (add-hook 'completion-at-point-functions
            #'claude-code--slash-command-capf nil t)
  (add-hook 'completion-at-point-functions
            #'claude-code--at-mention-capf nil t)
  ;; Unregister the agent automatically when the buffer is killed via any
  ;; path (C-x k, kill-buffer, etc.) — not just via `claude-code-kill'.
  (add-hook 'kill-buffer-hook
            #'claude-code--agent-unregister-self nil t)
  ;; magit-section-mode adds `magit-section--highlight-region' to
  ;; `redisplay--update-region-highlight-functions' to support multi-section
  ;; selection (e.g. staging git hunks).  In claude-code buffers the input
  ;; area is inserted outside the root magit-section, so
  ;; `magit-current-section' returns nil there.  When the user selects a
  ;; region that includes the input area, magit's hook crashes with
  ;; (wrong-type-argument … nil) inside `magit-section-siblings'.  Remove
  ;; the hook locally; normal Emacs region highlighting still works fine.
  (remove-hook 'redisplay--update-region-highlight-functions
               #'magit-section--highlight-region t)
)

;;;; Emacs-Native Subagent Spawning

;;;###autoload
(defun claude-code--spawn-subagent (parent-buf-name description prompt)
  "Spawn a new Emacs-native subagent as a child of PARENT-BUF-NAME.

Intended to be called by Claude via the Bash tool:
  emacsclient --eval \\='(claude-code--spawn-subagent PARENT DESC PROMPT)\\='

Creates a full `claude-code-mode' session buffer for the subagent, registers
it as a task child of the parent session in `claude-code--agents', pre-queues
PROMPT so the backend picks it up the moment it is ready, and returns the
TASK-ID string which emacsclient echoes back as the Bash tool result.

PARENT-BUF-NAME  buffer name of the parent Claude session (this session).
DESCRIPTION      short (3-5 word) label shown in the *Claude Agents* sidebar.
PROMPT           full task instructions sent as the subagent's first message."
  (let* ((parent-buf (or (get-buffer parent-buf-name)
                         (error "spawn-subagent: parent buffer %S not found"
                                parent-buf-name)))
         (parent-key (with-current-buffer parent-buf
                       (claude-code--effective-session-key)))
         (cwd        (with-current-buffer parent-buf claude-code--cwd))
         (task-id    (format "emacs-task-%s" (format-time-string "%s%N")))
         (buf-name   (generate-new-buffer-name
                      (format "*Claude: %s*" (abbreviate-file-name cwd))))
         (agent-buf  (get-buffer-create buf-name)))
    ;; ── Set up the subagent session buffer ───────────────────────────────
    (with-current-buffer agent-buf
      (claude-code-mode)
      (setq claude-code--cwd                  cwd
            claude-code--session-key          task-id
            claude-code--subagent-task-id     task-id
            claude-code--subagent-parent-key  parent-key
            ;; Pre-queue the prompt — the ready handler fires it automatically
            ;; the moment the backend process emits its first "ready" status.
            claude-code--input-queued         (list prompt))
      ;; Register as a child task of the parent session
      (claude-code--agent-register
       task-id
       :type        'task
       :description description
       :status      'working
       :parent-id   parent-key
       :cwd         cwd
       :buffer      agent-buf
       :children    nil)
      (claude-code--agent-add-child parent-key task-id)
      ;; Start the backend process (prompt will be sent once it's ready)
      (claude-code--start-process)
      (claude-code--schedule-render))
    ;; ── Display the subagent buffer so the user can see it ────────────────
    ;; Use display-buffer (not pop-to-buffer) so we don't steal focus from
    ;; the parent session that is still running.
    (display-buffer agent-buf '(display-buffer-pop-up-window))
    ;; ── Notify the parent session ─────────────────────────────────────────
    (with-current-buffer parent-buf
      (push `((type . "info")
              (text . ,(format "⚡ Subagent started: %s  [%s]"
                               description task-id)))
            claude-code--messages)
      (claude-code--schedule-render))
    ;; Return the task-id — emacsclient prints this as the Bash tool result
    task-id))

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
          (setq claude-code--cwd directory
                claude-code--session-key directory)
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
  (let (;; Save conversation state from every live Claude buffer
        (saved-states '()))
    (maphash (lambda (dir buf)
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   ;; If the backend process is live, keep it running through the
                   ;; reload.  The process filter/sentinel lambdas call their
                   ;; handlers by name, so reloaded elisp takes effect on future
                   ;; events automatically — no restart needed.  Killing a live
                   ;; process would interrupt any in-flight tool call (e.g. the
                   ;; agent calling reload via emacsclient from a Bash tool).
                   (let* ((working-p (and claude-code--process
                                          (process-live-p claude-code--process))))
                     (push (list :dir dir
                                 :messages claude-code--messages
                                 :session-id claude-code--session-id
                                 :session-overrides claude-code--session-overrides
                                 :streaming-text claude-code--streaming-text
                                 :streaming-thinking claude-code--streaming-thinking
                                 :streaming-active claude-code--streaming-active
                                 ;; Preserve typed input and queued/history state
                                 :input-text (if (and claude-code--input-marker
                                                      (marker-buffer claude-code--input-marker))
                                                 (buffer-substring-no-properties
                                                  claude-code--input-marker (point-max))
                                               "")
                                 :input-queued claude-code--input-queued
                                 :input-history claude-code--input-history
                                 ;; Preserve task agent children so the sidebar
                                 ;; survives the reload without losing subagents.
                                 :agent-children (when-let ((a (gethash dir claude-code--agents)))
                                                   (plist-get a :children))
                                 ;; For working sessions: keep the process reference
                                 ;; so we can restore it after mode re-activation
                                 ;; wipes buffer-locals via kill-all-local-variables.
                                 :keep-process working-p
                                 :saved-process (when working-p claude-code--process))
                           saved-states)
                     ;; Only stop the process if not actively executing a tool.
                     (unless working-p
                       (claude-code--stop-process))))))
             claude-code--buffers)
    ;; Re-evaluate all source files.  Unbind keymap variables first so that
    ;; `defvar-keymap' (which, like `defvar', skips re-initialization when the
    ;; variable is already bound) always rebuilds them from the source.
    ;; Save old values so we can restore them if loading fails partway.
    (let ((old-mode-map (and (boundp 'claude-code-mode-map) claude-code-mode-map))
          (old-agents-map (and (boundp 'claude-code-agents-mode-map) claude-code-agents-mode-map))
          ;; Auto-detect every claude-code*.el at the package root, sorted
          ;; so the entry point `claude-code.el' lands last (since `-' < `.'
          ;; in ASCII).  Excludes the test file (ERT style doesn't compile)
          ;; and the autogenerated package descriptor.
          (subfiles (sort
                     (cl-remove-if
                      (lambda (f) (member f '("claude-code-test"
                                              "claude-code-pkg")))
                      (mapcar #'file-name-base
                              (directory-files
                               claude-code--package-dir nil
                               "\\`claude-code.*\\.el\\'")))
                     #'string<)))
      (makunbound 'claude-code-mode-map)
      (makunbound 'claude-code-agents-mode-map)
      (condition-case err
          (dolist (subfile subfiles)
            (load (expand-file-name (concat subfile ".el") claude-code--package-dir) nil t))
        (error
         ;; Restore keymaps so the mode remains functional.
         (unless (boundp 'claude-code-mode-map)
           (setq claude-code-mode-map old-mode-map))
         (unless (boundp 'claude-code-agents-mode-map)
           (setq claude-code-agents-mode-map old-agents-map))
         (message "claude-code-reload: load error: %s" (error-message-string err)))))
    ;; Restore each buffer with saved state
    (dolist (state saved-states)
      (let* ((dir (plist-get state :dir))
             (buf (gethash dir claude-code--buffers)))
        (when (and buf (buffer-live-p buf))
          (with-current-buffer buf
            (cond
             ((plist-get state :keep-process)
              ;; Session has a live backend process (e.g. the agent that called
              ;; reload is mid-tool-execution).  Do NOT call (claude-code-mode)
              ;; here — that would invoke kill-all-local-variables and wipe
              ;; claude-code--process, claude-code--session-id, and all other
              ;; buffer-locals we need to preserve.  Instead just refresh the
              ;; keymap in-place so new bindings take effect.
              (use-local-map claude-code-mode-map)
              ;; Re-apply the highlight fix that claude-code-mode normally does.
              (remove-hook 'redisplay--update-region-highlight-functions
                           #'magit-section--highlight-region t)
              ;; Re-register in the agent table (status stays working).
              (claude-code--agent-register
               dir
               :type 'session
               :description (abbreviate-file-name dir)
               :status 'working
               :buffer buf
               :cwd dir
               :children (plist-get state :agent-children))
              (claude-code--schedule-render))
             (t
              ;; Idle session — full mode re-activation + fresh process.
              (claude-code-mode)
              (setq claude-code--cwd dir)
              ;; Restore conversation state (except session-id — see below)
              (setq claude-code--messages (plist-get state :messages)
                    claude-code--session-overrides (plist-get state :session-overrides)
                    claude-code--streaming-text (plist-get state :streaming-text)
                    claude-code--streaming-thinking (plist-get state :streaming-thinking)
                    claude-code--streaming-active (plist-get state :streaming-active)
                    claude-code--input-queued (plist-get state :input-queued)
                    claude-code--input-history (plist-get state :input-history))
              ;; Stash typed input so the next render restores it into the input area
              (let ((input-text (plist-get state :input-text)))
                (when (and input-text (not (string-empty-p input-text)))
                  (setq claude-code--pending-input input-text)))
              ;; Re-register as root agent, preserving task children.
              (claude-code--agent-register
               dir
               :type 'session
               :description (abbreviate-file-name dir)
               :status 'starting
               :buffer buf
               :cwd dir
               :children (plist-get state :agent-children))
              ;; Start a fresh backend, then restore the session ID so the SDK
              ;; can resume the conversation.
              (claude-code--start-process)
              (setq claude-code--session-id (plist-get state :session-id))
              (claude-code--schedule-render)))))))
    ;; Re-activate the agents sidebar mode so its local keymap stays in sync
    ;; with `claude-code-agents-mode-map'.  The buffer may hold a stale
    ;; reference to an older keymap object if the variable was ever replaced.
    (when-let ((agents-buf (get-buffer "*Claude Agents*")))
      (when (buffer-live-p agents-buf)
        (with-current-buffer agents-buf
          (claude-code-agents-mode)
          (claude-code--agents-do-render))))
    (message "claude-code reloaded (%d buffer%s)"
             (length saved-states)
             (if (= 1 (length saved-states)) "" "s"))))

(provide 'claude-code-commands)
;;; claude-code-commands.el ends here
