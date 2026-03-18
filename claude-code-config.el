;;; claude-code-config.el --- Session configuration and org-roam integration -*- lexical-binding: t; -*-

;;; Commentary:

;; Session configuration merging (defaults → project → overrides),
;; org-roam notes/TODOs/skills loading, and system prompt assembly.

;;; Code:

(require 'claude-code-vars)

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
    ;; Always inject the Emacs buffer name so the agent can reference itself
    ;; via `emacsclient' (e.g. to read its own buffer or send keystrokes).
    (push (format "You are running inside Emacs buffer \"%s\".
To interact with your own conversation buffer via emacsclient, use that name."
                  (buffer-name))
          parts)
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
      (let ((todos-file (when-let ((node (claude-code--org-roam-find-project-todos-node
                                         claude-code--cwd)))
                          (org-roam-node-file node))))
        (push (format "The following TODO list is for the current project \
directory (%s).%s\n\n%s"
                      (abbreviate-file-name claude-code--cwd)
                      (if todos-file
                          (format "\nTo add/update TODOs, edit the file: %s\n\
Use org TODO keywords (TODO, NEXT, DONE, CANCELLED) on headlines."
                                  todos-file)
                        "")
                      dir-todos)
              parts)))
    (when-let ((skills (claude-code--org-roam-load-skills)))
      (push skills parts))
    (when parts
      (mapconcat #'identity (nreverse parts) "\n\n"))))

(provide 'claude-code-config)
;;; claude-code-config.el ends here
