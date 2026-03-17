;;; resolve-deps.el --- Set up load-path from Cask + straight.el -*- lexical-binding: t; -*-

;; Reads the Cask file at the project root for `depends-on' declarations,
;; then walks straight.el's build directory to resolve transitive
;; dependencies by scanning `(require ...)' calls in each package.
;;
;; Intended to be loaded with: emacs --batch --load dev/resolve-deps.el ...

(let* ((project-dir (file-name-directory
                     (directory-file-name
                      (file-name-directory (or load-file-name
                                               buffer-file-name)))))
       (cask-file (expand-file-name "Cask" project-dir))
       (straight-build (expand-file-name "straight/build/"
                                         user-emacs-directory))
       ;; Built-in packages that don't need a straight build dir
       (builtins '("emacs" "cl-lib" "seq" "eieio" "subr-x" "pcase"
                   "edmacro" "format-spec" "pp" "cursor-sensor"
                   "nadvice" "cl-generic"))
       (seen nil)
       (queue nil))
  ;; Parse Cask for direct dependencies
  (with-temp-buffer
    (insert-file-contents cask-file)
    (goto-char (point-min))
    (while (re-search-forward "(depends-on \"\\([^\"]+\\)\"" nil t)
      (let ((pkg (match-string 1)))
        (unless (member pkg builtins)
          (push pkg queue)))))
  ;; Resolve transitive deps by scanning (require ...) in .el files
  (while queue
    (let* ((pkg (pop queue))
           (dir (expand-file-name pkg straight-build)))
      (when (and (file-directory-p dir)
                 (not (member pkg seen)))
        (push pkg seen)
        (add-to-list 'load-path dir)
        ;; Scan the main .el file for (require ...) calls
        (let ((el-file (expand-file-name (concat pkg ".el") dir)))
          (when (file-exists-p el-file)
            (with-temp-buffer
              (insert-file-contents el-file)
              (goto-char (point-min))
              (while (re-search-forward
                      "^(require '\\([a-zA-Z0-9_-]+\\))" nil t)
                (let ((dep (match-string 1)))
                  (unless (or (member dep seen)
                              (member dep builtins))
                    (push dep queue))))))))))
  ;; Add the project root
  (add-to-list 'load-path project-dir))

;;; resolve-deps.el ends here
