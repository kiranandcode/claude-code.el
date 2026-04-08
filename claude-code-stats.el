;;; claude-code-stats.el --- Token/cost usage statistics for claude-code.el -*- lexical-binding: t; -*-

;;; Commentary:

;; In-memory token/cost usage tracking with ASCII visualisations.
;; Data is accumulated per query (from result events) and displayed in
;; a dedicated *Claude Stats* buffer — no persistence across restarts.
;;
;; Entry point: M-x claude-code-stats  (also /stats slash command)
;; Keybinding in stats buffer: g = refresh, q = quit

;;; Code:

(require 'claude-code-vars)
(require 'cl-lib)
(require 'seq)

;;;; Global Store

(defvar claude-code--stats-entries '()
  "In-memory list of completed query stats, newest first.
Each entry is an alist with keys:
  cwd         — project directory string
  cost        — total_cost_usd (float or nil)
  turns       — num_turns (integer)
  duration_ms — wall-clock ms (integer)
  timestamp   — float-time when the result arrived")

(defvar claude-code--stats-session-start (float-time)
  "Float-time when the current Emacs session started collecting stats.")

;;;; Data Recording

(defun claude-code-stats-record! (cwd cost turns duration-ms)
  "Record one completed query into the global stats store.
CWD is the project directory; COST, TURNS, DURATION-MS are from
the result event (any may be nil)."
  (push `((cwd         . ,cwd)
          (cost        . ,cost)
          (turns       . ,(or turns 1))
          (duration_ms . ,(or duration-ms 0))
          (timestamp   . ,(float-time)))
        claude-code--stats-entries))

;;;; ASCII Drawing Helpers

(defun claude-code-stats--bar (filled total width &optional fill-char empty-char)
  "Return a bar string of WIDTH chars with FILLED of TOTAL filled.
FILL-CHAR defaults to ?█, EMPTY-CHAR defaults to ?░."
  (let* ((fill-c  (or fill-char ?█))
         (empty-c (or empty-char ?░))
         (n (if (> total 0)
                (round (* width (/ (float filled) total)))
              0))
         (n (max 0 (min width n))))
    (concat (make-string n fill-c)
            (make-string (- width n) empty-c))))

(defun claude-code-stats--sparkline (values height)
  "Return a list of HEIGHT strings forming a vertical bar chart of VALUES.
Each string is one row; returns rows top-to-bottom.
VALUES is a list of numbers; HEIGHT is number of rows."
  (let* ((max-val (apply #'max (cons 0.0 values)))
         (_n      (length values))
         (rows    '()))
    (dotimes (row height)
      (let* ((level (- height 1 row))   ; 0 = bottom row, height-1 = top
             (threshold (/ (* (1+ level) max-val) (float height)))
             (prev-thresh (/ (* level max-val) (float height)))
             (line ""))
        (dolist (v values)
          (cond
           ((>= v threshold)
            (setq line (concat line "█")))
           ((>= v prev-thresh)
            (setq line (concat line "▄")))
           (t
            (setq line (concat line " ")))))
        (push line rows)))
    (nreverse rows)))

(defun claude-code-stats--format-seconds (secs)
  "Format SECS (a number) as a human-readable duration string."
  (cond
   ((< secs 60)  (format "%.1fs" secs))
   ((< secs 3600)
    (format "%dm %02ds" (floor (/ secs 60)) (round (mod secs 60))))
   (t
    (format "%dh %dm" (floor (/ secs 3600)) (floor (/ (mod secs 3600) 60))))))

(defun claude-code-stats--abbreviate-dir (dir)
  "Shorten DIR for display: collapse $HOME to ~ and trim to 40 chars."
  (let* ((home (expand-file-name "~"))
         (abbrev (if (string-prefix-p home dir)
                     (concat "~" (substring dir (length home)))
                   dir)))
    (if (> (length abbrev) 40)
        (concat "…" (substring abbrev (- (length abbrev) 39)))
      abbrev)))

;;;; Faces

(defface claude-code-stats-title
  '((t :inherit magit-section-heading :height 1.2 :weight bold))
  "Title text in the stats buffer."
  :group 'claude-code)

(defface claude-code-stats-section
  '((t :inherit font-lock-keyword-face :weight bold))
  "Section headings in the stats buffer."
  :group 'claude-code)

(defface claude-code-stats-value
  '((t :inherit font-lock-constant-face :weight bold))
  "Numeric values in the stats buffer."
  :group 'claude-code)

(defface claude-code-stats-bar-fill
  '((t :inherit success))
  "Filled portion of bar charts."
  :group 'claude-code)

(defface claude-code-stats-bar-empty
  '((t :inherit shadow))
  "Empty portion of bar charts."
  :group 'claude-code)

(defface claude-code-stats-project
  '((t :inherit font-lock-string-face))
  "Project directory labels."
  :group 'claude-code)

(defface claude-code-stats-separator
  '((t :inherit shadow))
  "Separator lines."
  :group 'claude-code)

(defface claude-code-stats-hint
  '((t :inherit shadow :slant italic))
  "Hint / keybinding text at the bottom."
  :group 'claude-code)

;;;; Buffer Rendering

(defun claude-code-stats--separator ()
  "Insert a separator line."
  (insert (propertize (concat "\n" (make-string 70 ?─) "\n")
                      'face 'claude-code-stats-separator)))

(defun claude-code-stats--insert-kv (label value &optional label-width)
  "Insert a KEY: VALUE pair line."
  (let ((lw (or label-width 16)))
    (insert (format (concat "  %-" (number-to-string lw) "s")
                    (concat label ":")))
    (insert (propertize value 'face 'claude-code-stats-value))
    (insert "\n")))

(defun claude-code-stats--insert-bar-row (label bar-filled bar-total bar-width
                                                 &optional suffix label-width)
  "Insert a labelled bar chart row."
  (let* ((lw     (or label-width 26))
         (filled (claude-code-stats--bar bar-filled bar-total bar-width))
         (fill-part  (substring filled 0 (round (* bar-width (if (> bar-total 0)
                                                                 (/ (float bar-filled) bar-total)
                                                               0)))))
         (empty-part (substring filled (length fill-part))))
    (insert (format (concat "  %-" (number-to-string lw) "s") label))
    (insert (propertize fill-part  'face 'claude-code-stats-bar-fill))
    (insert (propertize empty-part 'face 'claude-code-stats-bar-empty))
    (when suffix
      (insert (propertize (concat "  " suffix) 'face 'claude-code-stats-value)))
    (insert "\n")))

(defun claude-code-stats--render ()
  "Render the full stats buffer content."
  (let ((inhibit-read-only t))
    (erase-buffer)
    ;; ── Title ──────────────────────────────────────────────────────────────
    (insert "\n")
    (insert (propertize "  ◈  Claude Code  ·  Usage Stats\n" 'face 'claude-code-stats-title))
    (let* ((start (format-time-string "%Y-%m-%d %H:%M:%S"
                                      claude-code--stats-session-start))
           (n     (length claude-code--stats-entries)))
      (insert (propertize (format "     Session since %s · %d quer%s recorded\n"
                                  start n (if (= n 1) "y" "ies"))
                          'face 'shadow)))

    (if (null claude-code--stats-entries)
        (progn
          (claude-code-stats--separator)
          (insert "\n")
          (insert (propertize "  No queries recorded yet.  Send a message to Claude first.\n"
                              'face 'shadow))
          (insert "\n"))

      ;; ── Summary numbers ────────────────────────────────────────────────
      (claude-code-stats--separator)
      (let* ((entries  claude-code--stats-entries)
             (n        (length entries))
             (costs    (delq nil (mapcar (lambda (e) (alist-get 'cost e)) entries)))
             (total-cost (apply #'+ costs))
             (turns    (mapcar (lambda (e) (alist-get 'turns e)) entries))
             (total-turns (apply #'+ turns))
             (durations (mapcar (lambda (e) (alist-get 'duration_ms e)) entries))
             (total-dur-ms (apply #'+ durations))
             (avg-cost  (if (> n 0) (/ total-cost n) 0))
             (avg-dur-s (if (> n 0) (/ (/ total-dur-ms 1000.0) n) 0)))
        (insert "\n")
        ;; two-column layout: insert each cell separately to preserve faces
        (cl-flet ((kv2 (l1 v1 l2 v2)
                    ;; Each column: 14-char label + value padded to col 38
                    (insert (format "  %-14s" l1))
                    (insert (propertize v1 'face 'claude-code-stats-value))
                    (let* ((left-used (+ 2 14 (length v1)))
                           (gap (max 2 (- 38 left-used))))
                      (insert (make-string gap ?\s)))
                    (insert (format "%-16s" l2))
                    (insert (propertize v2 'face 'claude-code-stats-value))
                    (insert "\n")))
          (kv2 "Total Cost:"   (format "$%.4f" total-cost)
               "Total Queries:" (number-to-string n))
          (kv2 "Avg Cost/q:"   (if (> n 0) (format "$%.4f" avg-cost) "—")
               "Total Turns:"   (number-to-string total-turns))
          (kv2 "Avg Duration:" (claude-code-stats--format-seconds avg-dur-s)
               "Total Time:"   (claude-code-stats--format-seconds (/ total-dur-ms 1000.0))))
        (insert "\n")

        ;; ── Cost by Project ──────────────────────────────────────────────
        (claude-code-stats--separator)
        (insert (propertize "  Cost by Project\n" 'face 'claude-code-stats-section))
        (insert "\n")
        (let* ((by-cwd (make-hash-table :test 'equal))
               (bar-w 24))
          ;; Aggregate
          (dolist (e entries)
            (let* ((cwd   (alist-get 'cwd e))
                   (cost  (or (alist-get 'cost e) 0))
                   (cur   (gethash cwd by-cwd '(0 . 0))))
              (puthash cwd (cons (+ (car cur) cost) (1+ (cdr cur)))
                       by-cwd)))
          ;; Collect into a list, sort by cost descending
          (let* ((rows nil))
            (maphash (lambda (k v) (push (cons k v) rows)) by-cwd)
            (setq rows (sort rows (lambda (a b) (> (cadr a) (cadr b)))))
            (dolist (row rows)
              (let* ((cwd    (car row))
                     (cost   (cadr row))
                     (qcount (cddr row))
                     (label  (claude-code-stats--abbreviate-dir cwd))
                     (suffix (format "$%.4f  %d%%" cost
                                     (round (* 100 (if (> total-cost 0)
                                                       (/ cost total-cost)
                                                     0))))))
                (let ((label-col (truncate-string-to-width label 26 0 ?\s)))
                  (insert (propertize (format "  %-26s" label-col) 'face 'claude-code-stats-project)))
                (let* ((frac  (if (> total-cost 0) (/ cost total-cost) 0))
                       (nfill (round (* bar-w frac)))
                       (nfill (max 0 (min bar-w nfill))))
                  (insert (propertize (make-string nfill ?█) 'face 'claude-code-stats-bar-fill))
                  (insert (propertize (make-string (- bar-w nfill) ?░) 'face 'claude-code-stats-bar-empty)))
                (insert (propertize (format "  %s  %dq\n" suffix qcount)
                                    'face 'claude-code-stats-value))))))
        (insert "\n")

        ;; ── Query Cost Sparkline ─────────────────────────────────────────
        (claude-code-stats--separator)
        (insert (propertize "  Query Cost History  " 'face 'claude-code-stats-section))
        (let* ((last-n 30)
               (recent (seq-take (nreverse (copy-sequence entries)) last-n))
               (costs2 (mapcar (lambda (e) (or (alist-get 'cost e) 0.0)) recent))
               (max-c  (if costs2 (apply #'max costs2) 0.0))
               (chart-h 5)
               (bar-w2  (length costs2)))
          (insert (propertize (format "(last %d)\n" (length costs2)) 'face 'shadow))
          (insert "\n")
          (if (or (null costs2) (= max-c 0.0))
              (insert (propertize "  (no cost data)\n" 'face 'shadow))
            ;; Draw vertical bar chart row by row
            (let ((rows (claude-code-stats--sparkline costs2 chart-h)))
              (let ((row-idx 0))
                (dolist (row rows)
                  (let* ((level (- chart-h 1 row-idx))
                         (thresh (/ (* (1+ level) max-c) (float chart-h)))
                         (label  (format "  $%.3f ┤" thresh)))
                    (insert (propertize label 'face 'shadow))
                    ;; Colour each char of the row
                    (dotimes (ci (length row))
                      (let ((ch (substring row ci (1+ ci))))
                        (insert (propertize ch
                                            'face (if (string= ch " ")
                                                      'shadow
                                                    'claude-code-stats-bar-fill)))))
                    (insert "\n"))
                  (cl-incf row-idx))))
            ;; X-axis
            (insert (propertize (format "  %s┴%s →\n"
                                        (make-string 9 ? )
                                        (make-string (max 1 bar-w2) ?─))
                                'face 'shadow))
            (insert (propertize (format "  %s1%s%d\n"
                                        (make-string 9 ? )
                                        (make-string (max 0 (- bar-w2 (length (number-to-string bar-w2)) 1)) ? )
                                        bar-w2)
                                'face 'shadow))))
        (insert "\n")

        ;; ── Duration Distribution ────────────────────────────────────────
        (claude-code-stats--separator)
        (insert (propertize "  Response Duration Distribution\n" 'face 'claude-code-stats-section))
        (insert "\n")
        (let* ((buckets '(("0–2s"   . (0    . 2000))
                          ("2–5s"   . (2000 . 5000))
                          ("5–10s"  . (5000 . 10000))
                          ("10–20s" . (10000 . 20000))
                          ("20s+"   . (20000 . 9999999))))
               (bar-w3  28))
          (dolist (bucket buckets)
            (let* ((label (car bucket))
                   (lo    (cadr bucket))
                   (hi    (cddr bucket))
                   (count (length (seq-filter
                                   (lambda (e)
                                     (let ((d (alist-get 'duration_ms e)))
                                       (and (>= d lo) (< d hi))))
                                   entries)))
                   (pct   (if (> n 0) (round (* 100 (/ (float count) n))) 0)))
              (insert (format "  %-8s" label))
              (let ((nfill (if (> n 0) (round (* bar-w3 (/ (float count) n))) 0)))
                (insert (propertize (make-string nfill ?█) 'face 'claude-code-stats-bar-fill))
                (insert (propertize (make-string (- bar-w3 nfill) ?░) 'face 'claude-code-stats-bar-empty)))
              (insert (propertize (format "  %2dq  %3d%%\n" count pct)
                                  'face 'claude-code-stats-value)))))
        (insert "\n")

        ;; ── Turn Distribution ────────────────────────────────────────────
        (claude-code-stats--separator)
        (insert (propertize "  Turn Distribution\n" 'face 'claude-code-stats-section))
        (insert "\n")
        (let* ((max-turn (apply #'max turns))
               (bar-w4   28)
               (buckets  (append
                          (mapcar (lambda (turn-n)
                                    (cons (format "%d turn%s"
                                                  turn-n (if (= turn-n 1) "" "s"))
                                          turn-n))
                                  (number-sequence 1 (min max-turn 5)))
                          (when (> max-turn 5)
                            (list (cons "6+ turns" 'many))))))
          (dolist (bucket buckets)
            (let* ((label (car bucket))
                   (tv    (cdr bucket))
                   (count (if (eq tv 'many)
                              (length (seq-filter
                                       (lambda (e) (> (alist-get 'turns e) 5))
                                       entries))
                            (length (seq-filter
                                     (lambda (e) (= (alist-get 'turns e) tv))
                                     entries))))
                   (pct   (if (> n 0) (round (* 100 (/ (float count) n))) 0)))
              (insert (format "  %-10s" label))
              (let ((nfill (if (> n 0) (round (* bar-w4 (/ (float count) n))) 0)))
                (insert (propertize (make-string nfill ?█) 'face 'claude-code-stats-bar-fill))
                (insert (propertize (make-string (- bar-w4 nfill) ?░) 'face 'claude-code-stats-bar-empty)))
              (insert (propertize (format "  %2dq  %3d%%\n" count pct)
                                  'face 'claude-code-stats-value)))))
        (insert "\n"))

      ;; ── Footer ──────────────────────────────────────────────────────────
      (claude-code-stats--separator)
      (insert (propertize "  [g] refresh   [q] quit\n" 'face 'claude-code-stats-hint))
      (insert "\n"))
    (goto-char (point-min))))

;;;; Major Mode

(defvar-keymap claude-code-stats-mode-map
  :doc "Keymap for `claude-code-stats-mode'."
  "g" #'claude-code-stats-refresh
  "q" #'quit-window)

(define-derived-mode claude-code-stats-mode special-mode "Claude-Stats"
  "Major mode for the Claude Code usage statistics buffer."
  :group 'claude-code
  (setq buffer-read-only t
        truncate-lines    nil))

(defun claude-code-stats-refresh ()
  "Refresh the stats buffer in place."
  (interactive)
  (claude-code-stats--render))

;;;; Entry Point

;;;###autoload
(defun claude-code-stats ()
  "Show the Claude Code usage statistics buffer.
Stats are accumulated in-memory since Emacs started;
they are not persisted across restarts."
  (interactive)
  (let ((buf (get-buffer-create "*Claude Stats*")))
    (with-current-buffer buf
      (unless (eq major-mode 'claude-code-stats-mode)
        (claude-code-stats-mode))
      (claude-code-stats--render))
    (pop-to-buffer buf
                   '(display-buffer-reuse-window
                     display-buffer-below-selected)
                   '((window-height . 0.45)))))

(provide 'claude-code-stats)
;;; claude-code-stats.el ends here
