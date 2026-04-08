;;; coverage.el --- Configure undercover for code coverage -*- lexical-binding: t; -*-

;; Instruments all claude-code source files with undercover before the test
;; file loads them, so that every form is tracked from the start.
;;
;; Usage:
;;   make coverage
;; or directly:
;;   ./emacs-batch.sh -l dev/coverage.el -l claude-code-test.el \
;;                    -f ert-run-tests-batch-and-exit
;;
;; Output: coverage/lcov.info (viewable with e.g. `genhtml` or a coverage UI)

(require 'undercover)

(undercover "claude-code*.el"
            (:report-format 'lcov)
            (:report-file "coverage/lcov.info")
            (:send-report nil))

;;; coverage.el ends here
