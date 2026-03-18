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
(require 'claude-code-render)
(require 'magit-section)
(require 'transient)

;;;; Interactive Commands

;;;###autoload
(defun claude-code-send (prompt)
  "Send PROMPT to Claude."
  (interactive
   (list (read-string "Claude> " nil 'claude-code--prompt-history)))
  (when (string-empty-p prompt)
    (user-error "Empty prompt"))
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
                   (max_turns . ,(alist-get 'max-turns cfg)))))
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
          (setq raw-data   raw
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
  (let ((key (or claude-code--session-key claude-code--cwd)))
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
  "Hard-reset the current conversation: clear all messages and restart the backend.
Unlike `claude-code-clear', this also restarts the Python process so you get a
truly blank slate.  Prompts for confirmation since the operation is irreversible."
  (interactive)
  (when (yes-or-no-p "Reset conversation? All messages will be cleared and the backend restarted. ")
    ;; Clear subagents from registry (same as claude-code-clear).
    (when claude-code--cwd
      (when-let ((agent (gethash (or claude-code--session-key claude-code--cwd)
                                 claude-code--agents)))
        (dolist (child-id (plist-get agent :children))
          (remhash child-id claude-code--agents))
        (puthash (or claude-code--session-key claude-code--cwd)
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
      (with-current-buffer buf
        (claude-code-mode)
        (setq claude-code--cwd        cwd
              claude-code--session-id nil        ; fresh backend session
              claude-code--session-key agent-key
              claude-code--messages   forked-msgs)
        (claude-code--agent-register
         agent-key
         :type 'session
         :description (format "%s (fork)" (abbreviate-file-name cwd))
         :status 'starting
         :buffer buf
         :cwd cwd
         :children nil)
        (claude-code--start-process)
        (claude-code--schedule-render))
      (pop-to-buffer buf)
      (message "Forked at: %s"
               (truncate-string-to-width
                (alist-get 'prompt target-msg) 60)))))

(defun claude-code--fork-at-msg (msg)
  "Fork the conversation at MSG without requiring point on a section.
This is the action used by the [fork] button rendered next to each user
message; it shares the same branching logic as `claude-code-fork' but
accepts the target message alist directly."
  (let* ((pos          (cl-position msg claude-code--messages :test #'eq))
         ;; claude-code--messages is newest-first; nthcdr gives target + older.
         (forked-msgs  (copy-sequence (nthcdr pos claude-code--messages)))
         (cwd          (or claude-code--cwd default-directory))
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
       :description (format "%s (fork)" (abbreviate-file-name cwd))
       :status 'starting
       :buffer buf
       :cwd cwd
       :children nil)
      (claude-code--start-process)
      (claude-code--schedule-render))
    (pop-to-buffer buf)
    (message "Forked at: %s"
             (truncate-string-to-width
              (alist-get 'prompt msg) 60))))

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
      ("/reset"         (call-interactively #'claude-code-reset))
      ("/new"           (call-interactively #'claude-code-new-session))
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
  "n"   #'claude-code-key-open-notes
  "d"   #'claude-code-key-open-dir-notes
  "o"   #'claude-code-key-open-dir-todos
  "a"   #'claude-code-key-agents-toggle
  "S"   #'claude-code-key-sync
  "?"   #'claude-code-key-menu
  "q"   #'claude-code-key-quit
  "G"   #'claude-code-key-render
  "SPC"   #'claude-code-key-space
  "S-SPC" #'claude-code-key-shift-space
  "RET" #'claude-code-return
  "C-j" #'newline
  "DEL" #'claude-code-key-delete-backward
  "TAB" #'claude-code-key-tab
  "M-p" #'claude-code-previous-input
  "M-n" #'claude-code-next-input
  "C-c i" #'claude-code-attach-image)

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
            #'claude-code--slash-command-capf nil t)
  ;; Unregister the agent automatically when the buffer is killed via any
  ;; path (C-x k, kill-buffer, etc.) — not just via `claude-code-kill'.
  (add-hook 'kill-buffer-hook
            #'claude-code--agent-unregister-self nil t))

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
                       (or claude-code--session-key claude-code--cwd)))
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
    (makunbound 'claude-code-mode-map)
    (makunbound 'claude-code-agents-mode-map)
    (dolist (subfile '("claude-code-vars" "claude-code-agents" "claude-code-process"
                       "claude-code-config" "claude-code-events" "claude-code-render"
                       "claude-code-commands" "claude-code-git-graph"))
      (load (expand-file-name (concat subfile ".el") claude-code--package-dir) nil t))
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
