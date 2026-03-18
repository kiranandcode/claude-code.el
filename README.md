# claude-code.el

An Emacs interface for Claude AI using the [Claude Agent SDK](https://pypi.org/project/claude-agent-sdk/).

Features a magit-section conversation buffer with streaming output, collapsible
thinking/tool blocks, per-project configuration, org-roam context integration,
slash commands, message queuing, and a treemacs-style agent sidebar for
monitoring sessions and subagents.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Emacs                                                   │
│                                                         │
│  claude-code.el                                         │
│  ├── magit-section buffer (conversation UI)             │
│  ├── transient menu (keyboard-first commands)           │
│  ├── agent sidebar (treemacs-style session tree)        │
│  ├── process filter (JSON-lines parser)                 │
│  └── overlay-based thinking spinner                     │
│           │                                             │
│           │ stdin: JSON-line commands                    │
│           │ stdout: JSON-line events                    │
│           ▼                                             │
│  python/claude_code_backend.py                          │
│  ├── asyncio main loop (stdin reader)                   │
│  ├── typed protocol (dataclasses)                       │
│  ├── SDK message → protocol event conversion            │
│  └── query dispatch + cancellation                      │
│           │                                             │
│           │ Claude Agent SDK                            │
│           ▼                                             │
│  claude-agent-sdk (pip package)                         │
│  ├── query() async iterator                             │
│  ├── built-in tools (Read/Write/Edit/Bash/Glob/Grep)   │
│  └── streaming via StreamEvent (raw SSE deltas)         │
│           │                                             │
│           │ HTTPS                                       │
│           ▼                                             │
│  Claude API                                             │
└─────────────────────────────────────────────────────────┘
```

## Source Files

The package is split into focused modules that load in dependency order via
`claude-code.el` (the main entry point).  When working on the codebase, check
this table first to identify which file to read or edit.

| File | Purpose | Depends on |
|------|---------|-----------|
| `claude-code-vars.el` | All `defcustom`, `defface`, `defvar`/`defvar-local` declarations, the `claude-code--def-key-command` macro, shared constants (`claude-code--thinking-frames`, `claude-code--slash-commands`), and Emacs-native subagent state vars (`claude-code--subagent-task-id`, `claude-code--subagent-parent-key`, `claude-code--subagent-has-worked`, `claude-code-enable-native-subagents`) | External: `magit-section`, `transient`, `cl-lib`, `json`, `project`, `seq` |
| `claude-code-agents.el` | Global agent registry (`claude-code--agents` hash), register/update/unregister functions, parent–child tree helpers, the treemacs-style Agent Sidebar (`claude-code-agents-mode`), and per-task progress buffers (`claude-code-task-mode`) | `claude-code-vars`, `magit-section` |
| `claude-code-process.el` | UV/Python environment setup (`claude-code--ensure-environment`), backend process lifecycle (`claude-code--start-process`, `--stop-process`, `--send-json`), and the process filter/sentinel that parse JSON-lines output | `claude-code-vars` |
| `claude-code-config.el` | Session config merging (defaults → project overrides → session overrides via `claude-code--session-config`), org-roam project-notes/TODOs/skills loading, and `claude-code--build-system-prompt` (always injects the current Emacs buffer name so the agent can self-reference) | `claude-code-vars` |
| `claude-code-events.el` | Dispatches backend events (`claude-code--handle-event`), handles status transitions, streaming deltas (text/thinking), task sub-agent events, Emacs-native subagent completion notifications (`claude-code--subagent-notify-parent`), and owns `claude-code--schedule-render` (debounced render timer) | `claude-code-vars`, `claude-code-agents` |
| `claude-code-render.el` | Full buffer rendering (`claude-code--render` and all `claude-code--render-*` helpers), text utilities (`claude-code--indent`, `--insert-linkified`), and the thinking-spinner animation (`claude-code--start-thinking`, `--stop-thinking`) | `claude-code-vars`, `claude-code-config`, `magit-section` |
| `claude-code-commands.el` | All user-facing interactive commands (`claude-code-send`, `claude-code-cancel`, `claude-code-fork`, etc.), input area handling and history navigation, slash-command dispatch, session config setters, Emacs-native subagent spawning (`claude-code--spawn-subagent`), the `claude-code-menu` transient, keymap, `claude-code-mode` major mode definition, and the main entry points (`claude-code`, `claude-code-quick`, `claude-code-reload`) | `claude-code-vars`, `claude-code-agents`, `claude-code-process`, `claude-code-config`, `claude-code-events`, `claude-code-render` |
| `claude-code-git-graph.el` | Standalone git repository visualizer (`claude-code-git-graph`): 52-week contribution heatmap, top-contributors bar chart, and recent-commits log.  No dependency on the rest of the package. | `claude-code-vars` |
| `claude-code.el` | Package entry point — `require`s all modules above in load order and `provide`s `claude-code` | All of the above |
| `claude-code-test.el` | ERT test suite (151 tests).  Run with `make test`. | `claude-code` |
| `python/claude_code_backend.py` | Async Python backend: reads JSON-line commands from stdin, calls the Claude Agent SDK, and writes JSON-line events to stdout | `claude-agent-sdk` (PyPI) |

### Module dependency graph

```
claude-code-vars
    ├── claude-code-agents
    │       └── (used by events, commands, process)
    ├── claude-code-process
    ├── claude-code-config
    │       └── claude-code-render
    ├── claude-code-events
    │       └── (uses render, commands — forward refs, resolved at runtime)
    ├── claude-code-commands   ← aggregates everything
    └── claude-code-git-graph
```

Forward references (functions called across module boundaries at runtime, not
load time) are annotated with comments in the source.  They are safe because
`claude-code.el` loads all modules before any interactive command can be
invoked.

## Installation

### Prerequisites

- Emacs 30.0+
- Python 3.12+
- [uv](https://docs.astral.sh/uv/) (Python package manager)
- [Claude Code](https://claude.ai/download) installed and authenticated (uses your Claude.ai subscription — no API key needed)

### Setup

```bash
git clone https://github.com/kiranandcode/claude-code.el.git
```

The Python environment is set up **automatically** on first launch —
`claude-code.el` checks for `uv`, creates the virtualenv, and runs `uv sync`
if needed.  No manual `cd python && uv sync` required.

To force a dependency sync (e.g. after `git pull`), run `M-x claude-code-sync`.

If `uv` is not installed, the package will error immediately with a link to the
installation instructions instead of producing cryptic JSON parse failures.

### use-package + straight.el

```elisp
(use-package claude-code
  :straight
  (claude-code
   :type git
   :host github
   :repo "kiranandcode/claude-code.el"
   :files ("*.el" "python"))
  :commands (claude-code claude-code-quick claude-code-menu
             claude-code-send-region claude-code-reload
             claude-code-git-graph)
  :bind
  (("C-c l"     . claude-code)
   ("C-c L"     . claude-code-menu)
   ("C-c C-l r" . claude-code-reload)))
```

### use-package + vc (Emacs 30+)

```elisp
(use-package claude-code
  :vc (:url "https://github.com/kiranandcode/claude-code.el" :rev :newest)
  :commands (claude-code claude-code-quick claude-code-menu)
  :bind ("C-c l" . claude-code))
```

Emacs dependencies (`magit-section`, `transient`) are pulled automatically from MELPA.

## Usage

```
M-x claude-code       Open the Claude buffer for the current project
```

Type your prompt in the input area at the bottom and press `RET` to send.
`C-j` inserts a newline in the prompt.

Single-letter keys (`s`, `c`, `?`, etc.) are **context-aware**: they
self-insert when the cursor is in the input area and run commands when
the cursor is in the conversation above.

### Keyboard Shortcuts (in Claude buffer)

These shortcuts work when point is **outside the input area** (in the
conversation).  Inside the input area, all keys type normally.

| Key | Command | Description |
|-----|---------|-------------|
| `s` | `claude-code-focus-input` | Jump to input area |
| `RET` | `claude-code-return` | Submit prompt (in input area) or toggle section |
| `C-j` | `newline` | Insert newline in input area |
| `SPC` / `S-SPC` | — | Scroll up/down in conversation (or self-insert space in input area) |
| `DEL` | `claude-code-key-delete-backward` | Delete backward (input area) or scroll down |
| `r` | `claude-code-send-region` | Send region with a prompt |
| `c` | `claude-code-cancel` | Cancel running query |
| `C` | `claude-code-clear` | Clear conversation |
| `k` | `claude-code-kill` | Kill session and buffer |
| `R` | `claude-code-restart` | Restart backend (keeps conversation) |
| `a` | `claude-code-agents-toggle` | Toggle agent sidebar |
| `S` | `claude-code-sync` | Sync Python environment |
| `n` | `claude-code-open-notes` | Open the global notes org file |
| `d` | `claude-code-open-dir-notes` | Open/create project context notes (org-roam) |
| `o` | `claude-code-open-dir-todos` | Open/create project TODO list (org-roam) |
| `M-p` | `claude-code-previous-input` | Recall previous input (older) |
| `M-n` | `claude-code-next-input` | Recall next input (more recent) |
| `TAB` | — | Slash-command completion (input area) or toggle section |
| `?` | `claude-code-menu` | Transient command menu |
| `q` | `quit-window` | Bury buffer |
| `G` | `claude-code--render` | Force re-render |

`t` (toggle thinking), `T` (toggle tool details), `W` (reset), `N` (new
session), and `f` (send file context) are available via the `?` transient menu,
not as direct buffer shortcuts.

### From Any Buffer

```
M-x claude-code-quick            ;; prompt in minibuffer, no buffer switch
M-x claude-code-send-region      ;; send selection with a question
M-x claude-code-send-buffer-file ;; send file path with a question
```

### Slash Commands

Type `/` in the input area to trigger slash commands with auto-complete (via
`completion-at-point`, picked up automatically by `company` or `corfu`):

| Command | Action |
|---------|--------|
| `/clear` | Clear the conversation history |
| `/reset` | Hard-reset: clear all messages and restart the backend |
| `/new` | Open a new independent session for this directory |
| `/model` | Set the model for this session |
| `/effort` | Set the thinking effort level |
| `/notes` | Open the global notes file |
| `/project-notes` | Open or create project context notes |
| `/todos` | Open or create project TODO list |
| `/inspect` | Show session state |
| `/help` | Show the transient command menu |

### Input History

Press `M-p` / `M-n` in the input area to cycle through previously submitted
prompts in the current session (like shell history):

- **`M-p`** — older input (back in history)
- **`M-n`** — newer input (forward in history)

Cycling past the newest entry restores whatever you had typed before you
started navigating.  If the agent is working, navigating history also updates
the queued message.

### Conversation Management

#### Reset and New Sessions

The buffer header displays clickable action buttons:

```
  [Cancel]  [Reset]  [New Session]
```

`[Cancel]` only appears while the agent is working.

- **`[Cancel]`** — cancels the running query (equivalent to `c`).  The
  conversation history is preserved; the queued message (if any) stays in the
  input area for editing.
- **`[Reset]`** — hard-resets the current conversation: clears all messages
  *and* restarts the backend process, giving you a blank slate.  Prompts for
  confirmation.  Also available as `W` in the `?` menu or the `/reset` slash
  command.
- **`[New Session]`** — opens a new, independent Claude buffer for the same
  directory without touching the current conversation.  Also available as `N` in
  the `?` menu or the `/new` slash command.  The new session appears in the
  Agent sidebar alongside the original.

#### Forking a Conversation

Each `▶ You` message heading has a `[fork]` button.  Clicking it (or pressing
`RET` on it) opens a new buffer pre-loaded with the conversation history *up to
and including* that message, then starts a fresh backend process.  This lets you
explore an alternative line of reasoning without losing the original thread.

You can also fork via `M-x claude-code-fork` when point is on a `▶ You`
heading.  Forked sessions appear in the Agent sidebar labelled `(fork)`.

### Message Queuing

If you press `RET` while the agent is still working, the message is **queued**
rather than sent immediately.  The text stays in the input area (edit it if
needed) and the spinner shows the queued text:

```
⠹ Working… (12s · ↓ 340 chars · thought 8s)
⏳ queued: your next message here
```

When the agent finishes, the queued message is sent automatically.  Press `c`
(cancel) to discard the queue — the text remains in the input area for editing.

### Thinking Spinner

The spinner now shows live stats while the agent works:

```
⠹ Working… (1m 45s · ↓ 558 chars · thought 88s)
```

- **elapsed** — wall-clock time since the query started
- **↓ N chars** — characters streamed so far (rough output size)
- **thought Xs** — time spent in thinking blocks

### Agent Sidebar

Press `a` in the Claude buffer (or `M-x claude-code-agents-toggle`) to open a
treemacs-style side panel showing all active sessions and their subagents:

```
Claude Agents
──────────────────────────────────────

▾ ⠹ ~/projects/myapp        [working]
   Explain the auth module
   ⎘ *Claude: ~/projects/myapp*
  ├─ ⠹ Search codebase      [working]
  │    ⎘ *Claude Task: Search codebase*
  │    ⚙ Grep
  ├─ ✓ Read config files    [completed]
  │    Found 3 config files
  └─ ⠹ Analyze patterns     [working]

▸ ● ~/other-project          [ready]
   ⎘ *Claude: ~/other-project*
```

- **Root nodes** are sessions (one per project directory)
- **Child nodes** are subagents spawned by the main agent
- **▾ / ▸** fold indicator — `TAB` collapses/expands session nodes
- **`⎘ buffer-name`** shows the Emacs buffer each agent lives in
- `RET` / click on a session node → jump to its conversation buffer
- `RET` / click on a task node → jump to its dedicated task progress buffer
- `k` kill agent, `g` refresh, `q` close

The sidebar auto-updates as agents start, make progress, and complete.
Sessions resume their conversation context across `claude-code-reload`.

#### Emacs-Native Subagents

When `claude-code-enable-native-subagents` is non-nil (the default), the
system prompt teaches Claude how to spawn **Emacs-native subagents** — full
`claude-code-mode` session buffers that run concurrently and are visible in
the `*Claude Agents*` sidebar.

Claude spawns them via `emacsclient` in the Bash tool:

```sh
emacsclient --eval '(claude-code--spawn-subagent "PARENT-BUF" "Description" "Prompt")'
```

The call:
1. Creates a new `claude-code-mode` buffer for the subagent.
2. Registers it as a task child of the parent session in the agent registry.
3. Pre-queues the prompt so the backend sends it the moment it is ready.
4. Pushes an info message into the parent session when the subagent completes.
5. Returns a `"emacs-task-…"` task ID that emacsclient echoes back.

This differs from the SDK's built-in sidechain subagents: each Emacs-native
subagent is a **first-class, inspectable Emacs buffer** — you can click into
it in the sidebar, read its conversation, and even interact with it directly.

### Git Graph

`M-x claude-code-git-graph` opens a read-only buffer showing a visual summary
of a git repository's history — useful for getting a quick sense of a project
before diving in:

```
  ██ myapp  ·  branch: main  ·  1 234 commits total

  Contribution Activity — last 52 weeks

        Jan         Feb         Mar     …
  Su  ░░░░░░██░██░░░███░░░░░░░░░░██████
  Mo  ░░░░░░██░██░░░███░░░░░░░░░░██████
  Tu  ░░░░░░██░██░░░███░░░░░░░░░░██████
  …

  Less ░▒▓█ More

  Top Contributors

  Alice Johnson          ████████████████████ 412
  Bob Smith              ██████████░░░░░░░░░░ 201
  …

  Recent Commits

  a1b2c3d  2 hours ago   (main) Fix login redirect — Alice Johnson
  d4e5f6a  yesterday     Add password reset flow — Bob Smith
  …
```

The buffer shows:

- **Contribution heatmap** — 52-week commit activity grid (Sun–Sat rows,
  one column per week), colour-coded by commit density
- **Top contributors** — bar chart of the top 10 authors by all-time commit count
- **Recent commits** — last 20 commits with short SHA, relative date, branch/tag
  refs, message, and author

| Key | Action |
|-----|--------|
| `g` | Refresh |
| `q` | Close |
| `n` / `p` | Move down / up |

You can call it from anywhere — it is not tied to a Claude session:

```
M-x claude-code-git-graph      ;; prompts for repo directory
```

## Configuration

```elisp
;; Global defaults (nil means use the SDK/API default)
(setq claude-code-defaults
      '((model            . nil)
        (effort           . nil)
        (permission-mode  . "bypassPermissions")
        (max-turns        . 50)
        (max-budget-usd   . nil)
        (allowed-tools    . ("Read" "Write" "Edit" "Bash" "Glob" "Grep"
                             "WebSearch" "WebFetch"))
        (betas            . nil)))

;; Per-project overrides
(setq claude-code-project-config
      '(("~/work/prod-app" . ((model . "claude-opus-4-6")
                               (effort . "high")
                               (permission-mode . "acceptEdits")))
        ("~/scratch"        . ((model . "claude-haiku-4-5")
                               (effort . "low")))))

;; Org file with notes included in every system prompt
(setq claude-code-notes-file "~/org/claude-notes.org")

;; Python command (default: "uv")
(setq claude-code-python-command "uv")

;; Show thinking/tool blocks expanded by default
(setq claude-code-show-thinking nil)
(setq claude-code-show-tool-details nil)

;; Agent sidebar width (default: 40)
(setq claude-code-agents-sidebar-width 40)

;; Emacs-native subagent spawning (default: t)
;; When non-nil, Claude is instructed on how to spawn subagents as full
;; Emacs session buffers (visible in the *Claude Agents* sidebar) instead
;; of relying on the opaque CLI sidechain mechanism.
(setq claude-code-enable-native-subagents t)
```

### Session Overrides

Use the transient menu (`?`) to change model, effort, or permission mode
for the current session without modifying your config.

### Org-Roam Integration

If you use [org-roam](https://www.orgroam.com/), claude-code.el stores two
kinds of context as org-roam notes and merges them into every system prompt:

| Kind | Scope | What it's for |
|------|-------|---------------|
| **Skills** | Global | Reusable instructions/preferences included in *every* session |
| **Project notes** | Per-directory | Context specific to one project (architecture, conventions, etc.) |

Both are plain org-roam notes, live in your `org-roam-directory`, and take
effect on the next prompt — no restart needed.

#### Skills

```elisp
;; Customization (all optional — defaults work out of the box)
(setq claude-code-org-roam-skills-hub-title "Claude Code Skills") ;; hub note title
(setq claude-code-org-roam-skill-tag "claude_skill")              ;; filetag on skill notes
(setq claude-code-org-roam-skill-property "CLAUDE_SKILL")         ;; property identifying skills
```

**Commands:**

| Command | Key | Description |
|---------|-----|-------------|
| `claude-code-org-roam-add-skill` | `A` (in `?` menu) | Create a new skill note and link it to the hub |
| `claude-code-org-roam-visit-skills-hub` | `N` (in `?` menu) | Open the skills hub index note |

Each skill is an org-roam note with the `CLAUDE_SKILL` property set to `t`.
The hub note is created automatically on first use and indexes all skills.
At prompt time, all skill bodies are concatenated into the system prompt.

**Example workflow:**

```
M-x claude-code-org-roam-add-skill RET
  Skill name: emacs-ui-testing
  Skill description: When testing UI changes, use emacsclient to ...
```

#### Project Notes & TODOs

Per-project context and task lists are each stored as an org-roam note.  Two
separate notes are supported:

| Note type | Property | Command | Key |
|-----------|----------|---------|-----|
| Context/architecture | `CLAUDE_PROJECT_DIR` | `claude-code-open-dir-notes` | `d` |
| TODO list | `CLAUDE_PROJECT_TODOS` | `claude-code-open-dir-todos` | `o` |

Both are included in the system prompt when Claude runs in the matched
directory, giving the agent awareness of project context and current tasks.
The agent can read and update the TODO org file directly via `emacsclient`.

Per-project context is stored as an org-roam note identified by the
`CLAUDE_PROJECT_DIR` property set to the expanded project path.  The note
body is injected into the system prompt whenever Claude runs in that
directory (or any subdirectory — matching is longest-prefix, so one note
for `~/org` also covers `~/org/roam` and deeper paths).  Notes live in
your `org-roam-directory` — nothing is written into the project repository
itself.

```elisp
;; Customization (optional)
(setq claude-code-org-roam-project-dir-property   "CLAUDE_PROJECT_DIR")
(setq claude-code-org-roam-project-todos-property "CLAUDE_PROJECT_TODOS")
```

**Commands:**

| Command | Key | Description |
|---------|-----|-------------|
| `claude-code-open-dir-notes` | `d` / `d` in `?` menu | Open or create the project-context note for the current session directory |
| `claude-code-open-dir-todos` | `o` / `o` in `?` menu | Open or create the project TODO list for the current session directory |

**Example workflow:**

```
;; In a Claude buffer for ~/work/myapp, press d (or ? → d)
;; → Creates an org-roam note titled "Project context: ~/work/myapp"
;; → Opens it for editing
;; → Its body is included in every prompt sent from that directory or below
```

The note is pre-populated with a starter template on first creation.  Edit
it freely — add architecture notes, conventions, links to key files, or
anything else that helps Claude understand the project.

## Troubleshooting

### Backend crashes / stops responding

If Claude stops responding to prompts, the backend process likely died.
You'll see a message in the buffer:

```
  ℹ Backend process exited: finished.  Press R to restart.
```

**Press `R`** (or `M-x claude-code-restart`) to restart the backend while
keeping your conversation history.  The next prompt you send will start a
fresh Agent SDK session.

If you didn't notice the crash and just see prompts being silently ignored,
`claude-code--send-json` will auto-restart the backend on the next send
attempt.  You can also use `M-x claude-code-inspect` to check the session
state — look for `process: nil` or `status: stopped`.

### Common causes

- **Stale session resume**: if the backend process restarts (or you reload
  the package), the old session ID becomes invalid.  The backend now retries
  without `resume` automatically when this happens.
- **`cwd` is nil**: can happen after a manual `load-file` reload (which
  resets buffer-local variables).  `claude-code-restart` recovers `cwd`
  from `project-current` or `default-directory`.  Prefer `M-x
  claude-code-reload` which preserves all state.

## Buffer Layout

```
Claude Code  [working]  ~/projects/myapp
  default model  bypassPermissions
──────────────────────────────────────────────────────────────────────────
  [Reset]  [New Session]   (+ [Cancel] while working)
▶ You  [fork]
  Explain the auth module

◀ Assistant
  ◆ Thinking                                              [TAB to expand]
  ⚙ Read src/auth.py                                      [TAB to expand]
  ⚙ Grep pattern=verify_token                              [TAB to expand]

  The authentication module handles JWT verification...

  ✓ Done | 3 turns | $0.0142 | 4.2s
──────────────────────────────────────────────────────────────────────────

  ⠹ Thinking...

──────────────────────────────────────────────────────────────────────────
> your prompt here
```

- **Header buttons** — `[Cancel]` (while working), `[Reset]`, and `[New Session]` are clickable; click or press `RET` to activate
- **`[fork]` button** — appears on every `▶ You` heading; forks the conversation at that message
- **Thinking blocks** — collapsed by default, toggle with `TAB`
- **Tool-use blocks** — collapsed, heading shows tool name + summary (file path, grep pattern, etc.)
- **Streaming** — text appears token-by-token; thinking spinner animates via overlay
- **Links** — URLs open in browser; absolute file paths open in Emacs

## Protocol

Emacs and the Python backend communicate over stdin/stdout using one JSON object per line.

### Commands (Emacs → Python)

| Command | Fields | Description |
|---------|--------|-------------|
| `query` | `prompt`, `cwd`, `allowed_tools`, `system_prompt`, `max_turns`, `permission_mode`, `model`, `effort`, `max_budget_usd`, `betas`, `resume` | Send a prompt to the agent |
| `cancel` | — | Cancel the running query |
| `quit` | — | Shut down the backend |

### Events (Python → Emacs)

| Event | Key fields | Description |
|-------|------------|-------------|
| `status` | `status`: ready/working/cancelled/error | Backend lifecycle |
| `system` | `subtype`, `data` | SDK system messages (e.g. session init with `session_id`) |
| `assistant` | `content[]`, `model` | Complete assistant turn with content blocks |
| `result` | `result`, `stop_reason`, `is_error`, `num_turns`, `total_cost_usd`, `duration_ms`, `session_id` | Final query result |
| `error` | `message`, `detail` | Error with optional traceback |
| `content_block_start` | `index`, `block_type` | A streaming content block begins |
| `text_delta` | `index`, `text` | Incremental text token |
| `thinking_delta` | `index`, `thinking` | Incremental thinking token |
| `input_json_delta` | `index`, `partial_json` | Incremental tool input JSON |
| `content_block_stop` | `index` | A streaming content block ends |
| `task_started` | `task_id`, `description` | Subagent task began |
| `task_progress` | `task_id`, `description`, `last_tool_name` | Subagent progress |
| `task_notification` | `task_id`, `status`, `summary` | Subagent completed/failed |
| `rate_limit` | `message` | Rate limit warning |

Content blocks within `assistant` events:

| Block type | Fields | Description |
|------------|--------|-------------|
| `text` | `text` | Assistant text output |
| `thinking` | `thinking` | Internal reasoning (collapsible in UI) |
| `tool_use` | `id`, `name`, `input` | Tool invocation (collapsible, shows summary) |
| `tool_result` | `tool_use_id`, `content`, `is_error` | Tool execution result |

All protocol types are defined as Python dataclasses in `python/claude_code_backend.py` and enforced by `mypy --strict`.

## Debugging & Introspection

### `M-x claude-code-inspect`

Opens a read-only buffer showing session state at a glance:

```
claude-code session state
══════════════════════════════════════
  buffer:     *Claude: ~/my-project/*
  cwd:        ~/my-project/
  status:     ready
  session-id: 80549b18-...
  process:    run
  messages:   42 total, 8 user, 4 results
  cost:       $0.1234

Last query command keys: (resume system_prompt max_turns ...)
Has system prompt: yes
Has resume: yes

User prompts (newest first):
  - fix the login bug
  - what does auth.py do
```

### Buffer-local variables

Every Claude buffer exposes these for programmatic access (e.g. via `emacsclient`):

| Variable | Description |
|----------|-------------|
| `claude-code--messages` | All messages (newest first). Each is an alist with `type` key. |
| `claude-code--session-id` | Current Agent SDK session ID (used for `resume`). |
| `claude-code--status` | Symbol: `starting`, `ready`, `working`, `error`, `stopped`. |
| `claude-code--cwd` | Working directory for this session. |
| `claude-code--last-query-cmd` | The last JSON command alist sent to the backend. |

Example via emacsclient:

```sh
# Check session state
emacsclient --eval '(with-current-buffer "*Claude: ~/my-project/*"
  (format "status=%s session=%s msgs=%d"
          claude-code--status claude-code--session-id
          (length claude-code--messages)))'

# Get last 5 user prompts
emacsclient --eval '(with-current-buffer "*Claude: ~/my-project/*"
  (mapcar (lambda (m) (alist-get (quote prompt) m))
          (seq-take (seq-filter
                     (lambda (m) (equal "user" (alist-get (quote type) m)))
                     claude-code--messages) 5)))'

# Check if resume was sent in last query
emacsclient --eval '(with-current-buffer "*Claude: ~/my-project/*"
  (alist-get (quote resume) claude-code--last-query-cmd))'
```

### Conversation persistence

Each query sends the `resume` field with the session ID from the previous
response.  This tells the Agent SDK to continue the same conversation,
preserving full history on the server side.  If Claude seems to "forget"
previous turns, check `claude-code--last-query-cmd` to verify `resume` is
present.

## Development

A convenience script `emacs-batch.sh` launches Emacs in `--batch` mode with all
dependencies resolved from the `Cask` file via `dev/resolve-deps.el`:

```bash
# Byte-compile
./emacs-batch.sh -f batch-byte-compile claude-code.el

# Evaluate a snippet
./emacs-batch.sh --eval '(progn (require (quote claude-code)) (message "ok"))'

# Run all checks (uses emacs-batch.sh internally)
make all                   # checkdoc + byte-compile + ERT tests + mypy --strict
make test                  # just the ERT tests
```

Inside Emacs:

```
M-x claude-code-reload     ;; reload source, keep conversation (preserves live backend)
M-x claude-code-sync       ;; force uv sync after pulling new deps
M-x claude-code-inspect    ;; show session state for debugging
```

## License

Apache License 2.0
