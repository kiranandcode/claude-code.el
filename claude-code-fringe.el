;;; claude-code-fringe.el --- Fringe indicators for Claude-touched lines -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2026

;;; Commentary:
;; Mark lines in source file buffers that Claude has read, written, or
;; referenced during the session.  Uses left-fringe bitmaps (like diff-hl)
;; with different bitmap/colour per operation type.

;;; Code:

(require 'cl-lib)

;;;; Fringe Bitmaps

;; Small dot — Claude read this region
(define-fringe-bitmap 'claude-code-fringe-read
  [#b00011000
   #b00111100
   #b00111100
   #b00011000]
  nil nil 'center)

;; Filled square — Claude wrote/edited this region
(define-fringe-bitmap 'claude-code-fringe-write
  [#b01111110
   #b01111110
   #b01111110
   #b01111110
   #b01111110
   #b01111110]
  nil nil 'center)

;; Small triangle — Claude referenced this file via Bash
(define-fringe-bitmap 'claude-code-fringe-bash
  [#b01000000
   #b01100000
   #b01110000
   #b01111000
   #b01110000
   #b01100000
   #b01000000]
  nil nil 'center)

;;;; Faces

(defface claude-code-fringe-read
  '((((background dark))  :foreground "#5B6268")
    (((background light)) :foreground "#9ca0a4"))
  "Fringe indicator for lines Claude has read."
  :group 'claude-code)

(defface claude-code-fringe-write
  '((((background dark))  :foreground "#da8548")
    (((background light)) :foreground "#c0752a"))
  "Fringe indicator for lines Claude has written or edited."
  :group 'claude-code)

(defface claude-code-fringe-bash
  '((((background dark))  :foreground "#7c7c75")
    (((background light)) :foreground "#9ca0a4"))
  "Fringe indicator for lines Claude referenced via Bash."
  :group 'claude-code)

;;;; Data Store

(defvar claude-code--fringe-touches (make-hash-table :test 'equal)
  "Hash table: absolute file path → list of touch records.
Each record is a plist (:type TYPE :start-line N :end-line M)
where TYPE is `read', `write', or `bash'.")

(defvar-local claude-code--fringe-overlays nil
  "List of fringe overlays applied in this buffer.")

;;;; Recording Touches

(defun claude-code--fringe-record-touch (file-path type &optional start-line end-line)
  "Record that Claude touched FILE-PATH with operation TYPE.
TYPE is a symbol: `read', `write', or `bash'.
START-LINE and END-LINE are 1-based line numbers.
If omitted, the entire file is considered touched."
  (when (and file-path (stringp file-path))
    (let* ((path  (expand-file-name file-path))
           (touch (list :type type
                        :start-line (or start-line 1)
                        :end-line   (or end-line 999999))))
      (puthash path
               (cons touch (gethash path claude-code--fringe-touches))
               claude-code--fringe-touches)
      ;; If a buffer is visiting this file, update its fringes now.
      (when-let ((buf (find-buffer-visiting path)))
        (claude-code--fringe-apply-buffer buf)))))

(defun claude-code--fringe-record-from-tool-use (tool-name input cwd)
  "Record a fringe touch for TOOL-NAME with INPUT.
CWD is the session working directory for resolving relative paths."
  (when-let ((rel-path (claude-code--tool-use-file-path tool-name input)))
    (let* ((full-path (if (file-name-absolute-p rel-path)
                          rel-path
                        (expand-file-name rel-path (or cwd default-directory))))
           (type (pcase tool-name
                   ("Read"      'read)
                   ("Write"     'write)
                   ("Edit"      'write)
                   ("MultiEdit" 'write)
                   (_           'bash))))
      ;; Extract line range from Read tool offset/limit
      (let (start-line end-line)
        (when (equal tool-name "Read")
          (let ((offset (or (alist-get 'offset input)
                            (alist-get "offset" input nil nil #'equal)))
                (limit  (or (alist-get 'limit input)
                            (alist-get "limit" input nil nil #'equal))))
            (when offset (setq start-line (max 1 offset)))
            (when (and offset limit)
              (setq end-line (+ offset limit)))))
        ;; Extract line range from Edit tool (approximate: search for old_string)
        (when (equal tool-name "Edit")
          (let ((old-string (or (alist-get 'old_string input)
                                (alist-get "old_string" input nil nil #'equal))))
            (when (and old-string (stringp old-string))
              (when-let ((buf (find-buffer-visiting full-path)))
                (with-current-buffer buf
                  (save-excursion
                    (goto-char (point-min))
                    (when (search-forward old-string nil t)
                      (setq start-line (line-number-at-pos (match-beginning 0))
                            end-line   (line-number-at-pos (match-end 0))))))))))
        (claude-code--fringe-record-touch full-path type start-line end-line)))))

;;;; Applying Overlays

(defun claude-code--fringe-clear-buffer (&optional buf)
  "Remove all claude-code fringe overlays from BUF (default: current buffer)."
  (with-current-buffer (or buf (current-buffer))
    (mapc #'delete-overlay claude-code--fringe-overlays)
    (setq claude-code--fringe-overlays nil)))

(defun claude-code--fringe-apply-buffer (buf)
  "Apply fringe indicators to BUF based on recorded touches."
  (when (buffer-live-p buf)
    (let* ((file-path (buffer-file-name buf))
           (touches   (when file-path
                        (gethash (expand-file-name file-path)
                                 claude-code--fringe-touches))))
      (when touches
        (with-current-buffer buf
          ;; Clear existing overlays first
          (claude-code--fringe-clear-buffer)
          ;; Merge all touches into a line→type map (write > bash > read priority)
          (let ((line-types (make-hash-table :test 'eql))
                (max-line   (count-lines (point-min) (point-max))))
            (dolist (touch touches)
              (let ((type  (plist-get touch :type))
                    (start (max 1 (plist-get touch :start-line)))
                    (end   (min max-line (plist-get touch :end-line))))
                (cl-loop for line from start to end do
                         (let ((cur (gethash line line-types)))
                           ;; Priority: write > bash > read
                           (unless (eq cur 'write)
                             (unless (and (eq cur 'bash) (eq type 'read))
                               (puthash line type line-types)))))))
            ;; Create overlays
            (save-excursion
              (goto-char (point-min))
              (let ((current-line 1))
                (while (not (eobp))
                  (when-let ((type (gethash current-line line-types)))
                    (let* ((bitmap (pcase type
                                    ('read  'claude-code-fringe-read)
                                    ('write 'claude-code-fringe-write)
                                    ('bash  'claude-code-fringe-bash)))
                           (face   (pcase type
                                     ('read  'claude-code-fringe-read)
                                     ('write 'claude-code-fringe-write)
                                     ('bash  'claude-code-fringe-bash)))
                           (ov     (make-overlay (line-beginning-position)
                                                 (line-end-position))))
                      (overlay-put ov 'before-string
                                   (propertize "x" 'display
                                               `(left-fringe ,bitmap ,face)))
                      (overlay-put ov 'claude-code-fringe t)
                      (overlay-put ov 'evaporate t)
                      (push ov claude-code--fringe-overlays)))
                  (setq current-line (1+ current-line))
                  (forward-line 1))))))))))

;;;; Integration Hook

(defun claude-code--fringe-on-tool-use (event cwd)
  "Record fringe touches for all tool-use blocks in assistant EVENT.
Call this from the event handler alongside the pulse system."
  (let* ((content (alist-get 'content event))
         (blocks  (cond ((vectorp content) (append content nil))
                        ((listp   content) content))))
    (dolist (block blocks)
      (when (equal (alist-get 'type block) "tool_use")
        (claude-code--fringe-record-from-tool-use
         (alist-get 'name block)
         (alist-get 'input block)
         cwd)))))

;;;; Cleanup

(defun claude-code-fringe-clear-all ()
  "Remove all fringe indicators from all buffers and clear the touch log.
Interactive command for when you want a clean slate."
  (interactive)
  (dolist (buf (buffer-list))
    (when (buffer-local-value 'claude-code--fringe-overlays buf)
      (claude-code--fringe-clear-buffer buf)))
  (clrhash claude-code--fringe-touches)
  (message "Cleared all Claude fringe indicators"))

(provide 'claude-code-fringe)
;;; claude-code-fringe.el ends here
