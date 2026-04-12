;;; claude-code-annotate.el --- Retroactive conversation annotations -*- lexical-binding: t; -*-

;;; Commentary:
;; Attach notes to earlier conversation turns — corrections, superseding
;; remarks, cross-references.  Annotations are stored in data (not buffer
;; overlays) and rendered inline during the normal render cycle.

;;; Code:

(require 'claude-code-vars)
(require 'magit-section)

;; Forward declarations
(declare-function claude-code--schedule-render "claude-code-events")

;;;; Faces

(defface claude-code-annotation
  '((((background dark))  :foreground "#e0c080" :slant italic)
    (((background light)) :foreground "#806020" :slant italic))
  "Face for annotation text in the conversation buffer."
  :group 'claude-code)

(defface claude-code-annotation-label
  '((t :inherit shadow :weight bold))
  "Face for the [note] label prefix on annotations."
  :group 'claude-code)

;;;; Storage

(defvar-local claude-code--annotations nil
  "Alist mapping message alists to their annotation lists.
Each entry is (MSG . ANNOTATIONS) where MSG is compared by `eq'
and ANNOTATIONS is a list of plists with :text and :time keys.")

(defun claude-code--annotations-for (msg)
  "Return the list of annotations for MSG, or nil."
  (alist-get msg claude-code--annotations nil nil #'eq))

(defun claude-code--annotate-msg (msg text)
  "Attach annotation TEXT to MSG and re-render."
  (let ((entry (assq msg claude-code--annotations))
        (annotation (list :text text :time (float-time))))
    (if entry
        (push annotation (cdr entry))
      (push (cons msg (list annotation)) claude-code--annotations)))
  (claude-code--schedule-render))

(defun claude-code--annotation-remove (msg annotation)
  "Remove ANNOTATION from MSG's annotation list and re-render."
  (when-let ((entry (assq msg claude-code--annotations)))
    (setcdr entry (delq annotation (cdr entry)))
    ;; Clean up empty entries
    (unless (cdr entry)
      (setq claude-code--annotations
            (assq-delete-all msg claude-code--annotations))))
  (claude-code--schedule-render))

;;;; Render

(defun claude-code--render-annotations (msg)
  "Render annotations for MSG, if any."
  (when-let ((annotations (claude-code--annotations-for msg)))
    (dolist (ann (reverse annotations))  ; oldest first
      (let* ((text (plist-get ann :text))
             (time (plist-get ann :time))
             (ago  (claude-code--relative-time time)))
        (insert (propertize "    [note] " 'face 'claude-code-annotation-label)
                (propertize text 'face 'claude-code-annotation)
                (propertize (format "  (%s)" ago) 'face 'shadow)
                "\n")))))

(defun claude-code--relative-time (time)
  "Format TIME as a relative duration string like \"2m ago\"."
  (let ((delta (- (float-time) time)))
    (cond
     ((< delta 60)    "just now")
     ((< delta 3600)  (format "%dm ago" (floor (/ delta 60))))
     ((< delta 86400) (format "%dh ago" (floor (/ delta 3600))))
     (t               (format "%dd ago" (floor (/ delta 86400)))))))

;;;; Interactive commands

(defun claude-code-annotate ()
  "Add an annotation to the message at point.
Works on ▶ You and ◀ Assistant sections."
  (interactive)
  (let ((msg (claude-code--annotation-find-msg-at-point)))
    (unless msg
      (user-error "Move point to a message to annotate"))
    (let ((text (read-string "Annotation: ")))
      (when (string-empty-p text)
        (user-error "Empty annotation"))
      (claude-code--annotate-msg msg text))))

(defun claude-code-delete-annotation ()
  "Delete an annotation from the message at point."
  (interactive)
  (let ((msg (claude-code--annotation-find-msg-at-point)))
    (unless msg
      (user-error "Move point to a message"))
    (let ((annotations (claude-code--annotations-for msg)))
      (unless annotations
        (user-error "No annotations on this message"))
      (if (= 1 (length annotations))
          ;; Only one — confirm and remove
          (when (y-or-n-p (format "Delete annotation \"%s\"? "
                                  (truncate-string-to-width
                                   (plist-get (car annotations) :text) 40)))
            (claude-code--annotation-remove msg (car annotations)))
        ;; Multiple — let user pick
        (let* ((candidates
                (mapcar (lambda (ann)
                          (cons (truncate-string-to-width
                                 (plist-get ann :text) 60)
                                ann))
                        annotations))
               (choice (completing-read "Delete annotation: "
                                        candidates nil t))
               (ann (alist-get choice candidates nil nil #'equal)))
          (when ann
            (claude-code--annotation-remove msg ann)))))))

(defun claude-code--annotation-find-msg-at-point ()
  "Find the message alist at point by walking magit-section parents.
Returns the msg alist or nil."
  (let ((section (magit-current-section)))
    (while (and section
                (not (memq (oref section type) '(claude-user claude-assistant))))
      (setq section (oref section parent)))
    (when section
      (oref section value))))

(provide 'claude-code-annotate)
;;; claude-code-annotate.el ends here
