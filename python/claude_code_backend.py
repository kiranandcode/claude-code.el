#!/usr/bin/env python3
"""Claude Code SDK backend for Emacs integration.

Communicates with Emacs via JSON-lines over stdin/stdout.
Uses the Claude Agent SDK to run an AI agent with tool access.
"""

from __future__ import annotations

import anyio
import asyncio
import json
import os
import shutil
import sys
import traceback
from dataclasses import asdict, dataclass
from typing import Any, Literal, cast

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    McpSdkServerConfig,
    PermissionResultAllow,
    PermissionResultDeny,
    RateLimitEvent,
    ResultMessage,
    StreamEvent,
    SystemMessage,
    TaskNotificationMessage,
    TaskProgressMessage,
    TaskStartedMessage,
    TextBlock,
    ThinkingBlock,
    ToolPermissionContext,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
    create_sdk_mcp_server,
    query,
    tool,
)

# ---------------------------------------------------------------------------
# Protocol types: Emacs -> Python (commands)
# ---------------------------------------------------------------------------


@dataclass
class ImageAttachment:
    """Base64-encoded image attached to a prompt."""

    data: str
    media_type: str
    name: str


@dataclass
class QueryCommand:
    """Request to send a prompt to the agent."""

    type: Literal["query"]
    prompt: str
    cwd: str | None = None
    allowed_tools: list[str] | None = None
    system_prompt: str | None = None
    max_turns: int | None = None
    permission_mode: Literal[
        "default", "acceptEdits", "plan", "bypassPermissions"
    ] | None = None
    model: str | None = None
    effort: Literal["low", "medium", "high", "max"] | None = None
    max_budget_usd: float | None = None
    betas: list[str] | None = None
    resume: str | None = None
    images: list[ImageAttachment] | None = None
    ask_permission_tools: list[str] | None = None


@dataclass
class CancelCommand:
    """Request to cancel the current query."""

    type: Literal["cancel"]


@dataclass
class QuitCommand:
    """Request to shut down the backend."""

    type: Literal["quit"]


@dataclass
class PermissionResponseCommand:
    """User's approval decision for a pending tool-call permission request."""

    type: Literal["permission_response"]
    request_id: str
    decision: Literal["allow", "deny", "always_allow"]


type Command = QueryCommand | CancelCommand | QuitCommand | PermissionResponseCommand

# ---------------------------------------------------------------------------
# Protocol types: Python -> Emacs (events)
# ---------------------------------------------------------------------------


@dataclass
class StatusEvent:
    """Backend status change."""

    type: Literal["status"] = "status"
    status: Literal["ready", "working", "cancelled", "error"] = "ready"


@dataclass
class ErrorEvent:
    """An error occurred."""

    type: Literal["error"] = "error"
    message: str = ""
    detail: str | None = None


@dataclass
class SystemEvent:
    """System-level message from the SDK (e.g. session init)."""

    type: Literal["system"] = "system"
    subtype: str = ""
    data: dict[str, Any] | None = None


@dataclass
class TextContentBlock:
    """A text content block within an assistant message."""

    type: Literal["text"] = "text"
    text: str = ""


@dataclass
class ThinkingContentBlock:
    """A thinking content block within an assistant message."""

    type: Literal["thinking"] = "thinking"
    thinking: str = ""


@dataclass
class ToolUseContentBlock:
    """A tool use content block within an assistant message."""

    type: Literal["tool_use"] = "tool_use"
    id: str = ""
    name: str = ""
    input: dict[str, Any] | None = None


@dataclass
class ToolResultContentBlock:
    """A tool result content block within an assistant message."""

    type: Literal["tool_result"] = "tool_result"
    tool_use_id: str = ""
    content: str | list[dict[str, Any]] | None = None
    is_error: bool | None = None


type EmitContentBlock = (
    TextContentBlock
    | ThinkingContentBlock
    | ToolUseContentBlock
    | ToolResultContentBlock
)


@dataclass
class AssistantEvent:
    """An assistant message containing content blocks."""

    type: Literal["assistant"] = "assistant"
    content: list[EmitContentBlock] | None = None
    model: str | None = None


@dataclass
class ResultEvent:
    """The final result of a query."""

    type: Literal["result"] = "result"
    result: str | None = None
    stop_reason: str | None = None
    is_error: bool = False
    num_turns: int = 0
    total_cost_usd: float | None = None
    duration_ms: int = 0
    session_id: str = ""


@dataclass
class TaskProgressEvent:
    """Progress update from a subagent task."""

    type: Literal["task_progress"] = "task_progress"
    task_id: str = ""
    description: str = ""
    last_tool_name: str | None = None


@dataclass
class TaskStartedEvent:
    """A subagent task has started."""

    type: Literal["task_started"] = "task_started"
    task_id: str = ""
    description: str = ""


@dataclass
class TaskNotificationEvent:
    """A subagent task has completed."""

    type: Literal["task_notification"] = "task_notification"
    task_id: str = ""
    status: Literal["completed", "failed", "stopped"] = "completed"
    summary: str = ""


@dataclass
class ContentBlockStartEvent:
    """A new content block has started streaming."""

    type: Literal["content_block_start"] = "content_block_start"
    index: int = 0
    block_type: str = ""  # "text", "thinking", "tool_use"


@dataclass
class TextDeltaEvent:
    """Incremental text token from a streaming response."""

    type: Literal["text_delta"] = "text_delta"
    index: int = 0
    text: str = ""


@dataclass
class ThinkingDeltaEvent:
    """Incremental thinking token from a streaming response."""

    type: Literal["thinking_delta"] = "thinking_delta"
    index: int = 0
    thinking: str = ""


@dataclass
class InputJsonDeltaEvent:
    """Incremental tool input JSON from a streaming response."""

    type: Literal["input_json_delta"] = "input_json_delta"
    index: int = 0
    partial_json: str = ""


@dataclass
class ContentBlockStopEvent:
    """A content block has finished streaming."""

    type: Literal["content_block_stop"] = "content_block_stop"
    index: int = 0


@dataclass
class RateLimitInfoEvent:
    """Rate limit information from the API."""

    type: Literal["rate_limit"] = "rate_limit"
    message: str = ""


@dataclass
class PermissionRequestEvent:
    """Ask Emacs whether Claude may use a particular tool.

    The backend emits this and then blocks until Emacs sends a
    PermissionResponseCommand with the matching request_id.
    """

    type: Literal["permission_request"] = "permission_request"
    request_id: str = ""
    tool_name: str = ""
    tool_input: dict[str, Any] | None = None


type EmitEvent = (
    StatusEvent
    | ErrorEvent
    | SystemEvent
    | AssistantEvent
    | ResultEvent
    | TaskProgressEvent
    | TaskStartedEvent
    | TaskNotificationEvent
    | RateLimitInfoEvent
    | ContentBlockStartEvent
    | TextDeltaEvent
    | ThinkingDeltaEvent
    | InputJsonDeltaEvent
    | ContentBlockStopEvent
    | PermissionRequestEvent
)

# ---------------------------------------------------------------------------
# SDK type aliases
# ---------------------------------------------------------------------------

type SDKMessage = (
    UserMessage
    | AssistantMessage
    | SystemMessage
    | ResultMessage
    | StreamEvent
    | RateLimitEvent
)

type SDKContentBlock = TextBlock | ThinkingBlock | ToolUseBlock | ToolResultBlock

# ---------------------------------------------------------------------------
# Emit / serialize
# ---------------------------------------------------------------------------


def emit(event: EmitEvent) -> None:
    """Write a typed event to stdout for Emacs to consume."""
    try:
        sys.stdout.write(json.dumps(asdict(event), default=str) + "\n")
        sys.stdout.flush()
    except BrokenPipeError:
        sys.exit(0)


def convert_content_block(block: SDKContentBlock) -> EmitContentBlock:
    """Convert an SDK content block to a protocol content block."""
    match block:
        case TextBlock(text=text):
            return TextContentBlock(text=text)
        case ThinkingBlock(thinking=thinking):
            return ThinkingContentBlock(thinking=thinking)
        case ToolUseBlock(id=id, name=name, input=input):
            return ToolUseContentBlock(id=id, name=name, input=input)
        case ToolResultBlock(
            tool_use_id=tool_use_id, content=content, is_error=is_error
        ):
            return ToolResultContentBlock(
                tool_use_id=tool_use_id, content=content, is_error=is_error
            )


def convert_stream_event(event: dict[str, Any]) -> EmitEvent | None:
    """Convert a raw Anthropic SSE event dict to a protocol event."""
    event_type: str = event.get("type", "")

    match event_type:
        case "content_block_start":
            block: dict[str, Any] = event.get("content_block", {})
            return ContentBlockStartEvent(
                index=event.get("index", 0),
                block_type=block.get("type", ""),
            )

        case "content_block_delta":
            delta: dict[str, Any] = event.get("delta", {})
            delta_type: str = delta.get("type", "")
            index: int = event.get("index", 0)

            match delta_type:
                case "text_delta":
                    return TextDeltaEvent(index=index, text=delta.get("text", ""))
                case "thinking_delta":
                    return ThinkingDeltaEvent(
                        index=index, thinking=delta.get("thinking", "")
                    )
                case "input_json_delta":
                    return InputJsonDeltaEvent(
                        index=index, partial_json=delta.get("partial_json", "")
                    )
                case _:
                    return None

        case "content_block_stop":
            return ContentBlockStopEvent(index=event.get("index", 0))

        case _:
            # message_start, message_delta, message_stop, etc. — skip
            return None


def convert_message(message: SDKMessage) -> EmitEvent | None:
    """Convert an SDK message to a protocol event, or None to skip."""
    match message:
        # Task* subclasses of SystemMessage must be matched before
        # the generic SystemMessage arm, otherwise isinstance-based
        # pattern matching resolves them as plain SystemMessage.
        case TaskProgressMessage(
            task_id=task_id,
            description=description,
            last_tool_name=last_tool_name,
        ):
            return TaskProgressEvent(
                task_id=task_id,
                description=description,
                last_tool_name=last_tool_name,
            )

        case TaskStartedMessage(task_id=task_id, description=description):
            return TaskStartedEvent(task_id=task_id, description=description)

        case TaskNotificationMessage(
            task_id=task_id, status=status, summary=summary
        ):
            return TaskNotificationEvent(
                task_id=task_id, status=status, summary=summary,
            )

        case SystemMessage(subtype=subtype, data=data):
            return SystemEvent(subtype=subtype, data=data)

        case AssistantMessage(content=content, model=model):
            return AssistantEvent(
                content=[convert_content_block(b) for b in content],
                model=model,
            )

        case ResultMessage(
            result=result,
            stop_reason=stop_reason,
            is_error=is_error,
            num_turns=num_turns,
            total_cost_usd=total_cost_usd,
            duration_ms=duration_ms,
            session_id=session_id,
        ):
            return ResultEvent(
                result=result,
                stop_reason=stop_reason,
                is_error=is_error,
                num_turns=num_turns,
                total_cost_usd=total_cost_usd,
                duration_ms=duration_ms,
                session_id=session_id,
            )

        case UserMessage(content=content) if isinstance(content, list):
            # Tool-result messages arrive as UserMessage with a list of content
            # blocks (ToolResultBlock entries).  Emit them as an AssistantEvent
            # so the Elisp renderer can display "↳ Tool result" sections.
            result_blocks = [
                convert_content_block(b)
                for b in content
                if isinstance(b, ToolResultBlock)
            ]
            if result_blocks:
                return AssistantEvent(content=result_blocks)
            return None

        case UserMessage():
            return None

        case StreamEvent(event=event):
            return convert_stream_event(event)

        case RateLimitEvent():
            return RateLimitInfoEvent(message="Rate limited by API")

    return None


# ---------------------------------------------------------------------------
# Command parsing
# ---------------------------------------------------------------------------

DEFAULT_TOOLS: list[str] = [
    "Read", "Write", "Edit", "Bash", "Glob", "Grep",
]

# ---------------------------------------------------------------------------
# Emacs MCP tools — call emacsclient rather than the raw Bash tool so that
# all Emacs interaction is channelled through the official gateway.
# ---------------------------------------------------------------------------

# Resolved once at import time — emacsclient location cannot change during
# the process lifetime without a restart, so caching avoids repeated PATH
# traversal on every MCP tool invocation.
_EMACSCLIENT: str | None = shutil.which("emacsclient")


class EmacsclientNotFoundError(RuntimeError):
    """Raised when emacsclient is not on PATH.

    Distinguished from general RuntimeError so tool handlers can re-raise
    it rather than silently converting it to an is_error tool result.
    """

# Names of the Emacs tools added to `allowed_tools` automatically.
EMACS_TOOL_NAMES: list[str] = [
    "EvalEmacs",
    "EmacsRenderFrame",
    "EmacsGetMessages",
    "EmacsGetDebugInfo",
    "EmacsGetBuffer",
    "EmacsGetBufferRegion",
    "EmacsListBuffers",
    "EmacsSwitchBuffer",
    "EmacsGetPointInfo",
    "EmacsSearchForward",
    "EmacsSearchBackward",
    "EmacsGotoLine",
]


def _unescape_emacs_string(s: str) -> str:  # kept for reference; no longer called
    """Unescape an Emacs Lisp prin1-encoded string (without outer quotes).

    Replaced by the json-encode/json.loads round-trip in _run_emacsclient,
    which delegates encoding to Emacs's own json.el and decoding to Python's
    stdlib — eliminating a hand-rolled escape parser that missed edge cases
    such as \\xHH hex sequences.  Left here temporarily in case git-blame
    readers want the history; will be removed in a follow-up.
    """
    result: bytearray = bytearray()
    i = 0
    while i < len(s):
        ch = s[i]
        if ch == "\\" and i + 1 < len(s):
            nch = s[i + 1]
            if nch == "n":
                result.extend(b"\n"); i += 2
            elif nch == "t":
                result.extend(b"\t"); i += 2
            elif nch == "r":
                result.extend(b"\r"); i += 2
            elif nch == '"':
                result.extend(b'"'); i += 2
            elif nch == "\\":
                result.extend(b"\\"); i += 2
            elif nch == "a":
                result.extend(b"\x07"); i += 2
            elif nch == "b":
                result.extend(b"\x08"); i += 2
            elif nch in "01234567":
                # Octal escape: collect up to 3 octal digits
                j = i + 1
                while j < len(s) and j < i + 4 and s[j] in "01234567":
                    j += 1
                result.append(int(s[i + 1 : j], 8))
                i = j
            elif nch == "u" and i + 5 < len(s):
                # Unicode \uXXXX (4 hex digits)
                hex4 = s[i + 2 : i + 6]
                if all(c in "0123456789abcdefABCDEF" for c in hex4):
                    result.extend(chr(int(hex4, 16)).encode("utf-8"))
                    i += 6
                else:
                    result.extend(nch.encode("utf-8")); i += 2
            elif nch == "U" and i + 9 < len(s):
                # Unicode \UXXXXXXXX (8 hex digits)
                hex8 = s[i + 2 : i + 10]
                if all(c in "0123456789abcdefABCDEF" for c in hex8):
                    result.extend(chr(int(hex8, 16)).encode("utf-8"))
                    i += 10
                else:
                    result.extend(nch.encode("utf-8")); i += 2
            else:
                result.extend(nch.encode("utf-8")); i += 2
        else:
            result.extend(ch.encode("utf-8"))
            i += 1
    return result.decode("utf-8", errors="replace")


async def _run_emacsclient(elisp: str, timeout: float = 15.0) -> str:
    """Evaluate ELISP in the running Emacs and return the result as a string.

    Async so it never blocks the asyncio event loop.  Blocking the event
    loop (with subprocess.run) while the claude CLI is streaming tokens
    causes the OS pipe buffer to fill, stalling the CLI, which then times
    out and reports "Stream closed" for in-flight MCP tool calls.

    Output encoding: wraps ELISP in (json-encode ...) so Emacs itself
    produces well-formed JSON.  Python's json.loads then decodes it — no
    hand-rolled Lisp escape parsing needed.  Non-string return values
    (nil, t, numbers) are serialised back to their JSON representation so
    callers always receive a plain string.

    Raises RuntimeError on non-zero exit or if emacsclient is not found.
    """
    if _EMACSCLIENT is None:
        raise EmacsclientNotFoundError("emacsclient not found on PATH")
    # Wrap in json-encode so Emacs handles all escaping; princ writes the
    # raw JSON to stdout (no extra Lisp-level quoting on top).
    wrapped = f"(progn (require 'json) (princ (json-encode {elisp})))"
    proc = await asyncio.create_subprocess_exec(
        _EMACSCLIENT, "--eval", wrapped,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        # Use anyio.fail_after rather than asyncio.wait_for: the Claude SDK
        # runs the event loop under anyio, and mixing anyio cancel scopes with
        # asyncio.wait_for's internal cancel scope causes:
        #   RuntimeError: Attempted to exit cancel scope in a different task
        # anyio.fail_after is cancel-scope-safe in this context.
        with anyio.fail_after(timeout):
            stdout_bytes, stderr_bytes = await proc.communicate()
    except TimeoutError:
        proc.kill()
        await proc.communicate()
        raise RuntimeError(f"emacsclient timed out after {timeout:.0f}s")
    if proc.returncode != 0:
        stderr = stderr_bytes.decode("utf-8", errors="replace").strip()
        raise RuntimeError(
            f"emacsclient exited {proc.returncode}"
            + (f": {stderr}" if stderr else "")
        )
    raw = stdout_bytes.decode("utf-8", errors="replace").strip()
    parsed = json.loads(raw)
    # All callers expect a string; for non-string values (nil → null,
    # t → true, numbers, lists) serialise back to a terse representation.
    return parsed if isinstance(parsed, str) else json.dumps(parsed)


def _tool_result(text: str, is_error: bool = False) -> dict[str, Any]:
    """Build a standard MCP tool result dict."""
    return {
        "content": [{"type": "text", "text": text}],
        **({"is_error": True} if is_error else {}),
    }


# ── EvalEmacs ─────────────────────────────────────────────────────────────

@tool(
    "EvalEmacs",
    description=(
        "Evaluate an Emacs Lisp expression in the running Emacs instance via "
        "emacsclient.  Prefer this over `Bash(emacsclient --eval ...)` because "
        "it validates parentheses before sending, surfaces Emacs errors clearly, "
        "and keeps all Emacs interaction in one auditable channel.\n\n"
        "Returns a string starting with 'ok: ' on success or 'error: ' on failure."
    ),
    input_schema={
        "type": "object",
        "properties": {
            "code": {
                "type": "string",
                "description": "Emacs Lisp expression(s) to evaluate.",
            },
        },
        "required": ["code"],
    },
)
async def _emacs_eval(args: dict[str, Any]) -> dict[str, Any]:
    code = args.get("code", "")
    try:
        # Delegate validation + eval to the Emacs-side helper
        elisp = f'(claude-code-tools-eval {json.dumps(code)})'
        out = await _run_emacsclient(elisp)
        is_error = out.startswith("error:")
        return _tool_result(out, is_error=is_error)
    except EmacsclientNotFoundError:
        raise
    except Exception as e:
        return _tool_result(f"error: emacsclient failed — {e}", is_error=True)


# ── EmacsRenderFrame ───────────────────────────────────────────────────────

@tool(
    "EmacsRenderFrame",
    description=(
        "Render the current Emacs frame as an ANSI-decorated ASCII snapshot. "
        "Shows all windows, their buffer contents, modelines, cursor positions, "
        "and clickable link citations.  Use this to 'see' what Emacs currently "
        "displays before navigating or editing."
    ),
    input_schema={
        "type": "object",
        "properties": {},
        "required": [],
    },
)
async def _emacs_render_frame(_args: dict[str, Any]) -> dict[str, Any]:
    try:
        out = await _run_emacsclient("(claude-code-tools-render-frame)", timeout=10)
        return _tool_result(out)
    except EmacsclientNotFoundError:
        raise
    except Exception as e:
        return _tool_result(f"error: {e}", is_error=True)


# ── EmacsGetMessages ───────────────────────────────────────────────────────

@tool(
    "EmacsGetMessages",
    description=(
        "Return the tail of the Emacs *Messages* buffer (default: last 3000 "
        "characters).  Use this to check for errors, warnings, or debug output "
        "after running elisp or triggering Emacs commands."
    ),
    input_schema={
        "type": "object",
        "properties": {
            "n_chars": {
                "type": "integer",
                "description": "How many characters to return from the end. Default 3000.",
            },
        },
        "required": [],
    },
)
async def _emacs_get_messages(args: dict[str, Any]) -> dict[str, Any]:
    n = args.get("n_chars", 3000)
    try:
        out = await _run_emacsclient(f"(claude-code-tools-get-messages {n})")
        return _tool_result(out)
    except EmacsclientNotFoundError:
        raise
    except Exception as e:
        return _tool_result(f"error: {e}", is_error=True)


# ── EmacsGetDebugInfo ──────────────────────────────────────────────────────

@tool(
    "EmacsGetDebugInfo",
    description=(
        "Return a combined debug snapshot: the *Backtrace* buffer (if present) "
        "followed by the last 2000 characters of *Messages*.  Call this whenever "
        "an operation fails unexpectedly to understand the root cause."
    ),
    input_schema={
        "type": "object",
        "properties": {},
        "required": [],
    },
)
async def _emacs_get_debug_info(_args: dict[str, Any]) -> dict[str, Any]:
    try:
        out = await _run_emacsclient("(claude-code-tools-get-debug-info)")
        return _tool_result(out)
    except EmacsclientNotFoundError:
        raise
    except Exception as e:
        return _tool_result(f"error: {e}", is_error=True)


# ── EmacsGetBuffer ─────────────────────────────────────────────────────────

@tool(
    "EmacsGetBuffer",
    description=(
        "Return the full text contents of an Emacs buffer by name.  "
        "Optionally include line numbers.  Use this to read file-visiting "
        "buffers or special buffers (e.g. *scratch*, *Claude: ...*) without "
        "going through the filesystem."
    ),
    input_schema={
        "type": "object",
        "properties": {
            "buffer_name": {
                "type": "string",
                "description": "Exact buffer name (e.g. 'myfile.el' or '*Messages*').",
            },
            "with_line_numbers": {
                "type": "boolean",
                "description": "If true, prefix every line with its 1-based line number.",
            },
        },
        "required": ["buffer_name"],
    },
)
async def _emacs_get_buffer(args: dict[str, Any]) -> dict[str, Any]:
    buf = args.get("buffer_name", "")
    nums = "t" if args.get("with_line_numbers") else "nil"
    try:
        out = await _run_emacsclient(
            f"(claude-code-tools-get-buffer {json.dumps(buf)} {nums})"
        )
        return _tool_result(out)
    except EmacsclientNotFoundError:
        raise
    except Exception as e:
        return _tool_result(f"error: {e}", is_error=True)


# ── EmacsGetBufferRegion ───────────────────────────────────────────────────

@tool(
    "EmacsGetBufferRegion",
    description=(
        "Return a range of lines from an Emacs buffer, with line numbers. "
        "More efficient than EmacsGetBuffer for inspecting a specific section."
    ),
    input_schema={
        "type": "object",
        "properties": {
            "buffer_name": {"type": "string", "description": "Buffer name."},
            "start_line":  {"type": "integer", "description": "First line (1-based)."},
            "end_line":    {"type": "integer", "description": "Last line (inclusive)."},
        },
        "required": ["buffer_name", "start_line", "end_line"],
    },
)
async def _emacs_get_buffer_region(args: dict[str, Any]) -> dict[str, Any]:
    buf   = args.get("buffer_name", "")
    start = args.get("start_line", 1)
    end   = args.get("end_line", 1)
    try:
        out = await _run_emacsclient(
            f"(claude-code-tools-get-buffer-region {json.dumps(buf)} {start} {end})"
        )
        return _tool_result(out)
    except EmacsclientNotFoundError:
        raise
    except Exception as e:
        return _tool_result(f"error: {e}", is_error=True)


# ── EmacsListBuffers ───────────────────────────────────────────────────────

@tool(
    "EmacsListBuffers",
    description=(
        "List all live Emacs buffers with their major mode and associated "
        "file or directory.  Use this to discover what buffers exist before "
        "calling EmacsGetBuffer or EmacsSwitchBuffer."
    ),
    input_schema={
        "type": "object",
        "properties": {},
        "required": [],
    },
)
async def _emacs_list_buffers(_args: dict[str, Any]) -> dict[str, Any]:
    try:
        out = await _run_emacsclient("(claude-code-tools-list-buffers)")
        return _tool_result(out)
    except EmacsclientNotFoundError:
        raise
    except Exception as e:
        return _tool_result(f"error: {e}", is_error=True)


# ── EmacsSwitchBuffer ──────────────────────────────────────────────────────

@tool(
    "EmacsSwitchBuffer",
    description=(
        "Switch to a named Emacs buffer.  If the buffer is visible in a window "
        "that window is selected; otherwise the current window's buffer is "
        "changed.  This moves point so subsequent EmacsSearchForward / "
        "EmacsGetPointInfo calls operate in the new buffer."
    ),
    input_schema={
        "type": "object",
        "properties": {
            "buffer_name": {"type": "string", "description": "Buffer to switch to."},
        },
        "required": ["buffer_name"],
    },
)
async def _emacs_switch_buffer(args: dict[str, Any]) -> dict[str, Any]:
    buf = args.get("buffer_name", "")
    try:
        out = await _run_emacsclient(f"(claude-code-tools-switch-buffer {json.dumps(buf)})")
        return _tool_result(out)
    except EmacsclientNotFoundError:
        raise
    except Exception as e:
        return _tool_result(f"error: {e}", is_error=True)


# ── EmacsGetPointInfo ──────────────────────────────────────────────────────

@tool(
    "EmacsGetPointInfo",
    description=(
        "Return a description of the current cursor (point) position in a "
        "buffer: line, column, character at point, and a short context snippet. "
        "Use after EmacsSearchForward / EmacsGotoLine to confirm position."
    ),
    input_schema={
        "type": "object",
        "properties": {
            "buffer_name": {
                "type": "string",
                "description": "Buffer to inspect.  Defaults to current buffer if omitted.",
            },
        },
        "required": [],
    },
)
async def _emacs_get_point_info(args: dict[str, Any]) -> dict[str, Any]:
    buf = args.get("buffer_name")
    elisp = (
        f"(claude-code-tools-get-point-info {json.dumps(buf)})"
        if buf
        else "(claude-code-tools-get-point-info)"
    )
    try:
        out = await _run_emacsclient(elisp)
        return _tool_result(out)
    except EmacsclientNotFoundError:
        raise
    except Exception as e:
        return _tool_result(f"error: {e}", is_error=True)


# ── EmacsSearchForward ─────────────────────────────────────────────────────

@tool(
    "EmacsSearchForward",
    description=(
        "Search forward in a buffer for a regexp pattern, moving point to the "
        "end of the match.  Returns the match location or 'not found'.  "
        "Combine with EmacsGetPointInfo or EmacsRenderFrame to confirm context."
    ),
    input_schema={
        "type": "object",
        "properties": {
            "pattern":     {"type": "string", "description": "Emacs regexp to search for."},
            "buffer_name": {"type": "string", "description": "Buffer to search in (default: current)."},
        },
        "required": ["pattern"],
    },
)
async def _emacs_search_forward(args: dict[str, Any]) -> dict[str, Any]:
    pat = args.get("pattern", "")
    buf = args.get("buffer_name")
    buf_arg = json.dumps(buf) if buf else "nil"
    try:
        out = await _run_emacsclient(
            f"(claude-code-tools-search-forward {json.dumps(pat)} {buf_arg} t)"
        )
        return _tool_result(out)
    except EmacsclientNotFoundError:
        raise
    except Exception as e:
        return _tool_result(f"error: {e}", is_error=True)


# ── EmacsSearchBackward ────────────────────────────────────────────────────

@tool(
    "EmacsSearchBackward",
    description=(
        "Search backward in a buffer for a regexp pattern, moving point to the "
        "beginning of the match.  Returns the match location or 'not found'."
    ),
    input_schema={
        "type": "object",
        "properties": {
            "pattern":     {"type": "string", "description": "Emacs regexp to search for."},
            "buffer_name": {"type": "string", "description": "Buffer to search in (default: current)."},
        },
        "required": ["pattern"],
    },
)
async def _emacs_search_backward(args: dict[str, Any]) -> dict[str, Any]:
    pat = args.get("pattern", "")
    buf = args.get("buffer_name")
    buf_arg = json.dumps(buf) if buf else "nil"
    try:
        out = await _run_emacsclient(
            f"(claude-code-tools-search-backward {json.dumps(pat)} {buf_arg} t)"
        )
        return _tool_result(out)
    except EmacsclientNotFoundError:
        raise
    except Exception as e:
        return _tool_result(f"error: {e}", is_error=True)


# ── EmacsGotoLine ──────────────────────────────────────────────────────────

@tool(
    "EmacsGotoLine",
    description=(
        "Move point to a specific line number in a buffer.  "
        "Returns a point-info snippet so you can verify the new position."
    ),
    input_schema={
        "type": "object",
        "properties": {
            "line_number":  {"type": "integer", "description": "1-based line number."},
            "buffer_name":  {"type": "string", "description": "Buffer to navigate (default: current)."},
        },
        "required": ["line_number"],
    },
)
async def _emacs_goto_line(args: dict[str, Any]) -> dict[str, Any]:
    line = args.get("line_number", 1)
    buf  = args.get("buffer_name")
    buf_arg = json.dumps(buf) if buf else "nil"
    try:
        out = await _run_emacsclient(
            f"(claude-code-tools-goto-line {line} {buf_arg})"
        )
        return _tool_result(out)
    except EmacsclientNotFoundError:
        raise
    except Exception as e:
        return _tool_result(f"error: {e}", is_error=True)


# ── Assemble MCP server ────────────────────────────────────────────────────

_EMACS_MCP_SERVER: McpSdkServerConfig = create_sdk_mcp_server(
    name="emacs",
    version="1.0.0",
    tools=[
        _emacs_eval,
        _emacs_render_frame,
        _emacs_get_messages,
        _emacs_get_debug_info,
        _emacs_get_buffer,
        _emacs_get_buffer_region,
        _emacs_list_buffers,
        _emacs_switch_buffer,
        _emacs_get_point_info,
        _emacs_search_forward,
        _emacs_search_backward,
        _emacs_goto_line,
    ],
)


# ---------------------------------------------------------------------------
# Permission callback state
# ---------------------------------------------------------------------------

# Maps request_id → asyncio.Event; set when Emacs responds.
_pending_permission_requests: dict[str, asyncio.Event] = {}
# Maps request_id → decision string ("allow" | "deny" | "always_allow").
_permission_decisions: dict[str, str] = {}

# Timeout (seconds) waiting for the user to approve/deny a permission prompt.
_PERMISSION_TIMEOUT = 60.0


def _make_can_use_tool_callback() -> (
    "Callable[[str, dict[str, Any], ToolPermissionContext], Awaitable[PermissionResultAllow | PermissionResultDeny]]"
):
    """Return a fresh can_use_tool callback with its own always-allowed set.

    The set is scoped to a single query (i.e. one user message and all its
    agentic turns).  "Always allow" means "don't ask again during this
    response" — it is NOT persisted across separate user messages so that
    the user retains full control each time they send a new prompt.
    """
    always_allowed: set[str] = set()

    async def _callback(
        tool_name: str,
        tool_input: dict[str, Any],
        _context: ToolPermissionContext,
    ) -> PermissionResultAllow | PermissionResultDeny:
        """Async callback that asks Emacs before executing each tool call.

        Emits a ``permission_request`` event and blocks until Emacs sends a
        ``permission_response`` command with the matching ``request_id``.
        Times out after ``_PERMISSION_TIMEOUT`` seconds and auto-denies.
        """
        if tool_name in always_allowed:
            return PermissionResultAllow()

        request_id = f"perm_{os.urandom(6).hex()}"
        event = asyncio.Event()
        _pending_permission_requests[request_id] = event

        emit(PermissionRequestEvent(
            request_id=request_id,
            tool_name=tool_name,
            tool_input=tool_input,
        ))

        try:
            await asyncio.wait_for(event.wait(), timeout=_PERMISSION_TIMEOUT)
        except asyncio.TimeoutError:
            _pending_permission_requests.pop(request_id, None)
            _permission_decisions.pop(request_id, None)
            return PermissionResultDeny(
                message=f"Permission request timed out after {_PERMISSION_TIMEOUT:.0f}s"
            )

        decision = _permission_decisions.pop(request_id, "deny")
        _pending_permission_requests.pop(request_id, None)

        if decision == "always_allow":
            always_allowed.add(tool_name)
            return PermissionResultAllow()
        elif decision == "allow":
            return PermissionResultAllow()
        else:
            return PermissionResultDeny(message="Denied by user")

    return _callback


def parse_command(raw: dict[str, Any]) -> Command:
    """Parse a raw JSON dict into a typed Command."""
    cmd_type = raw.get("type")
    match cmd_type:
        case "query":
            raw_images = raw.get("images")
            images = (
                [ImageAttachment(**img) for img in raw_images]
                if raw_images
                else None
            )
            return QueryCommand(
                type="query",
                prompt=raw["prompt"],
                cwd=raw.get("cwd"),
                allowed_tools=raw.get("allowed_tools"),
                system_prompt=raw.get("system_prompt"),
                max_turns=raw.get("max_turns"),
                permission_mode=raw.get("permission_mode"),
                model=raw.get("model"),
                effort=raw.get("effort"),
                max_budget_usd=raw.get("max_budget_usd"),
                betas=raw.get("betas"),
                resume=raw.get("resume"),
                images=images,
                ask_permission_tools=raw.get("ask_permission_tools"),
            )
        case "cancel":
            return CancelCommand(type="cancel")
        case "quit":
            return QuitCommand(type="quit")
        case "permission_response":
            return PermissionResponseCommand(
                type="permission_response",
                request_id=raw["request_id"],
                decision=raw["decision"],
            )
        case _:
            raise ValueError(f"Unknown command type: {cmd_type}")


async def _prompt_as_streaming(
    prompt: str, images: list[ImageAttachment] | None = None,
) -> Any:
    """Yield a single user message in the SDK streaming-mode format.

    The SDK's ``AsyncIterable`` streaming mode requires each dict to have:
      ``{"type": "user", "message": {"role": "user", "content": ...}}``
    (NOT plain ``{"role": "user", ...}``).  Used when ``can_use_tool``
    is registered, since the SDK only supports that callback in streaming
    mode.
    """
    if images:
        content: list[dict[str, Any]] = []
        for img in images:
            content.append({
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": img.media_type,
                    "data": img.data,
                },
            })
        content.append({"type": "text", "text": prompt})
    else:
        content = prompt  # type: ignore[assignment]
    yield {
        "type": "user",
        "message": {"role": "user", "content": content},
    }


def build_prompt(cmd: QueryCommand, *, streaming: bool = False) -> Any:
    """Return the prompt value to pass to ``query()``.

    Returns a plain string when *streaming* is False (the common case),
    or an async generator of SDK streaming-format dicts when True.
    Streaming mode is required when ``can_use_tool`` is registered.
    """
    if streaming or cmd.images:
        return _prompt_as_streaming(cmd.prompt, cmd.images or None)
    return cmd.prompt


def build_options(cmd: QueryCommand) -> ClaudeAgentOptions:
    """Build ClaudeAgentOptions from a QueryCommand.

    The Emacs MCP server is always attached so Claude has access to the
    EvalEmacs / EmacsRenderFrame / EmacsGet* family of tools without needing
    to route through the raw Bash tool.

    When ``ask_permission_tools`` is non-empty, the permission callback is
    registered and ``permission_mode`` is forced to ``"default"`` so the SDK
    actually sends ``can_use_tool`` events (bypassPermissions skips them).
    """
    base_tools = cmd.allowed_tools or DEFAULT_TOOLS
    # Always include Emacs tools alongside whatever the session configured.
    all_tools = list(base_tools) + [
        t for t in EMACS_TOOL_NAMES if t not in base_tools
    ]

    ask_tools = set(cmd.ask_permission_tools or [])
    use_permission_callback = bool(ask_tools)

    # Create a fresh callback with its own always-allowed set so that
    # "always allow" decisions are scoped to this query only.
    _raw_callback = _make_can_use_tool_callback() if use_permission_callback else None

    # Intercept only for the tools the user wants to confirm; let the SDK
    # run everything else without interruption.
    async def _filtered_callback(
        tool_name: str,
        tool_input: dict[str, Any],
        context: ToolPermissionContext,
    ) -> PermissionResultAllow | PermissionResultDeny:
        if tool_name in ask_tools and _raw_callback is not None:
            return await _raw_callback(tool_name, tool_input, context)
        return PermissionResultAllow()

    # bypassPermissions makes the SDK skip all can_use_tool calls entirely, so
    # override to "default" whenever the permission callback is active.
    effective_perm_mode = cmd.permission_mode
    if use_permission_callback and effective_perm_mode == "bypassPermissions":
        effective_perm_mode = "default"

    return ClaudeAgentOptions(
        cwd=cmd.cwd,
        allowed_tools=all_tools,
        mcp_servers={"emacs": _EMACS_MCP_SERVER},
        permission_mode=effective_perm_mode,
        max_turns=cmd.max_turns,
        max_budget_usd=cmd.max_budget_usd,
        system_prompt=cmd.system_prompt,
        model=cmd.model,
        effort=cmd.effort,
        betas=cast(list[Literal["context-1m-2025-08-07"]], cmd.betas or []),
        resume=cmd.resume,
        can_use_tool=_filtered_callback if use_permission_callback else None,
    )


# ---------------------------------------------------------------------------
# Query handler
# ---------------------------------------------------------------------------


async def handle_query(cmd: QueryCommand) -> None:
    """Process a query command from Emacs."""
    options = build_options(cmd)
    needs_streaming = options.can_use_tool is not None

    emit(StatusEvent(status="working"))

    try:
        async for message in query(
            prompt=build_prompt(cmd, streaming=needs_streaming),
            options=options,
        ):
            event = convert_message(message)
            if event is not None:
                emit(event)
    except asyncio.CancelledError:
        emit(StatusEvent(status="cancelled"))
        return
    except Exception as e:
        # If resume failed, retry without it (stale session ID).
        if cmd.resume is not None:
            emit(ErrorEvent(
                message=f"Resume failed, retrying fresh: {e}",
            ))
            cmd.resume = None
            options = build_options(cmd)
            needs_streaming = options.can_use_tool is not None
            try:
                async for message in query(
                    prompt=build_prompt(cmd, streaming=needs_streaming),
                    options=options,
                ):
                    event = convert_message(message)
                    if event is not None:
                        emit(event)
            except asyncio.CancelledError:
                emit(StatusEvent(status="cancelled"))
                return
            except Exception as e2:
                emit(ErrorEvent(message=str(e2), detail=traceback.format_exc()))
        else:
            emit(ErrorEvent(message=str(e), detail=traceback.format_exc()))

    emit(StatusEvent(status="ready"))


# ---------------------------------------------------------------------------
# Task management
# ---------------------------------------------------------------------------


async def cancel_task(task: asyncio.Task[None]) -> None:
    """Cancel a running task and wait for it to finish."""
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------


async def main() -> None:
    """Read JSON commands from stdin, dispatch them."""
    if _EMACSCLIENT is None:
        emit(ErrorEvent(
            message=(
                "emacsclient not found on PATH — Emacs MCP tools (EvalEmacs, "
                "EmacsRenderFrame, etc.) will not work.  Add the directory "
                "containing emacsclient to exec-path and PATH before starting "
                "claude-code, then restart with M-x claude-code-reset."
            )
        ))
    emit(StatusEvent(status="ready"))

    loop = asyncio.get_event_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)

    current_task: asyncio.Task[None] | None = None

    while True:
        try:
            line = await reader.readline()
            if not line:
                break

            text = line.decode("utf-8").strip()
            if not text:
                continue

            try:
                raw: dict[str, Any] = json.loads(text)
            except json.JSONDecodeError as e:
                emit(ErrorEvent(message=f"Invalid JSON: {e}"))
                continue

            try:
                command = parse_command(raw)
            except (ValueError, KeyError) as e:
                emit(ErrorEvent(message=f"Bad command: {e}"))
                continue

            match command:
                case QueryCommand() as qcmd:
                    if current_task is not None and not current_task.done():
                        await cancel_task(current_task)
                    current_task = asyncio.create_task(handle_query(qcmd))

                case CancelCommand():
                    if current_task is not None and not current_task.done():
                        await cancel_task(current_task)
                        emit(StatusEvent(status="ready"))

                case QuitCommand():
                    if current_task is not None and not current_task.done():
                        await cancel_task(current_task)
                    break

                case PermissionResponseCommand() as prsp:
                    # Unblock the _can_use_tool_callback awaiting this request.
                    ev = _pending_permission_requests.get(prsp.request_id)
                    if ev is not None:
                        _permission_decisions[prsp.request_id] = prsp.decision
                        ev.set()

        except Exception as e:
            emit(ErrorEvent(message=f"Main loop error: {e}"))


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
