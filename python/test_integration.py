"""Integration tests for MCP tools against a live Emacs instance.

These tests require a running Emacs server (emacsclient must be on PATH
and able to connect).  They are skipped automatically when emacsclient
is not available or the server is not running.

Run with:  cd python && uv run pytest test_integration.py -v
"""
from __future__ import annotations

import asyncio
import shutil
from typing import Any

import pytest

from claude_code_backend import (
    _emacs_eval,
    _emacs_get_buffer,
    _emacs_get_buffer_region,
    _emacs_get_debug_info,
    _emacs_get_messages,
    _emacs_get_point_info,
    _emacs_goto_line,
    _emacs_list_buffers,
    _emacs_render_frame,
    _emacs_search_backward,
    _emacs_search_forward,
    _emacs_switch_buffer,
    _run_emacsclient,
)

# Skip all tests if emacsclient is not on PATH or server is unreachable.
_HAS_EMACSCLIENT = shutil.which("emacsclient") is not None


def _server_running() -> bool:
    """Check whether the Emacs server is actually running."""
    if not _HAS_EMACSCLIENT:
        return False
    try:
        loop = asyncio.new_event_loop()
        result = loop.run_until_complete(_run_emacsclient("(+ 1 1)"))
        loop.close()
        return result == "2"
    except Exception:
        return False


_SERVER_UP = _server_running()
pytestmark = pytest.mark.skipif(
    not _SERVER_UP,
    reason="Emacs server not running (emacsclient can't connect)",
)

# Buffer name used for isolation — created and killed per-test.
_TEST_BUF = " *cc-integration-test*"


async def _setup_test_buffer() -> None:
    await _run_emacsclient(
        f'(with-current-buffer (get-buffer-create "{_TEST_BUF}")'
        f'  (erase-buffer)'
        f'  (insert "line-one\\nline-two\\nline-three\\n")'
        f'  (goto-char (point-min)))'
    )


async def _teardown_test_buffer() -> None:
    await _run_emacsclient(
        f'(when (get-buffer "{_TEST_BUF}") (kill-buffer "{_TEST_BUF}"))'
    )


# ═══════════════════════════════════════════════════════════════════════════
# EvalEmacs
# ═══════════════════════════════════════════════════════════════════════════


class TestEvalEmacsIntegration:
    @pytest.mark.asyncio
    async def test_simple_arithmetic(self) -> None:
        result = await _emacs_eval.handler({"code": "(+ 21 21)"})
        text = result["content"][0]["text"]
        assert "ok" in text.lower()
        assert "42" in text

    @pytest.mark.asyncio
    async def test_string_return(self) -> None:
        result = await _emacs_eval.handler({"code": '(concat "hello" " " "world")'})
        text = result["content"][0]["text"]
        assert "hello world" in text

    @pytest.mark.asyncio
    async def test_error_returns_error(self) -> None:
        result = await _emacs_eval.handler({"code": "(/ 1 0)"})
        text = result["content"][0]["text"]
        assert "error" in text.lower()

    @pytest.mark.asyncio
    async def test_unbalanced_parens(self) -> None:
        result = await _emacs_eval.handler({"code": "(+ 1"})
        text = result["content"][0]["text"]
        assert "error" in text.lower()


# ═══════════════════════════════════════════════════════════════════════════
# EmacsGetBuffer
# ═══════════════════════════════════════════════════════════════════════════


class TestGetBufferIntegration:
    @pytest.mark.asyncio
    async def test_get_test_buffer(self) -> None:
        await _setup_test_buffer()
        try:
            result = await _emacs_get_buffer.handler({"buffer_name": _TEST_BUF})
            text = result["content"][0]["text"]
            assert "line-one" in text
            assert "line-two" in text
        finally:
            await _teardown_test_buffer()

    @pytest.mark.asyncio
    async def test_get_buffer_with_line_numbers(self) -> None:
        await _setup_test_buffer()
        try:
            result = await _emacs_get_buffer.handler({
                "buffer_name": _TEST_BUF,
                "with_line_numbers": True,
            })
            text = result["content"][0]["text"]
            assert "1" in text
            assert "line-one" in text
        finally:
            await _teardown_test_buffer()

    @pytest.mark.asyncio
    async def test_get_nonexistent_buffer(self) -> None:
        result = await _emacs_get_buffer.handler({
            "buffer_name": "*definitely-does-not-exist-xyzzy*"
        })
        text = result["content"][0]["text"]
        assert "error" in text.lower() or "not found" in text.lower() or "no such" in text.lower()


# ═══════════════════════════════════════════════════════════════════════════
# EmacsGetBufferRegion
# ═══════════════════════════════════════════════════════════════════════════


class TestGetBufferRegionIntegration:
    @pytest.mark.asyncio
    async def test_get_region(self) -> None:
        await _setup_test_buffer()
        try:
            result = await _emacs_get_buffer_region.handler({
                "buffer_name": _TEST_BUF,
                "start_line": 1,
                "end_line": 2,
            })
            text = result["content"][0]["text"]
            assert "line-one" in text
            assert "line-two" in text
        finally:
            await _teardown_test_buffer()


# ═══════════════════════════════════════════════════════════════════════════
# EmacsListBuffers
# ═══════════════════════════════════════════════════════════════════════════


class TestListBuffersIntegration:
    @pytest.mark.asyncio
    async def test_lists_buffers_returns_text(self) -> None:
        result = await _emacs_list_buffers.handler({})
        text = result["content"][0]["text"]
        # Should return some non-empty text (may contain control chars that
        # break JSON, in which case the backend wraps it as an error string).
        assert isinstance(text, str)
        assert len(text) > 0


# ═══════════════════════════════════════════════════════════════════════════
# EmacsGetMessages
# ═══════════════════════════════════════════════════════════════════════════


class TestGetMessagesIntegration:
    @pytest.mark.asyncio
    async def test_returns_string(self) -> None:
        result = await _emacs_get_messages.handler({})
        text = result["content"][0]["text"]
        assert isinstance(text, str)
        assert len(text) > 0

    @pytest.mark.asyncio
    async def test_custom_n_chars(self) -> None:
        result = await _emacs_get_messages.handler({"n_chars": 100})
        text = result["content"][0]["text"]
        assert len(text) <= 120  # some slack for encoding


# ═══════════════════════════════════════════════════════════════════════════
# EmacsSwitchBuffer + EmacsGetPointInfo + EmacsGotoLine
# ═══════════════════════════════════════════════════════════════════════════


class TestNavigationIntegration:
    @pytest.mark.asyncio
    async def test_switch_to_test_buffer(self) -> None:
        await _setup_test_buffer()
        try:
            result = await _emacs_switch_buffer.handler({"buffer_name": _TEST_BUF})
            text = result["content"][0]["text"]
            assert "error" not in text.lower()
        finally:
            await _teardown_test_buffer()

    @pytest.mark.asyncio
    async def test_goto_line_and_get_point(self) -> None:
        await _setup_test_buffer()
        try:
            await _emacs_switch_buffer.handler({"buffer_name": _TEST_BUF})
            await _emacs_goto_line.handler({"line_number": 2, "buffer_name": _TEST_BUF})
            result = await _emacs_get_point_info.handler({"buffer_name": _TEST_BUF})
            text = result["content"][0]["text"]
            assert "2" in text
        finally:
            await _teardown_test_buffer()


# ═══════════════════════════════════════════════════════════════════════════
# EmacsSearchForward + EmacsSearchBackward
# ═══════════════════════════════════════════════════════════════════════════


class TestSearchIntegration:
    @pytest.mark.asyncio
    async def test_search_forward_found(self) -> None:
        await _setup_test_buffer()
        try:
            await _run_emacsclient(
                f'(with-current-buffer "{_TEST_BUF}" (goto-char (point-min)))'
            )
            result = await _emacs_search_forward.handler({
                "pattern": "line-two",
                "buffer_name": _TEST_BUF,
            })
            text = result["content"][0]["text"]
            assert "not found" not in text.lower()
        finally:
            await _teardown_test_buffer()

    @pytest.mark.asyncio
    async def test_search_forward_not_found(self) -> None:
        await _setup_test_buffer()
        try:
            result = await _emacs_search_forward.handler({
                "pattern": "xyzzy-nonexistent",
                "buffer_name": _TEST_BUF,
            })
            text = result["content"][0]["text"]
            assert "not found" in text.lower()
        finally:
            await _teardown_test_buffer()

    @pytest.mark.asyncio
    async def test_search_backward(self) -> None:
        await _setup_test_buffer()
        try:
            await _run_emacsclient(
                f'(with-current-buffer "{_TEST_BUF}" (goto-char (point-max)))'
            )
            result = await _emacs_search_backward.handler({
                "pattern": "line-one",
                "buffer_name": _TEST_BUF,
            })
            text = result["content"][0]["text"]
            assert "not found" not in text.lower()
        finally:
            await _teardown_test_buffer()


# ═══════════════════════════════════════════════════════════════════════════
# EmacsGetDebugInfo
# ═══════════════════════════════════════════════════════════════════════════


class TestGetDebugInfoIntegration:
    @pytest.mark.asyncio
    async def test_returns_string(self) -> None:
        result = await _emacs_get_debug_info.handler({})
        text = result["content"][0]["text"]
        assert isinstance(text, str)
