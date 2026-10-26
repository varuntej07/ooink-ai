"""Cartesia TTS that tells the server to stop when a stream is cut short.

livekit-plugins-cartesia 1.8.3 streams one websocket context per reply and, on
interruption, cancels its local tasks only: it never sends Cartesia's
``{"context_id": ..., "cancel": true}`` frame, and the pooled socket is not
even closed until the next request drains it. Cartesia therefore keeps
generating the rest of the reply nobody will hear. Every sentence already on
the socket is billed either way (a credit per character sent), so this is a
stop-the-server measure whose refund effect is unconfirmed; what it does
guarantee is that an interrupted context stops producing audio the plugin then
has to discard. Sending less text ahead of playback is the separate lever.

The plugin holds the socket inside ``SynthesizeStream._run`` and creates the
context id there, so rather than copy that body this wraps the connection pool
the stream draws from: the wrapper watches what the plugin sends, remembers
the live context id, notices the ``done`` message, and on an early exit sends
the cancel frame before the pool reclaims the socket.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from typing import Any

import aiohttp
from livekit.plugins import cartesia

logger = logging.getLogger(__name__)

# How long an early-exiting stream may spend telling Cartesia to stop. The
# task is already being cancelled; this bounds the goodbye.
_CANCEL_SEND_TIMEOUT_S = 0.5


class _ContextWatchingSocket:
    """A pass-through over the plugin's websocket that tracks the live context."""

    def __init__(self, ws: aiohttp.ClientWebSocketResponse) -> None:
        self._ws = ws
        self.context_id: str | None = None
        self.done = False

    def __getattr__(self, name: str) -> Any:
        return getattr(self._ws, name)

    async def send_str(self, data: str, *args: Any, **kwargs: Any) -> None:
        try:
            pkt = json.loads(data)
        except (TypeError, ValueError):
            pkt = None
        if isinstance(pkt, dict) and pkt.get("context_id") and "transcript" in pkt:
            self.context_id = str(pkt["context_id"])
        await self._ws.send_str(data, *args, **kwargs)

    async def receive(self, *args: Any, **kwargs: Any) -> aiohttp.WSMessage:
        msg = await self._ws.receive(*args, **kwargs)
        if msg.type == aiohttp.WSMsgType.TEXT and self.context_id is not None:
            try:
                data = json.loads(msg.data)
            except (TypeError, ValueError):
                data = None
            if (
                isinstance(data, dict)
                and data.get("done")
                and data.get("context_id") in (None, self.context_id)
            ):
                self.done = True
        return msg

    async def cancel_if_open(self) -> None:
        """Send the cancel frame if this context started and never finished."""
        if self.context_id is None or self.done or self._ws.closed:
            return
        frame = json.dumps({"context_id": self.context_id, "cancel": True})
        try:
            await asyncio.wait_for(
                asyncio.shield(self._ws.send_str(frame)), _CANCEL_SEND_TIMEOUT_S
            )
        except Exception as exc:
            # The socket is being reclaimed anyway; say so and move on.
            logger.info("cartesia_cancel: cancel frame not sent", extra={
                "context_id": self.context_id,
                "error_type": type(exc).__name__,
            })
            return
        logger.info("cartesia_cancel: cancelled context", extra={"context_id": self.context_id})


class _CancellingPool:
    """Delegates to the plugin's ConnectionPool, yielding watched sockets."""

    def __init__(self, pool: Any) -> None:
        self._pool = pool

    def __getattr__(self, name: str) -> Any:
        return getattr(self._pool, name)

    @asynccontextmanager
    async def connection(self, *, timeout: float) -> AsyncGenerator[Any, None]:
        async with self._pool.connection(timeout=timeout) as ws:
            watched = _ContextWatchingSocket(ws)
            try:
                yield watched
            finally:
                # Runs on CancelledError from a barge-in or a dropped
                # speculation, and on a clean finish (where it is a no-op).
                await watched.cancel_if_open()


class CancellingCartesiaTTS(cartesia.TTS):
    """cartesia.TTS whose interrupted streams cancel their Cartesia context."""

    def __init__(self, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        self._pool = _CancellingPool(self._pool)
