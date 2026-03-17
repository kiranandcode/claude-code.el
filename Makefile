EMACS ?= emacs
BATCH := ./emacs-batch.sh

# Run all checks by default.
MATCH ?=

.PHONY: test clean mypy all checkdoc compile

default: all

# Remove compiled files
clean:
	rm -f *.elc

# Only compile the main source, not the test file
SRC_FILES := claude-code.el

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

all: checkdoc compile test mypy
