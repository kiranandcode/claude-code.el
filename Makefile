EMACS ?= emacs
BATCH := ./emacs-batch.sh

# Run all checks by default.
MATCH ?=

.PHONY: test clean mypy all checkdoc compile elsa coverage

default: all

# Remove compiled files
clean:
	rm -f *.elc

# All source modules in load order (test file excluded — ERT style doesn't compile cleanly)
SRC_FILES := claude-code-vars.el \
             claude-code-agents.el \
             claude-code-process.el \
             claude-code-config.el \
             claude-code-events.el \
             claude-code-render.el \
             claude-code-commands.el \
             claude-code-git-graph.el \
             claude-code.el

# Run checkdoc on source files (skip test file — ERT style doesn't pass checkdoc)
checkdoc:
	for FILE in ${SRC_FILES}; do $(BATCH) -eval "(setq sentence-end-double-space nil)" -eval "(checkdoc-file \"$$FILE\")" ; done

# Byte-compile
compile: clean
	$(BATCH) -eval "(setq sentence-end-double-space nil)" -f batch-byte-compile ${SRC_FILES}

# Run ERT tests
test:
	$(BATCH) -l claude-code-test.el -f ert-run-tests-batch-and-exit

# Type-check Python backend
mypy:
	cd python && uv run mypy --strict claude_code_backend.py

# Run Elsa static analysis on all source files
elsa:
	$(BATCH) -l elsa \
	  --eval "(defun elsa--find-dependency (library-name) \
	    (when (stringp library-name) \
	      (let* ((load-suffixes (list \".el\" \".el.gz\")) \
	             (load-file-rep-suffixes (list \"\"))) \
	        (when-let ((lib-file (locate-library library-name))) \
	          (let ((truename (file-truename lib-file))) \
	            (unless (string-match-p \"/share/emacs/\" truename) \
	              truename))))))" \
	  -f elsa-run ${SRC_FILES}

# Run ERT tests with code coverage (writes coverage/lcov.info)
coverage:
	mkdir -p coverage
	$(BATCH) -l dev/coverage.el -l claude-code-test.el -f ert-run-tests-batch-and-exit

all: checkdoc compile test mypy
