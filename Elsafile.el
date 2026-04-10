;;; Elsafile.el --- Elsa project configuration -*- lexical-binding: t; no-byte-compile: t -*-

;; Elsa loads this file via its own restricted parser that only handles
;; `register-extensions' and `register-ruleset' forms — arbitrary Elisp is
;; silently ignored.  The nil-safety patch for Emacs 30 compatibility is
;; applied via --eval in the Makefile instead (see `make elsa').
;;
;; The `no-byte-compile: t' file-local variable in the header tells Emacs
;; (and straight.el's build pass) not to byte-compile this file.  Without
;; it, the file's lack of any top-level forms produces an "empty byte
;; compiler output" warning at package install/build time.

;;; Elsafile.el ends here
