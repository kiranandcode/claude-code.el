;;; claude-code-git-graph.el --- Git contribution graph visualization -*- lexical-binding: t; -*-

;;; Commentary:

;; Standalone git repository visualization: 52-week contribution heatmap,
;; top contributors bar chart, and recent commits log.

;;; Code:

(require 'claude-code-vars)

;;;; Git Graph Visualization

(defface claude-code-git-heat-0
  '((((background dark)) :foreground "#2d333b")
    (t :foreground "#ebedf0"))
  "Heatmap cell: no commits."
  :group 'claude-code)

(defface claude-code-git-heat-1
  '((((background dark)) :foreground "#0e4429")
    (t :foreground "#9be9a8"))
  "Heatmap cell: low activity."
  :group 'claude-code)

(defface claude-code-git-heat-2
  '((((background dark)) :foreground "#006d32")
    (t :foreground "#40c463"))
  "Heatmap cell: medium activity."
  :group 'claude-code)

(defface claude-code-git-heat-3
  '((((background dark)) :foreground "#26a641")
    (t :foreground "#30a14e"))
  "Heatmap cell: high activity."
  :group 'claude-code)

(defface claude-code-git-heat-4
  '((((background dark)) :foreground "#39d353")
    (t :foreground "#216e39"))
  "Heatmap cell: very high activity."
  :group 'claude-code)

(defface claude-code-git-graph-header
  '((t :inherit claude-code-header))
  "Git graph section headers."
  :group 'claude-code)

(defface claude-code-git-graph-sha
  '((t :inherit font-lock-constant-face))
  "Commit SHA in git log."
  :group 'claude-code)

(defface claude-code-git-graph-author
  '((t :inherit font-lock-string-face))
  "Author name in git log."
  :group 'claude-code)

(defface claude-code-git-graph-date
  '((t :inherit shadow))
  "Commit date in git log."
  :group 'claude-code)

(defface claude-code-git-graph-ref
  '((t :inherit font-lock-keyword-face :weight bold))
  "Branch/tag refs in git log."
  :group 'claude-code)

(defun claude-code-git-graph--run (dir &rest args)
  "Run git with ARGS in DIR; return trimmed output string or nil on error."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (when (= 0 (apply #'call-process "git" nil t nil args))
        (string-trim (buffer-string))))))

(defun claude-code-git-graph--commit-dates (dir days)
  "Return hash-table date-string->count for the last DAYS days in DIR."
  (let ((since (format-time-string
                "%Y-%m-%d"
                (time-subtract (current-time) (days-to-time days))))
        (counts (make-hash-table :test #'equal)))
    (let ((raw (claude-code-git-graph--run
                dir "log" "--all" "--format=%ad" "--date=short"
                (format "--since=%s" since))))
      (when raw
        (dolist (line (split-string raw "\n" t))
          (let ((d (string-trim line)))
            (when (string-match-p "^[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}$" d)
              (puthash d (1+ (gethash d counts 0)) counts))))))
    counts))

(defun claude-code-git-graph--author-counts (dir)
  "Return alist (author . count) sorted descending for DIR."
  (let ((raw (claude-code-git-graph--run
              dir "shortlog" "-sn" "--all" "--no-merges")))
    (when raw
      (delq nil
            (mapcar (lambda (line)
                      (when (string-match "^[[:space:]]*\\([0-9]+\\)[[:space:]]+\\(.+\\)$" line)
                        (cons (match-string 2 line)
                              (string-to-number (match-string 1 line)))))
                    (split-string raw "\n" t))))))

(defun claude-code-git-graph--recent-commits (dir n)
  "Return list of N recent commit plists from DIR."
  (let ((raw (claude-code-git-graph--run
              dir "log" "--all" "-n" (number-to-string n)
              "--format=%h|%ar|%an|%D|%s")))
    (when raw
      (mapcar (lambda (line)
                (let ((parts (split-string line "|" nil)))
                  (list :sha    (nth 0 parts)
                        :date   (nth 1 parts)
                        :author (nth 2 parts)
                        :refs   (nth 3 parts)
                        :msg    (nth 4 parts))))
              (split-string raw "\n" t)))))

(defun claude-code-git-graph--heat-face (count max-count)
  "Return face for COUNT commits, scaled to MAX-COUNT."
  (cond
   ((= count 0) 'claude-code-git-heat-0)
   ((< count (max 1 (/ max-count 4))) 'claude-code-git-heat-1)
   ((< count (max 1 (/ max-count 2))) 'claude-code-git-heat-2)
   ((< count (max 1 (* 3 (/ max-count 4)))) 'claude-code-git-heat-3)
   (t 'claude-code-git-heat-4)))

(defun claude-code-git-graph--propertize (text face)
  "Return TEXT with FACE applied."
  (propertize text 'face face))

(defconst claude-code-git-graph--months
  ["Jan" "Feb" "Mar" "Apr" "May" "Jun"
   "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"])

(defun claude-code-git-graph--render-heatmap (dir)
  "Render 52-week heatmap for DIR into current buffer."
  (let* ((weeks 52)
         (counts (claude-code-git-graph--commit-dates dir (* weeks 7)))
         (max-count (let ((m 0))
                      (maphash (lambda (_k v) (setq m (max m v))) counts)
                      (max m 1)))
         ;; Align so today lands in the last column on its correct day-of-week.
         ;; day-of-week in decode-time: 0=Sun 1=Mon … 6=Sat
         (today-dow (nth 6 (decode-time (current-time))))
         ;; Shift: we want the last row (index 6 = Sat) to be today or later.
         ;; Start on a Sunday: go back (weeks*7 + today-dow) days.
         (start-time (time-subtract (current-time)
                                    (days-to-time (+ (* weeks 7) today-dow -1))))
         ;; Build grid[week][day] = "YYYY-MM-DD"
         (grid (let ((g (make-vector weeks nil)))
                 (dotimes (w weeks)
                   (aset g w (make-vector 7 nil))
                   (dotimes (d 7)
                     (aset (aref g w) d
                           (format-time-string
                            "%Y-%m-%d"
                            (time-add start-time
                                      (days-to-time (+ (* w 7) d)))))))
                 g))
         (day-labels ["Su" "Mo" "Tu" "We" "Th" "Fr" "Sa"]))

    (insert (claude-code-git-graph--propertize
             "  Contribution Activity — last 52 weeks\n\n"
             'claude-code-git-graph-header))

    ;; Month label row: 1 char per week, emit 3-char month name where month changes
    (let ((month-row (make-string weeks ?\s))
          (last-month -1))
      (dotimes (w weeks)
        (let* ((ds (aref (aref grid w) 0))
               (m (string-to-number (substring ds 5 7))))
          (when (/= m last-month)
            (setq last-month m)
            (let ((label (aref claude-code-git-graph--months (1- m))))
              (dotimes (i (min (length label) (- weeks w)))
                (aset month-row (+ w i) (aref label i)))))))
      (insert "      ")   ; left margin for day labels
      (insert (claude-code-git-graph--propertize month-row 'claude-code-git-graph-header))
      (insert "\n"))

    ;; Day rows (7 rows: Sun–Sat)
    (dotimes (d 7)
      (insert (claude-code-git-graph--propertize
               (format "  %s  " (aref day-labels d))
               'claude-code-git-graph-date))
      (dotimes (w weeks)
        (let* ((ds (aref (aref grid w) d))
               (cnt (gethash ds counts 0))
               (face (claude-code-git-graph--heat-face cnt max-count)))
          (insert (propertize "█"
                              'face face
                              'help-echo (format "%s: %d commit%s"
                                                 ds cnt
                                                 (if (= cnt 1) "" "s"))))))
      (insert "\n"))

    ;; Legend
    (insert "\n  ")
    (insert (propertize "Less " 'face 'shadow))
    (dolist (f '(claude-code-git-heat-0 claude-code-git-heat-1
                 claude-code-git-heat-2 claude-code-git-heat-3
                 claude-code-git-heat-4))
      (insert (propertize "█" 'face f)))
    (insert (propertize " More\n\n" 'face 'shadow))))

(defun claude-code-git-graph--render-authors (dir)
  "Render top-contributor bar chart for DIR into current buffer."
  (let* ((authors (seq-take (claude-code-git-graph--author-counts dir) 10))
         (max-count (if authors (apply #'max (mapcar #'cdr authors)) 1))
         (bar-width 36))
    (insert (claude-code-git-graph--propertize
             "  Top Contributors\n\n" 'claude-code-git-graph-header))
    (dolist (ac authors)
      (let* ((name   (car ac))
             (cnt    (cdr ac))
             (filled (round (* bar-width (/ (float cnt) max-count))))
             (empty  (- bar-width filled)))
        (insert (propertize (format "  %-22s "
                                    (truncate-string-to-width name 22))
                            'face 'claude-code-git-graph-author))
        (insert (propertize (make-string filled ?█) 'face 'claude-code-git-heat-3))
        (insert (propertize (make-string empty  ?░) 'face 'claude-code-git-heat-0))
        (insert (propertize (format " %d\n" cnt) 'face 'shadow))))
    (insert "\n")))

(defun claude-code-git-graph--render-log (dir)
  "Render recent commits for DIR into current buffer."
  (let ((commits (claude-code-git-graph--recent-commits dir 20)))
    (insert (claude-code-git-graph--propertize
             "  Recent Commits\n\n" 'claude-code-git-graph-header))
    (dolist (c commits)
      (let ((sha    (plist-get c :sha))
            (date   (plist-get c :date))
            (author (plist-get c :author))
            (refs   (plist-get c :refs))
            (msg    (plist-get c :msg)))
        (insert "  ")
        (insert (propertize (format "%s " (or sha "???????"))
                            'face 'claude-code-git-graph-sha))
        (insert (propertize (format "%-13s " (truncate-string-to-width
                                               (or date "") 13))
                            'face 'claude-code-git-graph-date))
        (when (and refs (not (string-empty-p (string-trim refs))))
          (dolist (ref (seq-take (split-string (string-trim refs) ", *" t) 2))
            (unless (string-prefix-p "tag: " ref)
              (insert (propertize (format "(%s) " ref)
                                  'face 'claude-code-git-graph-ref)))))
        (insert (truncate-string-to-width (or msg "") 52))
        (insert (propertize (format " — %s\n"
                                    (truncate-string-to-width (or author "") 20))
                            'face 'claude-code-git-graph-author))))))

(defun claude-code-git-graph--render ()
  "Render the full git graph for `claude-code-git-graph--dir'."
  (let* ((dir (buffer-local-value 'claude-code-git-graph--dir (current-buffer)))
         (inhibit-read-only t))
    (erase-buffer)
    (let* ((repo-name (file-name-nondirectory (directory-file-name dir)))
           (total     (claude-code-git-graph--run dir "rev-list" "--all" "--count"))
           (branch    (claude-code-git-graph--run dir "rev-parse" "--abbrev-ref" "HEAD")))
      (insert "\n")
      (insert (propertize (format "  ██ %s" repo-name)
                          'face 'claude-code-git-graph-header))
      (insert (propertize (format "  ·  branch: %s  ·  %s commits total\n\n"
                                  (or branch "?") (or total "?"))
                          'face 'shadow)))
    (claude-code-git-graph--render-heatmap dir)
    (claude-code-git-graph--render-authors dir)
    (claude-code-git-graph--render-log dir)
    (goto-char (point-min))))

(defvar-local claude-code-git-graph--dir nil
  "Git repo root being visualized in this buffer.")

(defvar-keymap claude-code-git-graph-mode-map
  :doc "Keymap for `claude-code-git-graph-mode'."
  "g" #'claude-code-git-graph-refresh
  "q" #'quit-window
  "n" #'next-line
  "p" #'previous-line)

(define-derived-mode claude-code-git-graph-mode special-mode "GitGraph"
  "Major mode for the Claude Code git contribution graph."
  :group 'claude-code
  (setq buffer-read-only t
        truncate-lines    t))

(defun claude-code-git-graph-refresh ()
  "Refresh the git graph visualization."
  (interactive)
  (message "Refreshing…")
  (claude-code-git-graph--render)
  (message "Git graph updated."))

;;;###autoload
(defun claude-code-git-graph (&optional directory)
  "Show a git contribution graph for DIRECTORY (default: current repo root)."
  (interactive
   (list (read-directory-name
          "Git repo: "
          (or (when (fboundp 'magit-toplevel) (ignore-errors (magit-toplevel)))
              (locate-dominating-file default-directory ".git")
              default-directory))))
  (let* ((dir (or (claude-code-git-graph--run directory "rev-parse" "--show-toplevel")
                  (expand-file-name directory)))
         (repo-name (file-name-nondirectory (directory-file-name dir)))
         (buf (get-buffer-create (format "*Claude Git Graph: %s*" repo-name))))
    (with-current-buffer buf
      (unless (eq major-mode 'claude-code-git-graph-mode)
        (claude-code-git-graph-mode))
      (setq claude-code-git-graph--dir dir)
      (claude-code-git-graph--render))
    (pop-to-buffer buf)))

(provide 'claude-code-git-graph)
;;; claude-code-git-graph.el ends here
