;;; claude-code.el --- Claude AI coding assistant for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2026

;; Author: Kiran G
;; Version: 0.2.0
;; Package-Requires: ((emacs "30.0") (magit-section "4.0.0") (transient "0.9.3"))
;; Keywords: tools ai
;; URL: https://github.com/kiranandcode/claude-code.el

;;; Commentary:

;; Claude Code integration using the Claude Agent SDK.
;;
;; Communicates with a Python backend over JSON-lines stdin/stdout.
;; The backend uses the Agent SDK to run an AI agent with built-in
;; tool access (file read/write, bash, grep, web search, etc.).
;;
;; The conversation is rendered in a magit-section buffer with collapsible
;; thinking blocks, tool-use details, and streaming token output.
;;
;; Quick start:
;;   M-x claude-code
;;   Type your prompt in the input area at the bottom and press RET.
;;   Press `s' to jump to the input area, `C-j' for a newline in the prompt.
;;
;; The source is split into focused modules — see README.md for the complete
;; file map and per-module descriptions.

;;; Code:

(require 'claude-code-vars)
(require 'claude-code-agents)
(require 'claude-code-process)
(require 'claude-code-config)
(require 'claude-code-stats)
(require 'claude-code-fringe)
(require 'claude-code-events)
(require 'claude-code-diff)
(require 'claude-code-render)
(require 'claude-code-lsp-link)
(require 'claude-code-xwidget)
(require 'claude-code-edit-result)
(require 'claude-code-annotate)
(require 'claude-code-dynamic-tools)
(require 'claude-code-self-heal)
(require 'claude-code-export)
(require 'claude-code-fork-tree)
(require 'claude-code-commands)
(require 'claude-code-git-graph)
(require 'claude-code-frame-render)
(require 'claude-code-emacs-tools)

(provide 'claude-code)
;;; claude-code.el ends here
