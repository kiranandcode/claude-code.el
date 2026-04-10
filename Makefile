EMACS ?= emacs
BATCH := ./emacs-batch.sh

# Run all checks by default.
MATCH ?=

.PHONY: test clean mypy all checkdoc compile pytest elsa coverage

default: all

# Remove compiled files
clean:
	rm -f *.elc

# All source modules: every claude-code*.el at the repo root, except the test
# file (ERT style doesn't compile cleanly) and the package descriptor (autogen).
# Sorted alphabetically — `-' (0x2d) sorts before `.' (0x2e), so the entry-
# point file `claude-code.el' naturally lands at the end of the list.
SRC_FILES := $(sort $(filter-out claude-code-test.el claude-code-pkg.el, \
               $(wildcard claude-code*.el)))

# Run checkdoc on source files (skip test file — ERT style doesn't pass checkdoc)
checkdoc:
	for FILE in ${SRC_FILES}; do $(BATCH) -eval "(setq sentence-end-double-space nil)" -eval "(checkdoc-file \"$$FILE\")" ; done

# Byte-compile
compile: clean
	$(BATCH) -eval "(setq sentence-end-double-space nil)" -f batch-byte-compile ${SRC_FILES}

# Run ERT tests
test:
	$(BATCH) -l claude-code-test.el -f ert-run-tests-batch-and-exit

# Python unit tests
pytest:
	cd python && uv run pytest -v

# Type-check Python backend
mypy:
	cd python && uv run mypy --strict claude_code_backend.py

# Run Elsa static analysis on all source files
elsa:
	$(BATCH) -l elsa \
	  --eval "(defun elsa--find-dependency (_library-name) nil)" \
	  -f elsa-run ${SRC_FILES}

# Run ERT tests with code coverage (writes coverage/lcov.info)
coverage:
	mkdir -p coverage
	$(BATCH) -l dev/coverage.el -l claude-code-test.el -f ert-run-tests-batch-and-exit

all: checkdoc compile test pytest mypy
