;;; claude-code-diff.el --- Inline diff for Edit tool-use blocks -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Renders Edit tool-use blocks as collapsible inline unified diffs.
;; Each Edit becomes a section showing the file path and +N/-M stats.
;; Pressing TAB expands the full diff; pressing RET (or clicking [ediff])
;; opens a side-by-side ediff session in a new tab-bar tab.
;; A "✎ Modified:" summary line appears after each assistant group that
;; contained file edits.

;;; Code:

(require 'claude-code-vars)
(require 'magit-section)
(require 'diff-mode)

(declare-function claude-code--splice-heading-button "claude-code-render")

;;;; Customization

(defcustom claude-code-show-edit-diff t
  "When non-nil, render Edit tool-use blocks as inline unified diffs.
The diff block is collapsed by default; press TAB to expand it and
see the full diff.  Press RET (or click [ediff]) to open a
side-by-side ediff comparison in a new tab."
  :type 'boolean
  :group 'claude-code)

;;;; Diff Computation

(defvar claude-code--diff-cache (make-hash-table :test 'equal)
  "Memoization cache for computed diffs.
Keys are (OLD-STR . NEW-STR) cons cells; values are unified diff strings.")

(defun claude-code--diff-strings (old-str new-str)
  "Return a unified diff string comparing OLD-STR to NEW-STR.
Result is memoised in `claude-code--diff-cache'.  Returns nil when
OLD-STR equals NEW-STR or when the external `diff' binary is absent."
  (if (string= old-str new-str)
      nil
    (let ((key (cons old-str new-str)))
      (or (gethash key claude-code--diff-cache)
          (let ((result (claude-code--diff-strings--compute old-str new-str)))
            (when result
              (puthash key result claude-code--diff-cache))
            result)))))

(defun claude-code--diff-strings--compute (old-str new-str)
  "Actually run the external diff between OLD-STR and NEW-STR."
  (let ((old-file (make-temp-file "cc-edit-old"))
        (new-file (make-temp-file "cc-edit-new")))
    (unwind-protect
        (progn
          (write-region old-str nil old-file nil 'silent)
          (write-region new-str nil new-file nil 'silent)
          (with-temp-buffer
            ;; diff exits 0=identical, 1=different (normal), 2=error.
            (call-process "diff" nil t nil
                          "-u" "--label" "before" "--label" "after"
                          old-file new-file)
            (let ((s (buffer-string)))
              (unless (string-empty-p s) s))))
      (ignore-errors (delete-file old-file))
      (ignore-errors (delete-file new-file)))))

(defun claude-code--diff-count-changes (diff-str)
  "Return (ADDED . REMOVED) line counts from unified DIFF-STR."
  (let ((added 0) (removed 0))
    (dolist (line (split-string diff-str "\n"))
      (when (> (length line) 0)
        (pcase (aref line 0)
          (?+ (unless (string-prefix-p "+++" line) (cl-incf added)))
          (?- (unless (string-prefix-p "---" line) (cl-incf removed))))))
    (cons added removed)))

;;;; Diff Rendering

(defun claude-code--render-diff-string (diff-str indent)
  "Insert DIFF-STR with diff-mode syntax highlighting at INDENT columns."
  (let ((prefix (make-string indent ?\s)))
    (dolist (line (split-string diff-str "\n"))
      (unless (string-empty-p line)
        (let ((face (cond
                     ((string-prefix-p "+++" line) 'diff-file-header)
                     ((string-prefix-p "---" line) 'diff-file-header)
                     ((string-prefix-p "@@"  line) 'diff-hunk-header)
                     ((string-prefix-p "+"   line) 'diff-added)
                     ((string-prefix-p "-"   line) 'diff-removed)
                     (t                            'shadow))))
          (insert prefix (propertize line 'face face) "\n"))))))

;;;; Edit Section Rendering

(defun claude-code--render-edit-diff-section (block)
  "Render an Edit tool BLOCK as a collapsible inline diff section.

The heading shows the abbreviated file path plus +N/-M change stats.
The body (hidden by default; TAB to expand) contains the rendered
unified diff with diff-mode colours.

The magit section type is `claude-edit-diff'; its value is a plist:
  (:file-path FILE :old-string OLD :new-string NEW)
used by `claude-code-return' to launch ediff without re-parsing."
  (let* ((input      (alist-get 'input block))
         (file-path  (alist-get 'file_path input))
         (old-string (or (alist-get 'old_string input) ""))
         (new-string (or (alist-get 'new_string input) ""))
         (diff-str   (claude-code--diff-strings old-string new-string))
         (counts     (when diff-str (claude-code--diff-count-changes diff-str)))
         (added      (or (car counts) 0))
         (removed    (or (cdr counts) 0))
         (stats      (when counts
                       (concat
                        (when (> added 0)
                          (propertize (format "+%d" added) 'face 'diff-added))
                        (when (and (> added 0) (> removed 0)) " ")
                        (when (> removed 0)
                          (propertize (format "-%d" removed) 'face 'diff-removed)))))
         (section-val (list :file-path  file-path
                            :old-string old-string
                            :new-string new-string)))
    (magit-insert-section (claude-edit-diff section-val t) ; hidden=t (collapsed)
      (magit-insert-heading
        (concat "  "
                (propertize "✎ Edit" 'face 'claude-code-tool-name)
                "  "
                (let ((fp (or file-path "")))
                  (propertize (abbreviate-file-name fp)
                              'face 'claude-code-file-link))
                (when (and stats (not (string-empty-p stats)))
                  (concat "  " stats))))
      ;; [ediff] button spliced into the heading line
      (claude-code--splice-heading-button
       "[ediff]" 'claude-code-action-button
       "Open side-by-side ediff in a new tab (or press RET)"
       (let ((fp file-path) (old old-string) (new new-string))
         (lambda (_btn)
           (claude-code--open-ediff fp old new))))
      ;; Diff body — rendered when section is expanded
      (if diff-str
          (claude-code--render-diff-string diff-str 4)
        (insert (propertize "    (no changes)\n" 'face 'shadow))))))

;;;; Write Section Rendering

(defun claude-code--render-write-diff-section (block)
  "Render a Write tool BLOCK as a collapsible file-content section.
Write creates or overwrites files; we show the new content since we
do not have the previous version.  Section type is `claude-edit-diff'
so RET opens the file."
  (let* ((input     (alist-get 'input block))
         (file-path (alist-get 'file_path input))
         (file-text (or (alist-get 'file_text input) ""))
         (lines     (length (split-string file-text "\n")))
         (section-val (list :file-path  file-path
                            :old-string nil
                            :new-string file-text)))
    (magit-insert-section (claude-edit-diff section-val t)
      (magit-insert-heading
        (concat "  "
                (propertize "✎ Write" 'face 'claude-code-tool-name)
                "  "
                (propertize (abbreviate-file-name (or file-path ""))
                            'face 'claude-code-file-link)
                "  "
                (propertize (format "%d lines" lines) 'face 'shadow)))
      ;; [open] button to open the file
      (when file-path
        (claude-code--splice-heading-button
         "[open]" 'claude-code-action-button
         "Open this file"
         (let ((fp file-path))
           (lambda (_btn) (find-file fp)))))
      ;; Show new file content
      (dolist (line (split-string file-text "\n"))
        (insert (make-string 4 ?\s)
                (propertize line 'face 'shadow)
                "\n")))))

;;;; Ediff Integration

(defun claude-code--open-ediff (file-path old-string new-string)
  "Open a side-by-side ediff for FILE-PATH comparing OLD-STRING to NEW-STRING.

If OLD-STRING is nil (e.g. for Write tool), opens the file at FILE-PATH
in a read-only buffer for viewing instead of ediff.

Opens in a new `tab-bar' tab when `tab-bar-mode' is active.  Pressing
`q' in the ediff control buffer quits ediff and closes the tab."
  (if (null old-string)
      ;; Write tool: just open the file
      (when file-path (find-file file-path))
    ;; Edit tool: proper ediff comparison
    (require 'ediff)
    (let* ((base    (file-name-nondirectory (or file-path "edit")))
           (old-buf (generate-new-buffer (format "*cc-before:%s*" base)))
           (new-buf (generate-new-buffer (format "*cc-after:%s*"  base))))
      ;; Populate buffers with syntax highlighting from the file's major mode.
      (dolist (pair `((,old-buf . ,old-string) (,new-buf . ,new-string)))
        (with-current-buffer (car pair)
          (insert (cdr pair))
          (goto-char (point-min))
          (when file-path
            (ignore-errors
              (let ((buffer-file-name file-path))
                (set-auto-mode t))))
          (read-only-mode 1)))
      ;; Open a new tab if tab-bar-mode is already on.
      (let ((use-tab (and (fboundp 'tab-bar-new-tab) tab-bar-mode)))
        (when use-tab
          (tab-bar-new-tab)
          (tab-bar-rename-tab (format "diff:%s" base)))
        ;; Start ediff; startup hook registers buffer-local quit cleanup.
        (ediff-buffers
         old-buf new-buf
         (list
          (let ((ob old-buf) (nb new-buf) (ut use-tab))
            (lambda ()
              ;; This lambda runs inside the ediff control buffer.
              (add-hook 'ediff-quit-hook
                        (lambda ()
                          (ignore-errors (kill-buffer ob))
                          (ignore-errors (kill-buffer nb))
                          (when (and ut
                                     (fboundp 'tab-bar-close-tab)
                                     (> (length (tab-bar-tabs)) 1))
                            (tab-bar-close-tab)))
                        nil t)))))))))  ; append=nil, local=t

;;;; File Modification Summary

(defun claude-code--collect-edit-files (content)
  "Return a deduplicated list of file paths from Edit/Write blocks in CONTENT.
CONTENT may be a list or vector of content blocks."
  (let ((files '()))
    (dolist (block (if (vectorp content) (append content nil) content))
      (when (equal (alist-get 'type block) "tool_use")
        (let* ((name  (alist-get 'name block))
               (input (alist-get 'input block))
               (path  (when (listp input) (alist-get 'file_path input))))
          (when (and path (member name '("Edit" "Write")))
            (push path files)))))
    (nreverse (delete-dups files))))

(defun claude-code--render-edit-summary (files)
  "Render a \"✎ Modified:\" line with clickable links for each of FILES."
  (when files
    (insert "  ")
    (insert (propertize "✎ Modified: " 'face 'shadow))
    (let ((first t))
      (dolist (file files)
        (unless first (insert (propertize "  " 'face 'shadow)))
        (setq first nil)
        (let ((fp file))
          (insert-button (abbreviate-file-name file)
                         'action      (lambda (_) (find-file fp))
                         'face        'claude-code-file-link
                         'help-echo   (format "Open %s" file)
                         'follow-link t))))
    (insert "\n")))

(provide 'claude-code-diff)
;;; claude-code-diff.el ends here
