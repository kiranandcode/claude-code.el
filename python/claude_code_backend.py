#!/usr/bin/env python3
"""Claude Code SDK backend for Emacs integration.

Communicates with Emacs via JSON-lines over stdin/stdout.
Uses the Claude Agent SDK to run an AI agent with tool access.
"""

from __future__ import annotations

import asyncio
import json
import sys
import traceback
from dataclasses import asdict, dataclass
from typing import Any, Literal, cast

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    RateLimitEvent,
    ResultMessage,
    StreamEvent,
    SystemMessage,
    TaskNotificationMessage,
    TaskProgressMessage,
    TaskStartedMessage,
    TextBlock,
    ThinkingBlock,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
    query,
)

# ---------------------------------------------------------------------------
# Protocol types: Emacs -> Python (commands)
# ---------------------------------------------------------------------------


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


@dataclass
class CancelCommand:
    """Request to cancel the current query."""

    type: Literal["cancel"]


@dataclass
class QuitCommand:
    """Request to shut down the backend."""

    type: Literal["quit"]


type Command = QueryCommand | CancelCommand | QuitCommand

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
                task_id=task_id, status=status, summary=summary
            )

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


def parse_command(raw: dict[str, Any]) -> Command:
    """Parse a raw JSON dict into a typed Command."""
    cmd_type = raw.get("type")
    match cmd_type:
        case "query":
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
            )
        case "cancel":
            return CancelCommand(type="cancel")
        case "quit":
            return QuitCommand(type="quit")
        case _:
            raise ValueError(f"Unknown command type: {cmd_type}")


def build_options(cmd: QueryCommand) -> ClaudeAgentOptions:
    """Build ClaudeAgentOptions from a QueryCommand."""
    return ClaudeAgentOptions(
        cwd=cmd.cwd,
        allowed_tools=cmd.allowed_tools or DEFAULT_TOOLS,
        permission_mode=cmd.permission_mode,
        max_turns=cmd.max_turns,
        max_budget_usd=cmd.max_budget_usd,
        system_prompt=cmd.system_prompt,
        model=cmd.model,
        effort=cmd.effort,
        betas=cast(list[Literal["context-1m-2025-08-07"]], cmd.betas or []),
        resume=cmd.resume,
    )


# ---------------------------------------------------------------------------
# Query handler
# ---------------------------------------------------------------------------


async def handle_query(cmd: QueryCommand) -> None:
    """Process a query command from Emacs."""
    options = build_options(cmd)

    emit(StatusEvent(status="working"))

    try:
        async for message in query(prompt=cmd.prompt, options=options):
            event = convert_message(message)
            if event is not None:
                emit(event)
    except asyncio.CancelledError:
        emit(StatusEvent(status="cancelled"))
        return
    except Exception as e:
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

        except Exception as e:
            emit(ErrorEvent(message=f"Main loop error: {e}"))


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
