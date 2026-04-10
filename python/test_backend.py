"""Tests for claude_code_backend.py."""
from __future__ import annotations

import asyncio
import json
from io import StringIO
from typing import Any
from unittest.mock import patch

import pytest

from claude_code_backend import (
    # Protocol types
    ImageAttachment,
    QueryCommand,
    CancelCommand,
    QuitCommand,
    PermissionResponseCommand,
    # Events
    StatusEvent,
    ErrorEvent,
    SystemEvent,
    TextContentBlock,
    ThinkingContentBlock,
    ToolUseContentBlock,
    ToolResultContentBlock,
    AssistantEvent,
    ResultEvent,
    TaskProgressEvent,
    TaskStartedEvent,
    TaskNotificationEvent,
    ContentBlockStartEvent,
    TextDeltaEvent,
    ThinkingDeltaEvent,
    InputJsonDeltaEvent,
    ContentBlockStopEvent,
    RateLimitInfoEvent,
    PermissionRequestEvent,
    # Functions
    emit,
    convert_content_block,
    convert_stream_event,
    convert_message,
    parse_command,
    build_prompt,
    build_options,
    _tool_result,
    _make_can_use_tool_callback,
    _prompt_as_streaming,
    cancel_task,
    # MCP tool handlers
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
    _run_emacsclient,
    _tool_result,
    EmacsclientNotFoundError,
    _EMACS_MCP_SERVER,
    # Constants
    DEFAULT_TOOLS,
    EMACS_TOOL_NAMES,
    # Permission state
    _pending_permission_requests,
    _permission_decisions,
)
from claude_agent_sdk import (
    AssistantMessage,
    RateLimitEvent as SDKRateLimitEvent,
    RateLimitInfo,
    ResultMessage,
    StreamEvent,
    SystemMessage,
    TaskNotificationMessage,
    TaskProgressMessage,
    TaskStartedMessage,
    TaskUsage,
    TextBlock,
    ThinkingBlock,
    ToolPermissionContext,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
)


# ── helpers ──────────────────────────────────────────────────────────────────


def _capture_emit(event: Any) -> dict[str, Any]:
    """Emit an event and return the JSON dict that was written to stdout."""
    buf = StringIO()
    with patch("claude_code_backend.sys.stdout", buf):
        emit(event)
    return json.loads(buf.getvalue().strip())


def _make_task_usage() -> TaskUsage:
    return TaskUsage(
        input_tokens=0,
        output_tokens=0,
        cache_read_input_tokens=0,
        cache_creation_input_tokens=0,
        cost_usd=0.0,
    )


# ═══════════════════════════════════════════════════════════════════════════
# emit()
# ═══════════════════════════════════════════════════════════════════════════


class TestEmit:
    def test_status_event(self) -> None:
        out = _capture_emit(StatusEvent(status="ready"))
        assert out == {"type": "status", "status": "ready"}

    def test_error_event(self) -> None:
        out = _capture_emit(ErrorEvent(message="boom", detail="tb"))
        assert out == {"type": "error", "message": "boom", "detail": "tb"}

    def test_error_event_no_detail(self) -> None:
        out = _capture_emit(ErrorEvent(message="boom"))
        assert out["detail"] is None

    def test_assistant_event(self) -> None:
        out = _capture_emit(
            AssistantEvent(
                content=[TextContentBlock(text="hi")],
                model="claude-sonnet",
            )
        )
        assert out["type"] == "assistant"
        assert out["content"] == [{"type": "text", "text": "hi"}]
        assert out["model"] == "claude-sonnet"

    def test_result_event(self) -> None:
        out = _capture_emit(
            ResultEvent(
                result="done",
                session_id="s1",
                num_turns=3,
                total_cost_usd=0.05,
                duration_ms=1200,
            )
        )
        assert out["type"] == "result"
        assert out["session_id"] == "s1"
        assert out["num_turns"] == 3

    def test_broken_pipe_exits(self) -> None:
        with patch("claude_code_backend.sys.stdout") as mock_out:
            mock_out.write.side_effect = BrokenPipeError
            with pytest.raises(SystemExit):
                emit(StatusEvent(status="ready"))

    def test_permission_request_event(self) -> None:
        out = _capture_emit(
            PermissionRequestEvent(
                request_id="perm_abc",
                tool_name="Bash",
                tool_input={"command": "ls"},
            )
        )
        assert out["type"] == "permission_request"
        assert out["request_id"] == "perm_abc"
        assert out["tool_name"] == "Bash"

    def test_text_delta_event(self) -> None:
        out = _capture_emit(TextDeltaEvent(index=2, text="hello"))
        assert out == {"type": "text_delta", "index": 2, "text": "hello"}

    def test_thinking_delta_event(self) -> None:
        out = _capture_emit(ThinkingDeltaEvent(index=0, thinking="hmm"))
        assert out == {"type": "thinking_delta", "index": 0, "thinking": "hmm"}

    def test_input_json_delta_event(self) -> None:
        out = _capture_emit(InputJsonDeltaEvent(index=1, partial_json='{"k":'))
        assert out == {
            "type": "input_json_delta",
            "index": 1,
            "partial_json": '{"k":',
        }


# ═══════════════════════════════════════════════════════════════════════════
# convert_content_block()
# ═══════════════════════════════════════════════════════════════════════════


class TestConvertContentBlock:
    def test_text_block(self) -> None:
        result = convert_content_block(TextBlock(text="hello"))
        assert isinstance(result, TextContentBlock)
        assert result.text == "hello"

    def test_thinking_block(self) -> None:
        result = convert_content_block(ThinkingBlock(thinking="hmm", signature="sig"))
        assert isinstance(result, ThinkingContentBlock)
        assert result.thinking == "hmm"

    def test_tool_use_block(self) -> None:
        result = convert_content_block(
            ToolUseBlock(id="tu1", name="Read", input={"path": "/tmp"})
        )
        assert isinstance(result, ToolUseContentBlock)
        assert result.id == "tu1"
        assert result.name == "Read"
        assert result.input == {"path": "/tmp"}

    def test_tool_result_block(self) -> None:
        result = convert_content_block(
            ToolResultBlock(tool_use_id="tu1", content="output", is_error=False)
        )
        assert isinstance(result, ToolResultContentBlock)
        assert result.tool_use_id == "tu1"
        assert result.content == "output"
        assert result.is_error is False

    def test_tool_result_block_error(self) -> None:
        result = convert_content_block(
            ToolResultBlock(tool_use_id="tu1", content="fail", is_error=True)
        )
        assert isinstance(result, ToolResultContentBlock)
        assert result.is_error is True


# ═══════════════════════════════════════════════════════════════════════════
# convert_stream_event()
# ═══════════════════════════════════════════════════════════════════════════


class TestConvertStreamEvent:
    def test_content_block_start(self) -> None:
        result = convert_stream_event(
            {"type": "content_block_start", "index": 0, "content_block": {"type": "text"}}
        )
        assert isinstance(result, ContentBlockStartEvent)
        assert result.index == 0
        assert result.block_type == "text"

    def test_text_delta(self) -> None:
        result = convert_stream_event(
            {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "hi"}}
        )
        assert isinstance(result, TextDeltaEvent)
        assert result.text == "hi"

    def test_thinking_delta(self) -> None:
        result = convert_stream_event(
            {"type": "content_block_delta", "index": 1, "delta": {"type": "thinking_delta", "thinking": "hmm"}}
        )
        assert isinstance(result, ThinkingDeltaEvent)
        assert result.thinking == "hmm"

    def test_input_json_delta(self) -> None:
        result = convert_stream_event(
            {"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": '{"x":'}}
        )
        assert isinstance(result, InputJsonDeltaEvent)
        assert result.partial_json == '{"x":'

    def test_content_block_stop(self) -> None:
        result = convert_stream_event({"type": "content_block_stop", "index": 3})
        assert isinstance(result, ContentBlockStopEvent)
        assert result.index == 3

    def test_unknown_delta_type_returns_none(self) -> None:
        result = convert_stream_event(
            {"type": "content_block_delta", "index": 0, "delta": {"type": "unknown_delta"}}
        )
        assert result is None

    def test_message_start_returns_none(self) -> None:
        assert convert_stream_event({"type": "message_start"}) is None

    def test_message_stop_returns_none(self) -> None:
        assert convert_stream_event({"type": "message_stop"}) is None

    def test_empty_event_returns_none(self) -> None:
        assert convert_stream_event({}) is None


# ═══════════════════════════════════════════════════════════════════════════
# convert_message()
# ═══════════════════════════════════════════════════════════════════════════


class TestConvertMessage:
    def test_system_message(self) -> None:
        msg = SystemMessage(subtype="init", data={"session_id": "s1"})
        result = convert_message(msg)
        assert isinstance(result, SystemEvent)
        assert result.subtype == "init"
        assert result.data == {"session_id": "s1"}

    def test_assistant_message(self) -> None:
        msg = AssistantMessage(
            content=[TextBlock(text="hello")],
            model="claude-sonnet",
        )
        result = convert_message(msg)
        assert isinstance(result, AssistantEvent)
        assert result.model == "claude-sonnet"
        assert len(result.content) == 1  # type: ignore[arg-type]
        assert isinstance(result.content[0], TextContentBlock)  # type: ignore[index]

    def test_result_message(self) -> None:
        msg = ResultMessage(
            subtype="result",
            result="done",
            stop_reason="end_turn",
            is_error=False,
            num_turns=2,
            total_cost_usd=0.01,
            duration_ms=500,
            duration_api_ms=400,
            session_id="s1",
        )
        result = convert_message(msg)
        assert isinstance(result, ResultEvent)
        assert result.result == "done"
        assert result.session_id == "s1"
        assert result.num_turns == 2

    def test_task_progress_message(self) -> None:
        msg = TaskProgressMessage(
            subtype="task_progress",
            data={},
            task_id="t1",
            description="working",
            last_tool_name="Read",
            usage=_make_task_usage(),
            uuid="u1",
            session_id="s1",
        )
        result = convert_message(msg)
        assert isinstance(result, TaskProgressEvent)
        assert result.task_id == "t1"
        assert result.last_tool_name == "Read"

    def test_task_started_message(self) -> None:
        msg = TaskStartedMessage(
            subtype="task_started",
            data={},
            task_id="t1",
            description="starting",
            uuid="u1",
            session_id="s1",
        )
        result = convert_message(msg)
        assert isinstance(result, TaskStartedEvent)
        assert result.task_id == "t1"

    def test_task_notification_message(self) -> None:
        msg = TaskNotificationMessage(
            subtype="task_notification",
            data={},
            task_id="t1",
            status="completed",
            output_file="/tmp/out",
            summary="all done",
            uuid="u1",
            session_id="s1",
        )
        result = convert_message(msg)
        assert isinstance(result, TaskNotificationEvent)
        assert result.status == "completed"
        assert result.summary == "all done"

    def test_user_message_with_tool_results(self) -> None:
        msg = UserMessage(
            content=[ToolResultBlock(tool_use_id="tu1", content="output")]
        )
        result = convert_message(msg)
        assert isinstance(result, AssistantEvent)
        assert len(result.content) == 1  # type: ignore[arg-type]
        assert isinstance(result.content[0], ToolResultContentBlock)  # type: ignore[index]

    def test_user_message_string_returns_none(self) -> None:
        msg = UserMessage(content="hello")
        assert convert_message(msg) is None

    def test_user_message_empty_list_returns_none(self) -> None:
        # A UserMessage with a list but no ToolResultBlocks
        msg = UserMessage(content=[TextBlock(text="hi")])
        result = convert_message(msg)
        assert result is None

    def test_stream_event(self) -> None:
        msg = StreamEvent(
            uuid="u1",
            session_id="s1",
            event={"type": "content_block_stop", "index": 0},
        )
        result = convert_message(msg)
        assert isinstance(result, ContentBlockStopEvent)

    def test_rate_limit_event(self) -> None:
        msg = SDKRateLimitEvent(
            rate_limit_info=RateLimitInfo(status="allowed"),
            uuid="u1",
            session_id="s1",
        )
        result = convert_message(msg)
        assert isinstance(result, RateLimitInfoEvent)
        assert result.message == "Rate limited by API"

    def test_plain_system_message_still_works(self) -> None:
        """SystemMessage that is NOT a Task* subclass should still map to SystemEvent."""
        msg = SystemMessage(subtype="init", data={"session_id": "abc"})
        result = convert_message(msg)
        assert isinstance(result, SystemEvent)
        assert result.subtype == "init"

    def test_task_progress_not_swallowed_as_system(self) -> None:
        """TaskProgressMessage must NOT be matched by the SystemMessage arm."""
        msg = TaskProgressMessage(
            subtype="task_progress", data={}, task_id="t1",
            description="searching", last_tool_name="Grep",
            usage=_make_task_usage(), uuid="u1", session_id="s1",
        )
        result = convert_message(msg)
        # Must be TaskProgressEvent, not SystemEvent
        assert not isinstance(result, SystemEvent)
        assert isinstance(result, TaskProgressEvent)

    def test_task_started_not_swallowed_as_system(self) -> None:
        """TaskStartedMessage must NOT be matched by the SystemMessage arm."""
        msg = TaskStartedMessage(
            subtype="task_started", data={}, task_id="t1",
            description="auditing", uuid="u1", session_id="s1",
        )
        result = convert_message(msg)
        assert not isinstance(result, SystemEvent)
        assert isinstance(result, TaskStartedEvent)

    def test_task_notification_not_swallowed_as_system(self) -> None:
        """TaskNotificationMessage must NOT be matched by the SystemMessage arm."""
        msg = TaskNotificationMessage(
            subtype="task_notification", data={}, task_id="t1",
            status="completed", output_file="/out", summary="done",
            uuid="u1", session_id="s1",
        )
        result = convert_message(msg)
        assert not isinstance(result, SystemEvent)
        assert isinstance(result, TaskNotificationEvent)

    def test_task_notification_failed_status(self) -> None:
        msg = TaskNotificationMessage(
            subtype="task_notification", data={}, task_id="t1",
            status="failed", output_file="/out", summary="crash",
            uuid="u1", session_id="s1",
        )
        result = convert_message(msg)
        assert isinstance(result, TaskNotificationEvent)
        assert result.status == "failed"
        assert result.summary == "crash"

    def test_assistant_with_multiple_block_types(self) -> None:
        """An assistant message can contain mixed block types."""
        msg = AssistantMessage(
            content=[
                ThinkingBlock(thinking="let me think", signature="sig"),
                TextBlock(text="here's the answer"),
                ToolUseBlock(id="tu1", name="Read", input={"path": "/f"}),
            ],
            model="claude-opus",
        )
        result = convert_message(msg)
        assert isinstance(result, AssistantEvent)
        assert len(result.content) == 3  # type: ignore[arg-type]
        assert isinstance(result.content[0], ThinkingContentBlock)  # type: ignore[index]
        assert isinstance(result.content[1], TextContentBlock)  # type: ignore[index]
        assert isinstance(result.content[2], ToolUseContentBlock)  # type: ignore[index]

    def test_user_message_mixed_blocks_only_tool_results(self) -> None:
        """UserMessage with mixed blocks should only emit ToolResultBlock entries."""
        msg = UserMessage(
            content=[
                TextBlock(text="irrelevant"),
                ToolResultBlock(tool_use_id="tu1", content="result1"),
                ToolResultBlock(tool_use_id="tu2", content="result2", is_error=True),
            ],
        )
        result = convert_message(msg)
        assert isinstance(result, AssistantEvent)
        assert len(result.content) == 2  # type: ignore[arg-type]
        assert all(isinstance(b, ToolResultContentBlock) for b in result.content)  # type: ignore[union-attr]


# ═══════════════════════════════════════════════════════════════════════════
# parse_command()
# ═══════════════════════════════════════════════════════════════════════════


class TestParseCommand:
    def test_query_minimal(self) -> None:
        cmd = parse_command({"type": "query", "prompt": "hello"})
        assert isinstance(cmd, QueryCommand)
        assert cmd.prompt == "hello"
        assert cmd.cwd is None
        assert cmd.images is None

    def test_query_full(self) -> None:
        cmd = parse_command({
            "type": "query",
            "prompt": "do stuff",
            "cwd": "/tmp",
            "allowed_tools": ["Read", "Write"],
            "system_prompt": "be helpful",
            "max_turns": 5,
            "permission_mode": "bypassPermissions",
            "model": "claude-sonnet-4-6",
            "effort": "high",
            "max_budget_usd": 1.0,
            "betas": ["context-1m-2025-08-07"],
            "resume": "session-123",
            "ask_permission_tools": ["Bash"],
        })
        assert isinstance(cmd, QueryCommand)
        assert cmd.cwd == "/tmp"
        assert cmd.allowed_tools == ["Read", "Write"]
        assert cmd.max_turns == 5
        assert cmd.permission_mode == "bypassPermissions"
        assert cmd.model == "claude-sonnet-4-6"
        assert cmd.effort == "high"
        assert cmd.resume == "session-123"
        assert cmd.ask_permission_tools == ["Bash"]

    def test_query_with_images(self) -> None:
        cmd = parse_command({
            "type": "query",
            "prompt": "what is this?",
            "images": [
                {"data": "abc123", "media_type": "image/png", "name": "screenshot.png"},
            ],
        })
        assert isinstance(cmd, QueryCommand)
        assert cmd.images is not None
        assert len(cmd.images) == 1
        assert cmd.images[0].data == "abc123"
        assert cmd.images[0].media_type == "image/png"

    def test_cancel(self) -> None:
        cmd = parse_command({"type": "cancel"})
        assert isinstance(cmd, CancelCommand)

    def test_quit(self) -> None:
        cmd = parse_command({"type": "quit"})
        assert isinstance(cmd, QuitCommand)

    def test_permission_response(self) -> None:
        cmd = parse_command({
            "type": "permission_response",
            "request_id": "perm_abc",
            "decision": "allow",
        })
        assert isinstance(cmd, PermissionResponseCommand)
        assert cmd.request_id == "perm_abc"
        assert cmd.decision == "allow"

    def test_unknown_type_raises(self) -> None:
        with pytest.raises(ValueError, match="Unknown command type"):
            parse_command({"type": "bogus"})

    def test_missing_prompt_raises(self) -> None:
        with pytest.raises(KeyError):
            parse_command({"type": "query"})

    def test_missing_request_id_raises(self) -> None:
        with pytest.raises(KeyError):
            parse_command({"type": "permission_response", "decision": "allow"})


# ═══════════════════════════════════════════════════════════════════════════
# _tool_result()
# ═══════════════════════════════════════════════════════════════════════════


class TestToolResult:
    def test_success(self) -> None:
        result = _tool_result("hello")
        assert result == {"content": [{"type": "text", "text": "hello"}]}
        assert "is_error" not in result

    def test_error(self) -> None:
        result = _tool_result("oops", is_error=True)
        assert result["is_error"] is True
        assert result["content"][0]["text"] == "oops"


# ═══════════════════════════════════════════════════════════════════════════
# build_prompt() / _prompt_as_messages()
# ═══════════════════════════════════════════════════════════════════════════


class TestBuildPrompt:
    def test_plain_text_returns_string(self) -> None:
        """Without streaming or images, build_prompt returns a plain string."""
        cmd = QueryCommand(type="query", prompt="hello")
        result = build_prompt(cmd)
        assert result == "hello"

    @pytest.mark.asyncio
    async def test_streaming_yields_sdk_format(self) -> None:
        """With streaming=True, yields SDK streaming-format dicts."""
        cmd = QueryCommand(type="query", prompt="hello")
        gen = build_prompt(cmd, streaming=True)
        messages = [msg async for msg in gen]
        assert len(messages) == 1
        assert messages[0]["type"] == "user"
        assert messages[0]["message"] == {"role": "user", "content": "hello"}

    @pytest.mark.asyncio
    async def test_images_always_stream(self) -> None:
        """Images force streaming mode even without streaming=True."""
        cmd = QueryCommand(
            type="query",
            prompt="what is this?",
            images=[
                ImageAttachment(data="abc", media_type="image/png", name="img.png"),
            ],
        )
        gen = build_prompt(cmd)
        assert hasattr(gen, "__aiter__")
        messages = [msg async for msg in gen]
        assert len(messages) == 1
        assert messages[0]["type"] == "user"
        content = messages[0]["message"]["content"]
        assert isinstance(content, list)
        assert len(content) == 2
        # First block: image
        assert content[0]["type"] == "image"
        assert content[0]["source"]["data"] == "abc"
        assert content[0]["source"]["media_type"] == "image/png"
        # Second block: text
        assert content[1] == {"type": "text", "text": "what is this?"}

    @pytest.mark.asyncio
    async def test_multiple_images(self) -> None:
        cmd = QueryCommand(
            type="query",
            prompt="compare",
            images=[
                ImageAttachment(data="a", media_type="image/png", name="a.png"),
                ImageAttachment(data="b", media_type="image/jpeg", name="b.jpg"),
            ],
        )
        gen = build_prompt(cmd, streaming=True)
        messages = [msg async for msg in gen]
        content = messages[0]["message"]["content"]
        # 2 images + 1 text
        assert len(content) == 3
        assert content[0]["type"] == "image"
        assert content[1]["type"] == "image"
        assert content[2]["type"] == "text"

    @pytest.mark.asyncio
    async def test_streaming_flag_produces_async_gen(self) -> None:
        """streaming=True always returns an async generator."""
        cmd = QueryCommand(type="query", prompt="test")
        gen = build_prompt(cmd, streaming=True)
        assert hasattr(gen, "__aiter__")
        assert hasattr(gen, "__anext__")
        _ = [msg async for msg in gen]


# ═══════════════════════════════════════════════════════════════════════════
# build_options()
# ═══════════════════════════════════════════════════════════════════════════


class TestBuildOptions:
    def test_default_tools_include_emacs(self) -> None:
        cmd = QueryCommand(type="query", prompt="hi")
        opts = build_options(cmd)
        for tool_name in EMACS_TOOL_NAMES:
            assert tool_name in opts.allowed_tools

    def test_default_tools_include_defaults(self) -> None:
        cmd = QueryCommand(type="query", prompt="hi")
        opts = build_options(cmd)
        for tool_name in DEFAULT_TOOLS:
            assert tool_name in opts.allowed_tools

    def test_custom_tools_plus_emacs(self) -> None:
        cmd = QueryCommand(
            type="query", prompt="hi", allowed_tools=["Read", "Grep"]
        )
        opts = build_options(cmd)
        assert "Read" in opts.allowed_tools
        assert "Grep" in opts.allowed_tools
        # Emacs tools still present
        assert "EvalEmacs" in opts.allowed_tools

    def test_no_duplicate_emacs_tools(self) -> None:
        """If user already lists an Emacs tool, it shouldn't appear twice."""
        cmd = QueryCommand(
            type="query", prompt="hi", allowed_tools=["Read", "EvalEmacs"]
        )
        opts = build_options(cmd)
        count = opts.allowed_tools.count("EvalEmacs")
        assert count == 1

    def test_no_permission_callback_without_ask_tools(self) -> None:
        cmd = QueryCommand(type="query", prompt="hi")
        opts = build_options(cmd)
        assert opts.can_use_tool is None

    def test_permission_callback_with_ask_tools(self) -> None:
        cmd = QueryCommand(
            type="query",
            prompt="hi",
            ask_permission_tools=["Bash"],
            permission_mode="default",
        )
        opts = build_options(cmd)
        assert opts.can_use_tool is not None

    def test_bypass_overridden_when_ask_tools(self) -> None:
        """bypassPermissions is downgraded to 'default' when ask_permission_tools is set."""
        cmd = QueryCommand(
            type="query",
            prompt="hi",
            ask_permission_tools=["Bash"],
            permission_mode="bypassPermissions",
        )
        opts = build_options(cmd)
        assert opts.permission_mode == "default"

    def test_bypass_preserved_without_ask_tools(self) -> None:
        cmd = QueryCommand(
            type="query",
            prompt="hi",
            permission_mode="bypassPermissions",
        )
        opts = build_options(cmd)
        assert opts.permission_mode == "bypassPermissions"

    def test_passthrough_fields(self) -> None:
        cmd = QueryCommand(
            type="query",
            prompt="hi",
            cwd="/tmp",
            max_turns=10,
            max_budget_usd=2.5,
            system_prompt="be nice",
            model="claude-sonnet-4-6",
            effort="high",
            resume="session-abc",
        )
        opts = build_options(cmd)
        assert opts.cwd == "/tmp"
        assert opts.max_turns == 10
        assert opts.max_budget_usd == 2.5
        assert opts.system_prompt == "be nice"
        assert opts.model == "claude-sonnet-4-6"
        assert opts.effort == "high"
        assert opts.resume == "session-abc"


# ═══════════════════════════════════════════════════════════════════════════
# _make_can_use_tool_callback() — per-query permission callback factory
# ═══════════════════════════════════════════════════════════════════════════


class TestCanUseToolCallback:
    def setup_method(self) -> None:
        _pending_permission_requests.clear()
        _permission_decisions.clear()

    def teardown_method(self) -> None:
        _pending_permission_requests.clear()
        _permission_decisions.clear()

    @pytest.mark.asyncio
    async def test_allow_decision(self) -> None:
        callback = _make_can_use_tool_callback()
        ctx = ToolPermissionContext()

        async def _respond() -> None:
            while not _pending_permission_requests:
                await asyncio.sleep(0.01)
            req_id = next(iter(_pending_permission_requests))
            _permission_decisions[req_id] = "allow"
            _pending_permission_requests[req_id].set()

        with patch("claude_code_backend.emit"):
            task = asyncio.create_task(_respond())
            result = await callback("Bash", {"command": "ls"}, ctx)
            await task

        assert result.behavior == "allow"

    @pytest.mark.asyncio
    async def test_deny_decision(self) -> None:
        callback = _make_can_use_tool_callback()
        ctx = ToolPermissionContext()

        async def _respond() -> None:
            while not _pending_permission_requests:
                await asyncio.sleep(0.01)
            req_id = next(iter(_pending_permission_requests))
            _permission_decisions[req_id] = "deny"
            _pending_permission_requests[req_id].set()

        with patch("claude_code_backend.emit"):
            task = asyncio.create_task(_respond())
            result = await callback("Bash", {}, ctx)
            await task

        assert result.behavior == "deny"

    @pytest.mark.asyncio
    async def test_always_allow_remembers_within_callback(self) -> None:
        """'always_allow' is scoped to the callback instance (one query)."""
        callback = _make_can_use_tool_callback()
        ctx = ToolPermissionContext()

        async def _respond() -> None:
            while not _pending_permission_requests:
                await asyncio.sleep(0.01)
            req_id = next(iter(_pending_permission_requests))
            _permission_decisions[req_id] = "always_allow"
            _pending_permission_requests[req_id].set()

        with patch("claude_code_backend.emit"):
            task = asyncio.create_task(_respond())
            result = await callback("Bash", {}, ctx)
            await task

        assert result.behavior == "allow"

        # Same callback: subsequent call should auto-allow without prompting
        result2 = await callback("Bash", {}, ctx)
        assert result2.behavior == "allow"

    @pytest.mark.asyncio
    async def test_always_allow_does_not_leak_across_callbacks(self) -> None:
        """A fresh callback should NOT inherit always-allowed from a prior one."""
        cb1 = _make_can_use_tool_callback()
        cb2 = _make_can_use_tool_callback()
        ctx = ToolPermissionContext()

        async def _respond_always() -> None:
            while not _pending_permission_requests:
                await asyncio.sleep(0.01)
            req_id = next(iter(_pending_permission_requests))
            _permission_decisions[req_id] = "always_allow"
            _pending_permission_requests[req_id].set()

        # cb1: always-allow Bash
        with patch("claude_code_backend.emit"):
            task = asyncio.create_task(_respond_always())
            await cb1("Bash", {}, ctx)
            await task

        # cb2: should still prompt (not auto-allow)
        emitted: list[Any] = []

        async def _respond_deny() -> None:
            while not _pending_permission_requests:
                await asyncio.sleep(0.01)
            req_id = next(iter(_pending_permission_requests))
            _permission_decisions[req_id] = "deny"
            _pending_permission_requests[req_id].set()

        with patch("claude_code_backend.emit", side_effect=lambda e: emitted.append(e)):
            task = asyncio.create_task(_respond_deny())
            result = await cb2("Bash", {}, ctx)
            await task

        # cb2 should have prompted (emitted a permission request)
        assert len(emitted) == 1
        assert result.behavior == "deny"

    @pytest.mark.asyncio
    async def test_timeout_denies(self) -> None:
        callback = _make_can_use_tool_callback()
        ctx = ToolPermissionContext()
        with (
            patch("claude_code_backend.emit"),
            patch("claude_code_backend._PERMISSION_TIMEOUT", 0.05),
        ):
            result = await callback("Bash", {}, ctx)
        assert result.behavior == "deny"

    @pytest.mark.asyncio
    async def test_emits_permission_request(self) -> None:
        callback = _make_can_use_tool_callback()
        ctx = ToolPermissionContext()
        emitted: list[Any] = []

        async def _respond() -> None:
            while not _pending_permission_requests:
                await asyncio.sleep(0.01)
            req_id = next(iter(_pending_permission_requests))
            _permission_decisions[req_id] = "allow"
            _pending_permission_requests[req_id].set()

        with patch("claude_code_backend.emit", side_effect=lambda e: emitted.append(e)):
            task = asyncio.create_task(_respond())
            await callback("Bash", {"command": "rm"}, ctx)
            await task

        assert len(emitted) == 1
        assert isinstance(emitted[0], PermissionRequestEvent)
        assert emitted[0].tool_name == "Bash"
        assert emitted[0].tool_input == {"command": "rm"}


# ═══════════════════════════════════════════════════════════════════════════
# cancel_task()
# ═══════════════════════════════════════════════════════════════════════════


class TestCancelTask:
    @pytest.mark.asyncio
    async def test_cancels_running_task(self) -> None:
        ran = asyncio.Event()

        async def forever() -> None:
            ran.set()
            await asyncio.sleep(999)

        task = asyncio.create_task(forever())
        await ran.wait()
        await cancel_task(task)
        assert task.cancelled()

    @pytest.mark.asyncio
    async def test_cancel_already_done(self) -> None:
        async def quick() -> None:
            pass

        task = asyncio.create_task(quick())
        await task
        # Should not raise
        await cancel_task(task)


# ═══════════════════════════════════════════════════════════════════════════
# Dataclass field defaults
# ═══════════════════════════════════════════════════════════════════════════


class TestEventDefaults:
    def test_status_event_defaults(self) -> None:
        e = StatusEvent()
        assert e.type == "status"
        assert e.status == "ready"

    def test_error_event_defaults(self) -> None:
        e = ErrorEvent()
        assert e.message == ""
        assert e.detail is None

    def test_result_event_defaults(self) -> None:
        e = ResultEvent()
        assert e.num_turns == 0
        assert e.is_error is False
        assert e.session_id == ""

    def test_task_progress_defaults(self) -> None:
        e = TaskProgressEvent()
        assert e.task_id == ""
        assert e.last_tool_name is None

    def test_content_block_start_defaults(self) -> None:
        e = ContentBlockStartEvent()
        assert e.index == 0
        assert e.block_type == ""


# ═══════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════


class TestConstants:
    def test_default_tools(self) -> None:
        assert "Read" in DEFAULT_TOOLS
        assert "Write" in DEFAULT_TOOLS
        assert "Edit" in DEFAULT_TOOLS
        assert "Bash" in DEFAULT_TOOLS
        assert "Glob" in DEFAULT_TOOLS
        assert "Grep" in DEFAULT_TOOLS

    def test_emacs_tool_names(self) -> None:
        assert "EvalEmacs" in EMACS_TOOL_NAMES
        assert "EmacsRenderFrame" in EMACS_TOOL_NAMES
        assert "EmacsGetMessages" in EMACS_TOOL_NAMES
        assert "EmacsGetBuffer" in EMACS_TOOL_NAMES
        assert "EmacsListBuffers" in EMACS_TOOL_NAMES


# ═══════════════════════════════════════════════════════════════════════════
# _tool_result() helper
# ═══════════════════════════════════════════════════════════════════════════


class TestToolResultHelper:
    def test_success_result(self) -> None:
        r = _tool_result("hello")
        assert r == {"content": [{"type": "text", "text": "hello"}]}
        assert "is_error" not in r

    def test_error_result(self) -> None:
        r = _tool_result("oops", is_error=True)
        assert r["is_error"] is True
        assert r["content"][0]["text"] == "oops"


# ═══════════════════════════════════════════════════════════════════════════
# MCP Emacs tool handlers
# ═══════════════════════════════════════════════════════════════════════════


class TestMcpServerStructure:
    """Tests for the MCP server configuration and tool registration."""

    def test_mcp_server_exists(self) -> None:
        assert _EMACS_MCP_SERVER is not None

    def test_all_emacs_tools_registered(self) -> None:
        """Every name in EMACS_TOOL_NAMES should correspond to a registered tool."""
        for name in EMACS_TOOL_NAMES:
            assert name in EMACS_TOOL_NAMES


class TestEmacsEval:
    @pytest.mark.asyncio
    async def test_eval_success(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="ok: 42"):
            result = await _emacs_eval.handler({"code": "(+ 1 41)"})
        assert result["content"][0]["text"] == "ok: 42"
        assert "is_error" not in result

    @pytest.mark.asyncio
    async def test_eval_error_result(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="error: void-variable foo"):
            result = await _emacs_eval.handler({"code": "foo"})
        assert result["is_error"] is True
        assert "void-variable" in result["content"][0]["text"]

    @pytest.mark.asyncio
    async def test_eval_emacsclient_failure(self) -> None:
        with patch("claude_code_backend._run_emacsclient", side_effect=RuntimeError("connection refused")):
            result = await _emacs_eval.handler({"code": "(+ 1 1)"})
        assert result["is_error"] is True
        assert "emacsclient failed" in result["content"][0]["text"]

    @pytest.mark.asyncio
    async def test_eval_emacsclient_not_found_raises(self) -> None:
        with patch("claude_code_backend._run_emacsclient", side_effect=EmacsclientNotFoundError("not found")):
            with pytest.raises(EmacsclientNotFoundError):
                await _emacs_eval.handler({"code": "(+ 1 1)"})

    @pytest.mark.asyncio
    async def test_eval_empty_code(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="ok: nil"):
            result = await _emacs_eval.handler({})
        assert result["content"][0]["text"] == "ok: nil"


class TestEmacsRenderFrame:
    @pytest.mark.asyncio
    async def test_render_frame_success(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="frame output"):
            result = await _emacs_render_frame.handler({})
        assert result["content"][0]["text"] == "frame output"
        assert "is_error" not in result

    @pytest.mark.asyncio
    async def test_render_frame_error(self) -> None:
        with patch("claude_code_backend._run_emacsclient", side_effect=RuntimeError("timeout")):
            result = await _emacs_render_frame.handler({})
        assert result["is_error"] is True


class TestEmacsGetMessages:
    @pytest.mark.asyncio
    async def test_get_messages_default(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="msg output") as mock:
            result = await _emacs_get_messages.handler({})
        assert result["content"][0]["text"] == "msg output"
        # Check that 3000 (default) was passed
        call_arg = mock.call_args[0][0]
        assert "3000" in call_arg

    @pytest.mark.asyncio
    async def test_get_messages_custom_n(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="short") as mock:
            result = await _emacs_get_messages.handler({"n_chars": 500})
        call_arg = mock.call_args[0][0]
        assert "500" in call_arg


class TestEmacsGetBuffer:
    @pytest.mark.asyncio
    async def test_get_buffer_basic(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="buffer content") as mock:
            result = await _emacs_get_buffer.handler({"buffer_name": "*scratch*"})
        assert result["content"][0]["text"] == "buffer content"
        call_arg = mock.call_args[0][0]
        assert "*scratch*" in call_arg

    @pytest.mark.asyncio
    async def test_get_buffer_with_line_numbers(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="1: line") as mock:
            await _emacs_get_buffer.handler({"buffer_name": "test.el", "with_line_numbers": True})
        call_arg = mock.call_args[0][0]
        assert " t)" in call_arg  # the line-numbers flag

    @pytest.mark.asyncio
    async def test_get_buffer_error(self) -> None:
        with patch("claude_code_backend._run_emacsclient", side_effect=RuntimeError("no buffer")):
            result = await _emacs_get_buffer.handler({"buffer_name": "nonexistent"})
        assert result["is_error"] is True


class TestEmacsGetBufferRegion:
    @pytest.mark.asyncio
    async def test_get_region(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="region text") as mock:
            result = await _emacs_get_buffer_region.handler({
                "buffer_name": "test.el", "start_line": 10, "end_line": 20
            })
        assert result["content"][0]["text"] == "region text"
        call_arg = mock.call_args[0][0]
        assert "10" in call_arg
        assert "20" in call_arg


class TestEmacsListBuffers:
    @pytest.mark.asyncio
    async def test_list_buffers(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="buf1\nbuf2"):
            result = await _emacs_list_buffers.handler({})
        assert "buf1" in result["content"][0]["text"]


class TestEmacsSwitchBuffer:
    @pytest.mark.asyncio
    async def test_switch_buffer(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="switched") as mock:
            result = await _emacs_switch_buffer.handler({"buffer_name": "*scratch*"})
        assert result["content"][0]["text"] == "switched"
        call_arg = mock.call_args[0][0]
        assert "*scratch*" in call_arg


class TestEmacsGetPointInfo:
    @pytest.mark.asyncio
    async def test_get_point_default_buffer(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="line:1 col:0") as mock:
            result = await _emacs_get_point_info.handler({})
        assert "line:1" in result["content"][0]["text"]
        # No buffer arg → simpler elisp call
        call_arg = mock.call_args[0][0]
        assert "claude-code-tools-get-point-info)" in call_arg

    @pytest.mark.asyncio
    async def test_get_point_specific_buffer(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="info") as mock:
            await _emacs_get_point_info.handler({"buffer_name": "test.el"})
        call_arg = mock.call_args[0][0]
        assert "test.el" in call_arg


class TestEmacsSearchForward:
    @pytest.mark.asyncio
    async def test_search_forward(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="found at line 5") as mock:
            result = await _emacs_search_forward.handler({"pattern": "defun"})
        assert "found" in result["content"][0]["text"]
        call_arg = mock.call_args[0][0]
        assert "defun" in call_arg

    @pytest.mark.asyncio
    async def test_search_forward_with_buffer(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="found") as mock:
            await _emacs_search_forward.handler({"pattern": "foo", "buffer_name": "bar.el"})
        call_arg = mock.call_args[0][0]
        assert "bar.el" in call_arg


class TestEmacsSearchBackward:
    @pytest.mark.asyncio
    async def test_search_backward(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="found") as mock:
            result = await _emacs_search_backward.handler({"pattern": "require"})
        assert "found" in result["content"][0]["text"]


class TestEmacsGotoLine:
    @pytest.mark.asyncio
    async def test_goto_line(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="at line 42") as mock:
            result = await _emacs_goto_line.handler({"line_number": 42})
        assert "42" in result["content"][0]["text"]
        call_arg = mock.call_args[0][0]
        assert "42" in call_arg

    @pytest.mark.asyncio
    async def test_goto_line_with_buffer(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="ok") as mock:
            await _emacs_goto_line.handler({"line_number": 1, "buffer_name": "init.el"})
        call_arg = mock.call_args[0][0]
        assert "init.el" in call_arg


class TestEmacsGetDebugInfo:
    @pytest.mark.asyncio
    async def test_get_debug_info(self) -> None:
        with patch("claude_code_backend._run_emacsclient", return_value="debug info"):
            result = await _emacs_get_debug_info.handler({})
        assert result["content"][0]["text"] == "debug info"


class TestRunEmacsclient:
    @pytest.mark.asyncio
    async def test_emacsclient_not_found(self) -> None:
        with patch("claude_code_backend._EMACSCLIENT", None):
            with pytest.raises(EmacsclientNotFoundError):
                await _run_emacsclient("(+ 1 1)")
