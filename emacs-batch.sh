#!/usr/bin/env bash
# emacs-batch.sh — Run Emacs in batch mode with dependencies resolved from Cask.
#
# Loads dev/resolve-deps.el which parses the Cask file for direct deps, then
# walks straight.el's build directory to resolve transitive dependencies
# via each package's -pkg.el file.
#
# Usage:
#   ./emacs-batch.sh -f batch-byte-compile claude-code.el
#   ./emacs-batch.sh --eval '(progn (require (quote claude-code)) (message "ok"))'
#   ./emacs-batch.sh -l claude-code.el --eval '(message "%s" (claude-code--uv-available-p))'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec emacs --batch --load "$SCRIPT_DIR/dev/resolve-deps.el" "$@"
