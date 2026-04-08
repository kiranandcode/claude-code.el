;;; claude-code-frame-render.el --- Render Emacs frame as decorated text -*- lexical-binding: t -*-

;;; Commentary:
;; Renders the current Emacs frame as an ANSI-decorated ASCII string,
;; capturing window contents, modelines, tab bar, cursor positions,
;; clickable annotations, and image placeholders.
;;
;; This is the frame-snapshot capability used by EmacsRenderFrame to give
;; Claude a visual representation of the live Emacs UI state.
;;
;; Public API:
;;   (claude-code-frame-render)          → decorated string
;;   (claude-code-frame-render-to-file F) → write to file F, return F

;;; Code:

(require 'cl-lib)

;;;; ANSI SGR helpers

(defun claude-code-fr--color-fg-sgr (color)
  "ANSI SGR foreground params for COLOR, or nil."
  (when (and color (stringp color) (color-defined-p color))
    (let ((v (color-values color)))
      (when v
        (format "38;2;%d;%d;%d"
                (ash (nth 0 v) -8) (ash (nth 1 v) -8) (ash (nth 2 v) -8))))))

(defun claude-code-fr--underline-sgr (ul)
  "SGR param strings for underline spec UL."
  (let (parts)
    (cond
     ((and (consp ul) (plist-member ul :style))
      (push (pcase (plist-get ul :style)
              ('wave "4:3") ('double "4:2") (_ "4"))
            parts)
      (when-let* ((c (plist-get ul :color))
                  (fc (claude-code-fr--color-fg-sgr c)))
        (push (replace-regexp-in-string "^38;" "58;" fc) parts)))
     ((stringp ul)
      (push "4" parts)
      (when-let* ((fc (claude-code-fr--color-fg-sgr ul)))
        (push (replace-regexp-in-string "^38;" "58;" fc) parts)))
     (ul (push "4" parts)))
    parts))

(defconst claude-code-fr--reset "\033[0m"
  "ANSI reset sequence.")

;;;; Face → SGR

(defun claude-code-fr--face-attr (face-spec attr)
  "Get face ATTR from FACE-SPEC, handling lists/plists/symbols."
  (cond
   ((null face-spec) nil)
   ((and (symbolp face-spec) (facep face-spec))
    (let ((v (face-attribute face-spec attr nil t)))
      (unless (eq v 'unspecified) v)))
   ((and (consp face-spec) (keywordp (car face-spec)))
    (plist-get face-spec attr))
   ((consp face-spec)
    (cl-dolist (f face-spec)
      (cond
       ((and (symbolp f) (facep f))
        (let ((v (face-attribute f attr nil t)))
          (unless (eq v 'unspecified) (cl-return v))))
       ((and (consp f) (keywordp (car f)))
        (when-let* ((v (plist-get f attr)))
          (cl-return v))))))))

(defun claude-code-fr--face-to-sgr (face-spec)
  "SGR params for FACE-SPEC (fg color + text attrs, no bg)."
  (let* ((fg     (claude-code-fr--face-attr face-spec :foreground))
         (weight (claude-code-fr--face-attr face-spec :weight))
         (slant  (claude-code-fr--face-attr face-spec :slant))
         (ul     (claude-code-fr--face-attr face-spec :underline))
         (strike (claude-code-fr--face-attr face-spec :strike-through))
         parts)
    (when (memq weight '(bold semi-bold extra-bold ultra-bold))
      (push "1" parts))
    (when (memq weight '(semi-light light extra-light ultra-light))
      (push "2" parts))
    (when (memq slant '(italic oblique))
      (push "3" parts))
    (when ul
      (setq parts (nconc (nreverse (claude-code-fr--underline-sgr ul)) parts)))
    (when strike (push "9" parts))
    (when-let* ((fc (claude-code-fr--color-fg-sgr fg)))
      (push fc parts))
    (if parts
        (mapconcat #'identity (nreverse parts) ";")
      "")))

;;;; Grid — [CHAR SGR-PARAMS]

(defun claude-code-fr--make-grid (cols rows)
  "COLS × ROWS grid of [CHAR SGR] cells."
  (let ((g (make-vector rows nil)))
    (dotimes (r rows)
      (let ((row (make-vector cols nil)))
        (dotimes (c cols) (aset row c (vector ?\s "")))
        (aset g r row)))
    g))

(defun claude-code-fr--gset (g r c ch sgr)
  "Set grid cell at row R, col C to character CH with style SGR."
  (when (and (>= r 0) (< r (length g))
             (>= c 0) (< c (length (aref g 0))))
    (aset (aref g r) c (vector ch (or sgr "")))))

(defun claude-code-fr--gput-text (g row col text sgr max-col)
  "Write TEXT with style SGR into GRID row ROW starting at COL.
Returns the next column after the written text."
  (let ((i 0) (c col))
    (while (and (< i (length text)) (< c max-col))
      (let ((ch (aref text i))
            (w (char-width (aref text i))))
        (claude-code-fr--gset g row c ch sgr)
        (when (and (>= w 2) (< (1+ c) max-col))
          (claude-code-fr--gset g row (1+ c) nil sgr))
        (cl-incf c (max w 1))
        (cl-incf i)))
    c))

(defun claude-code-fr--gput-segs (g row col max-col segs)
  "Write segment list ((TEXT SGR) ...) into grid row ROW."
  (let ((c col))
    (dolist (s segs)
      (when (< c max-col)
        (setq c (claude-code-fr--gput-text g row c (nth 0 s) (nth 1 s) max-col))))))

(defun claude-code-fr--gput-box (g row col lines)
  "Draw a labelled box at ROW, COL containing LINES of text."
  (let* ((max-w (apply #'max (mapcar #'string-width lines)))
         (box-w (+ max-w 4))
         (_gcols (length (aref g 0)))
         (grows (length g))
         (sgr "2"))  ; dim for box chrome
    ;; Top border
    (when (< row grows)
      (claude-code-fr--gset g row col ?┌ sgr)
      (dotimes (i (+ max-w 2))
        (claude-code-fr--gset g row (+ col 1 i) ?─ sgr))
      (claude-code-fr--gset g row (+ col box-w -1) ?┐ sgr))
    ;; Content lines
    (cl-loop for line in lines
             for r from (1+ row)
             when (< r grows)
             do (claude-code-fr--gset g r col ?│ sgr)
               (claude-code-fr--gset g r (1+ col) ?\s sgr)
               (claude-code-fr--gput-text g r (+ col 2) line "" (+ col 2 max-w))
               ;; Pad short lines
               (cl-loop for c from (+ col 2 (string-width line))
                        below (+ col 2 max-w)
                        do (claude-code-fr--gset g r c ?\s ""))
               (claude-code-fr--gset g r (+ col 2 max-w) ?\s sgr)
               (claude-code-fr--gset g r (+ col box-w -1) ?│ sgr))
    ;; Bottom border
    (let ((br (+ row 1 (length lines))))
      (when (< br grows)
        (claude-code-fr--gset g br col ?└ sgr)
        (dotimes (i (+ max-w 2))
          (claude-code-fr--gset g br (+ col 1 i) ?─ sgr))
        (claude-code-fr--gset g br (+ col box-w -1) ?┘ sgr)))))

;;;; Action name extraction

(defun claude-code-fr--action-name (action keymap)
  "Extract a readable function name from button ACTION or KEYMAP."
  (or
   (when (symbolp action) (symbol-name action))
   (when action
     (let ((s (prin1-to-string action)))
       (cond
        ((string-match "#'\\([a-zA-Z0-9/_:-]+\\)" s)
         (match-string 1 s))
        ((string-match "(\\([a-zA-Z][a-zA-Z0-9_:-]+\\)" s)
         (match-string 1 s)))))
   (when (keymapp keymap)
     (let (found)
       (map-keymap
        (lambda (_key def)
          (when (and (not found)
                     (symbolp def)
                     (not (memq def '(nil ignore undefined
                                      push-button forward-button
                                      backward-button mouse-face))))
            (setq found (symbol-name def))))
        keymap)
       found))
   (when (keymapp keymap)
     (let ((b (lookup-key keymap [mouse-2])))
       (when (eq b 'push-button) "push-button")))))

;;;; Image detection

(defun claude-code-fr--line-image-info (win line-idx)
  "If display line LINE-IDX in WIN contains an image, return its info.
Returns a plist (:col C :cols W :rows H :file F), or nil."
  (with-selected-window win
    (save-excursion
      (move-to-window-line line-idx)
      (let ((beg (point))
            (end (progn (end-of-visual-line) (point)))
            (pos nil) (col 0)
            (body-w (window-body-width win))
            (found nil))
        (setq pos beg)
        (while (and (not found) (< pos end) (< col body-w))
          (let* ((nd (next-single-char-property-change pos 'display nil end))
                 (disp (get-char-property pos 'display)))
            (if (and (consp disp) (eq (car disp) 'image))
                (let* ((size (ignore-errors (image-size disp t)))
                       (pw (if size (car size) 70))
                       (ph (if size (cdr size) 14))
                       (cw (frame-char-width))
                       (ch (frame-char-height)))
                  (setq found
                        (list :col col
                              :cols (min (- body-w col)
                                         (ceiling (/ (float pw) cw)))
                              :rows (max 1 (ceiling (/ (float ph) ch)))
                              :file (or (plist-get (cdr disp) :file) ""))))
              (cl-incf col (max 1 (- (min nd (+ pos (- body-w col))) pos)))
              (setq pos nd))))
        found))))

;;;; Centering / line-prefix support

(defun claude-code-fr--line-prefix-indent (pos body-w)
  "Compute the display column indent from `line-prefix' at POS.
Returns an integer column offset (0 if no centering)."
  (let* ((lp (get-text-property pos 'line-prefix))
         (disp (when lp (get-text-property 0 'display lp))))
    (cond
     ;; (space :align-to (- center N))
     ((and (consp disp) (eq (car disp) 'space)
           (plist-get (cdr disp) :align-to))
      (let ((align (plist-get (cdr disp) :align-to)))
        (cond
         ;; (- center N)
         ((and (consp align) (eq (car align) '-)
               (eq (cadr align) 'center)
               (numberp (caddr align)))
          (max 0 (round (- (/ body-w 2.0) (caddr align)))))
         ;; center
         ((eq align 'center)
          (/ body-w 2))
         ;; literal number
         ((numberp align)
          (min align body-w))
         (t 0))))
     (t 0))))

;;;; Content extraction with annotation collection
;; Annotation: (KIND COL DETAIL) where KIND is \\='link or \\='hover,
;; COL is the display column (within window body) after the element.

(defun claude-code-fr--window-line-data (win line-idx)
  "Extract segments and annotations for visual line LINE-IDX in WIN.
Returns a plist (:segments ((TEXT SGR)...) :annotations ((KIND COL DETAIL)...))."
  (let ((body-w (window-body-width win))
        segs annots (col 0)
        last-btn last-kmap last-help last-wbtn)
    (with-selected-window win
      (save-excursion
        (goto-char (window-start win))
        (move-to-window-line line-idx)
        (let* ((beg (point))
               (end (progn (end-of-visual-line) (point)))
               (pos nil)
               ;; Handle line-prefix centering
               (indent (claude-code-fr--line-prefix-indent beg body-w)))
          (setq col indent)
          (when (> indent 0)
            (push (list (make-string indent ?\s) "") segs))
          (setq pos beg)
          (while (and (< pos end) (< col body-w))
            (let* ((nf (next-single-char-property-change pos 'face nil end))
                   (ni (next-single-char-property-change pos 'invisible nil end))
                   (nd (next-single-char-property-change pos 'display nil end))
                   (nk (next-single-char-property-change pos 'keymap nil end))
                   (nh (next-single-char-property-change pos 'help-echo nil end))
                   (nx (min nf ni nd nk nh))
                   (inv (get-char-property pos 'invisible))
                   (disp (get-char-property pos 'display))
                   (fspec (get-char-property pos 'face))
                   (sgr (claude-code-fr--face-to-sgr fspec))
                   (help (get-char-property pos 'help-echo))
                   (button (button-at pos))
                   (kmap (get-char-property pos 'keymap))
                   (seg-w 0))
              (cond
               (inv (setq pos nx))
               ((stringp disp)
                (let ((t2 (truncate-string-to-width disp (- body-w col))))
                  (push (list t2 sgr) segs)
                  (setq seg-w (string-width t2))
                  (setq pos nx)))
               ;; Images: emit a single placeholder char (box drawn later)
               ((and (consp disp) (eq (car disp) 'image))
                (push (list " " sgr) segs)
                (setq seg-w 1)
                (setq pos nx))
               ((and (consp disp) (eq (car disp) 'space))
                (let ((n (min (let ((w (plist-get (cdr disp) :width)))
                                (if (integerp w) w 1))
                              (- body-w col))))
                  (push (list (make-string n ?\s) sgr) segs)
                  (setq seg-w n)
                  (setq pos nx)))
               (t
                (let* ((avail (- body-w col))
                       (te (min nx (+ pos avail)))
                       (txt (buffer-substring-no-properties pos te))
                       (txt (replace-regexp-in-string "\n" "" txt))
                       (txt (truncate-string-to-width txt avail)))
                  (push (list txt sgr) segs)
                  (setq seg-w (string-width txt))
                  (setq pos te))))
              ;; Annotations (deduplicate by object identity)
              (when (> seg-w 0)
                (let* ((ecol (+ col seg-w))
                       (mface (get-char-property pos 'mouse-face))
                       ;; Widget buttons: overlay with 'button property
                       (wbtn (get-char-property pos 'button))
                       (waction (when (and (consp wbtn) (plist-get (cdr wbtn) :action))
                                  (let ((a (plist-get (cdr wbtn) :action)))
                                    (cond
                                     ((symbolp a) (symbol-name a))
                                     (t (let ((s (prin1-to-string a)))
                                          (when (string-match "(\\([a-zA-Z][a-zA-Z0-9/_:-]+\\)" s)
                                            (match-string 1 s)))))))))
                  ;; Link annotation
                  (when (or (and button (not (eq button last-btn)))
                            (and kmap mface (not (eq kmap last-kmap)))
                            (and waction wbtn (not (eq wbtn last-wbtn))))
                    (let ((name (or waction
                                    (claude-code-fr--action-name
                                     (when button (button-get button 'action))
                                     kmap))))
                      (when name
                        (push (list 'link ecol name) annots)))
                    (setq last-btn button last-kmap kmap last-wbtn wbtn))
                  ;; Hover annotation
                  (when (and (stringp help) (not (equal help last-help)))
                    (push (list 'hover ecol help) annots)
                    (setq last-help help))
                  (cl-incf col seg-w))))))))
    (list :segments (nreverse segs) :annotations (nreverse annots))))

;;;; Modeline extraction with annotations

(defun claude-code-fr--modeline-data (win)
  "Extract modeline segments and annotations for WIN.
Returns a plist (:segments ((TEXT SGR)...) :annotations ((KIND COL DETAIL)...))."
  (let* ((str (with-selected-window win
                (format-mode-line mode-line-format)))
         (pos 0) (len (length str)) (col 0)
         segs annots last-map last-help)
    (while (< pos len)
      (let* ((nf (or (next-single-property-change pos 'face str) len))
             (nd (or (next-single-property-change pos 'display str) len))
             (nm (or (next-single-property-change pos 'local-map str) len))
             (nh (or (next-single-property-change pos 'help-echo str) len))
             (nx (min nf nd nm nh))
             (nx (min (max nx (1+ pos)) len))
             (fspec (get-text-property pos 'face str))
             (disp (get-text-property pos 'display str))
             (lmap (get-text-property pos 'local-map str))
             (help (get-text-property pos 'help-echo str))
             (sgr (claude-code-fr--face-to-sgr fspec))
             ;; Force bold on modeline
             (sgr (if (string-empty-p sgr) "1"
                    (if (string-match-p "\\(?:^\\|;\\)1\\(?:;\\|$\\)" sgr) sgr
                      (concat "1;" sgr))))
             (text nil) (text-w 0))
        (cond
         ((and (consp disp) (eq (car disp) 'image))
          (setq text "▐" text-w 1))
         ((stringp disp)
          (setq text disp text-w (string-width disp)))
         (t
          (setq text (substring-no-properties str pos nx)
                text-w (string-width text))))
        (push (list text sgr) segs)
        ;; Annotations
        (let ((ecol (+ col text-w)))
          (when (and (keymapp lmap) (not (eq lmap last-map)))
            (let ((name (claude-code-fr--action-name nil lmap)))
              (when name (push (list 'link ecol name) annots)))
            (setq last-map lmap))
          (when (and (stringp help) (not (equal help last-help)))
            (push (list 'hover ecol help) annots)
            (setq last-help help)))
        (cl-incf col text-w)
        (setq pos nx)))
    (list :segments (nreverse segs) :annotations (nreverse annots))))

;;;; Tab bar segments

(defun claude-code-fr--tab-bar-segments ()
  "Return tab-bar segment list with │ borders."
  (let ((tabs (funcall tab-bar-tabs-function)) result)
    (dolist (tab tabs)
      (let* ((name (alist-get 'name tab))
             (cur (alist-get 'current-tab tab))
             (sgr (if cur "1;4" "2")))
        (push (list "│" "") result)
        (push (list (format " %s " name) sgr) result)))
    (when result (push (list "│" "") result))
    (nreverse result)))

;;;; Grid to string

(defun claude-code-fr--grid-to-string (grid)
  "Convert GRID to an ANSI-decorated string."
  (with-temp-buffer
    (let ((rows (length grid))
          (cols (length (aref grid 0))))
      (dotimes (r rows)
        (let ((row (aref grid r)) (prev ""))
          (dotimes (c cols)
            (let ((cell (aref row c)))
              (when (aref cell 0)
                (let ((sgr (aref cell 1)))
                  (unless (equal sgr prev)
                    (insert claude-code-fr--reset)
                    (unless (string-empty-p sgr)
                      (insert "\033[" sgr "m"))
                    (setq prev sgr))
                  (insert (aref cell 0))))))
          (insert claude-code-fr--reset "\n"))))
    (buffer-string)))

;;;; Main rendering entry points

;;;###autoload
(defun claude-code-frame-render ()
  "Render the current Emacs frame as an ANSI-decorated string.
Captures all windows, modelines, the tab bar, cursor positions,
clickable-link citations, and hover citations.

Returns a multi-line string suitable for writing to a terminal or file."
  (let* ((all-wins (append (window-list nil 'no-minibuf)
                           (list (minibuffer-window))))
         (gcols (apply #'max (mapcar (lambda (w) (nth 2 (window-edges w)))
                                     all-wins)))
         (grows (apply #'max (mapcar (lambda (w) (nth 3 (window-edges w)))
                                     all-wins)))
         (tab-h (or (frame-parameter nil 'tab-bar-lines) 0))
         (grid (claude-code-fr--make-grid gcols grows))
         (all-annots nil)
         (cite-n 0)
         ;; Map: (win → alist of (line-idx . grid-row)) for cursor tracking
         (line-maps (make-hash-table :test 'eq)))

    ;; ── Tab bar ──
    (when (> tab-h 0)
      (claude-code-fr--gput-segs grid 0 0 gcols (claude-code-fr--tab-bar-segments))
      (let ((br (min (1- grows) tab-h)))
        (when (< br grows)
          (dotimes (c gcols)
            (claude-code-fr--gset grid br c ?─ "")))))

    ;; ── Windows ──
    (dolist (win (window-list nil 'no-minibuf))
      (let* ((edges (window-edges win))
             (wl (nth 0 edges)) (_wt (nth 1 edges))
             (wr (nth 2 edges)) (wb (nth 3 edges))
             (inside (window-inside-edges win))
             (bl (nth 0 inside)) (bt (nth 1 inside))
             (bw (window-body-width win))
             (bh (window-body-height win))
             (br (+ bl bw)))

        ;; Body lines + images + annotations
        (let ((grid-row bt)
              (line-idx 0)
              (win-line-map nil))
          (while (and (< line-idx bh) (< grid-row (+ bt bh)))
            (let ((img (claude-code-fr--line-image-info win line-idx)))
              (if img
                  ;; Image: draw box and skip rows
                  (let* ((ic   (plist-get img :col))
                         (iw   (plist-get img :cols))
                         (ih   (plist-get img :rows))
                         (file (plist-get img :file))
                         (fname (file-name-nondirectory file))
                         (gc   (+ bl ic))
                         (max-r (min ih (- (+ bt bh) grid-row)))
                         (box-w (min iw (- br gc))))
                    (when (and (> box-w 2) (> max-r 2))
                      (let ((label (truncate-string-to-width
                                    (format "🖼 %s (%d×%d px)" fname
                                            (* iw (frame-char-width))
                                            (* ih (frame-char-height)))
                                    (max 0 (- box-w 4)))))
                        ;; Top border
                        (claude-code-fr--gset grid grid-row gc ?┌ "2")
                        (dotimes (j (- box-w 2))
                          (claude-code-fr--gset grid grid-row (+ gc 1 j) ?─ "2"))
                        (claude-code-fr--gset grid grid-row (+ gc box-w -1) ?┐ "2")
                        ;; Interior
                        (cl-loop for r from 1 below (1- max-r)
                                 do (claude-code-fr--gset grid (+ grid-row r) gc ?│ "2")
                                    (claude-code-fr--gset grid (+ grid-row r) (+ gc box-w -1) ?│ "2")
                                    (dotimes (j (- box-w 2))
                                      (claude-code-fr--gset grid (+ grid-row r) (+ gc 1 j) ?\s "")))
                        ;; Label centered
                        (let* ((mid (+ grid-row (/ max-r 2)))
                               (pad (/ (- box-w 2 (string-width label)) 2)))
                          (claude-code-fr--gput-text grid mid (+ gc 1 (max 0 pad))
                                                     label "2" (+ gc box-w -1)))
                        ;; Bottom border
                        (let ((bot (+ grid-row max-r -1)))
                          (claude-code-fr--gset grid bot gc ?└ "2")
                          (dotimes (j (- box-w 2))
                            (claude-code-fr--gset grid bot (+ gc 1 j) ?─ "2"))
                          (claude-code-fr--gset grid bot (+ gc box-w -1) ?┘ "2"))))
                    (push (cons line-idx grid-row) win-line-map)
                    (cl-incf grid-row max-r))
                ;; Normal text line
                (let* ((data (claude-code-fr--window-line-data win line-idx))
                       (segs (plist-get data :segments))
                       (annots (plist-get data :annotations)))
                  (claude-code-fr--gput-segs grid grid-row bl br segs)
                  (dolist (a annots)
                    (push (list (nth 0 a) grid-row
                                (+ bl (nth 1 a)) (nth 2 a))
                          all-annots))
                  (push (cons line-idx grid-row) win-line-map)
                  (cl-incf grid-row))))
            (cl-incf line-idx))
          (puthash win (nreverse win-line-map) line-maps))

        ;; Modeline + annotations
        (let* ((ml-row (+ bt bh))
               (ml-data (claude-code-fr--modeline-data win))
               (ml-segs (plist-get ml-data :segments))
               (ml-annots (plist-get ml-data :annotations)))
          (when (< ml-row grows)
            (claude-code-fr--gput-segs grid ml-row wl wr ml-segs))
          (dolist (a ml-annots)
            (push (list (nth 0 a) ml-row (+ wl (nth 1 a)) (nth 2 a))
                  all-annots))
          ;; ─ border below modeline (when there's a gap)
          (cl-loop for j from 1 below (max 0 (- wb ml-row 1))
                   when (< (+ ml-row j) grows)
                   do (dotimes (c (- wr wl))
                        (claude-code-fr--gset grid (+ ml-row j) (+ wl c) ?─ ""))))))

    ;; ── Window dividers ──
    (let ((wins (window-list nil 'no-minibuf)))
      (dolist (w1 wins)
        (let ((r1 (nth 2 (window-edges w1))))
          (dolist (w2 wins)
            (when (and (not (eq w1 w2))
                       (= r1 (nth 0 (window-edges w2))))
              (let ((top (max (nth 1 (window-edges w1))
                              (nth 1 (window-edges w2))))
                    (bot (min (nth 3 (window-edges w1))
                              (nth 3 (window-edges w2)))))
                (dotimes (r (- bot top))
                  (claude-code-fr--gset grid (+ top r) r1 ?│ ""))))))))

    ;; ── Minibuffer ──
    (let* ((mb (minibuffer-window))
           (mi (window-inside-edges mb))
           (ml (nth 0 mi)) (mt (nth 1 mi)) (mr (nth 2 mi))
           (txt (with-selected-window mb
                  (buffer-substring-no-properties (point-min) (point-max)))))
      (when (and (> (length txt) 0) (>= mt 0) (< mt grows))
        (claude-code-fr--gput-text grid mt ml txt "" mr)))

    ;; ── Cursor positions ──
    ;; Mark each window's cursor with inverse video style (SGR 7)
    (dolist (win (window-list nil 'no-minibuf))
      (let* ((inside (window-inside-edges win))
             (bl (nth 0 inside)) (bt (nth 1 inside))
             (bw (window-body-width win))
             (bh (window-body-height win))
             (win-lmap (gethash win line-maps))
             (cursor-info
              (with-selected-window win
                (save-excursion
                  (let* ((pt (window-point win))
                         (col (progn (goto-char pt) (current-column)))
                         (disp-line (count-lines (window-start win) pt))
                         (indent (claude-code-fr--line-prefix-indent
                                  (line-beginning-position) bw)))
                    (list disp-line (+ col indent))))))
             (cur-dline (nth 0 cursor-info))
             (cur-col (nth 1 cursor-info))
             (grid-row (or (cdr (assq cur-dline win-lmap))
                           (+ bt (min cur-dline (1- bh)))))
             (grid-col (+ bl (min cur-col (1- bw)))))
        (when (and (< grid-row (+ bt bh)) (< grid-col (+ bl bw)))
          (let* ((cell (when (and (< grid-row (length grid))
                                  (< grid-col (length (aref grid 0))))
                          (aref (aref grid grid-row) grid-col)))
                 (ch (if cell (aref cell 0) ?\s))
                 (ch (or ch ?\s)))
            (claude-code-fr--gset grid grid-row grid-col ch "7"))))) ; SGR 7 = inverse

    ;; ── Citation numbers (inserted BEFORE buffer info boxes) ──
    (setq all-annots (nreverse all-annots))
    (let ((numbered nil))
      (dolist (a all-annots)
        (let* ((kind (nth 0 a))
               (det  (nth 3 a)))
          (when (or (eq kind 'hover)
                    (and (eq kind 'link) det (not (equal det "nil"))))
            (cl-incf cite-n)
            (push (list cite-n kind (nth 1 a) (nth 2 a) det) numbered)
            (claude-code-fr--gput-text grid (nth 1 a) (nth 2 a)
                           (format "[%d]" cite-n) "2" gcols))))
      (setq numbered (nreverse numbered))

      ;; ── Buffer info boxes (drawn AFTER citations) ──
      (dolist (win (window-list nil 'no-minibuf))
        (let* ((inside (window-inside-edges win))
               (bl (nth 0 inside)) (bt (nth 1 inside))
               (bw (window-body-width win))
               (br (+ bl bw))
               (bufname (buffer-name (window-buffer win)))
               (modename (with-current-buffer (window-buffer win)
                           (symbol-name major-mode)))
               (line1 (format "buffer: %s" bufname))
               (line2 (format "mode:   %s" modename))
               (max-w (min (- bw 4)
                           (max (string-width line1) (string-width line2))))
               (line1 (truncate-string-to-width line1 max-w))
               (line2 (truncate-string-to-width line2 max-w))
               (box-w (+ max-w 4))
               (box-col (max bl (- br box-w))))
          (claude-code-fr--gput-box grid bt box-col (list line1 line2))))

      ;; ── Build final output string ──
      (let ((frame-str (claude-code-fr--grid-to-string grid))
            ;; Group links by action, group hovers by text
            (link-groups (make-hash-table :test 'equal))
            (hover-groups (make-hash-table :test 'equal))
            (link-order nil)
            (hover-order nil))
        (dolist (n numbered)
          (let ((num  (nth 0 n))
                (kind (nth 1 n))
                (det  (nth 4 n)))
            (pcase kind
              ('link
               (unless (gethash det link-groups)
                 (push det link-order))
               (push num (gethash det link-groups)))
              ('hover
               (let ((key (replace-regexp-in-string "\n" "  " det)))
                 (unless (gethash key hover-groups)
                   (push key hover-order))
                 (push num (gethash key hover-groups)))))))
        (setq link-order (nreverse link-order)
              hover-order (nreverse hover-order))
        (concat
         ;; Frame header
         (let* ((fname (frame-parameter nil 'name))
                (is-active (eq (selected-frame) (car (frame-list))))
                (marker (if is-active "★" "○"))
                (header (format "%s Frame: %s  (%dx%d)"
                                marker fname gcols grows)))
           (concat header "\n"
                   (make-string (min gcols (string-width header)) ?═) "\n"))
         frame-str "\n"
         (when link-order
           (concat "links:\n"
                   (mapconcat
                    (lambda (action)
                      (let* ((nums (nreverse (gethash action link-groups)))
                             (tags (mapconcat (lambda (n) (format "[%d]" n))
                                             nums ",")))
                        (if (member action '("lambda" "push-button" "anonymous"))
                            (format "  %s clickable" tags)
                          (format "  %s calls %s" tags action))))
                    link-order "\n")
                   "\n"))
         (when hover-order
           (concat "\nhover:\n"
                   (mapconcat
                    (lambda (text)
                      (let* ((nums (nreverse (gethash text hover-groups)))
                             (tags (mapconcat (lambda (n) (format "[%d]" n))
                                             nums ",")))
                        (format "  %s \"%s\"" tags text)))
                    hover-order "\n")
                   "\n"))
         ;; Legend
         "\nlegend:\n"
         "  ★ active frame  ○ inactive frame\n"
         (format "  \033[7m \033[0m cursor position  │ window divider  ─ separator\n")
         "  ┌─┐ buffer info / image box  [N] citation\n"
         (format "  \033[1mbold\033[0m=modeline  \033[2mdim\033[0m=chrome  \033[3mitalic\033[0m  \033[4munderline\033[0m\n"))))))

;;;###autoload
(defun claude-code-frame-render-to-file (file)
  "Render the current frame to FILE and return FILE.
The output can be viewed in any terminal with ANSI support (e.g. `cat FILE')."
  (interactive "FOutput file: ")
  (let ((s (claude-code-frame-render)))
    (with-temp-file file
      (set-buffer-multibyte t)
      (insert s))
    (message "Wrote %s" file)
    file))

(provide 'claude-code-frame-render)
;;; claude-code-frame-render.el ends here
