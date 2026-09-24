"""Per-turn latency telemetry for the voice pipeline.

Subscribes to the AgentSession's `metrics_collected` events and emits one structured
log line per metric (STT / EOU / LLM / TTS), plus a `turn_latency` line once the three
customer-facing pieces of a turn are known:

    turn_latency_ms = end_of_utterance_delay + llm ttft + tts ttfb

That sum is the time between the customer going quiet and the Pig starting to speak,
which is the number to compute p50/p95/p99 over. Fields go through `extra=` so LiveKit
Cloud's JSON log formatter surfaces them as top-level keys.
"""

import logging
from dataclasses import dataclass

from livekit.agents import AgentSession, JobContext, MetricsCollectedEvent, metrics

logger = logging.getLogger(__name__)


def _ms(seconds: float | None) -> int | None:
    return None if seconds is None else round(seconds * 1000)


@dataclass
class _TurnParts:
    eou_delay_ms: int | None = None
    llm_ttft_ms: int | None = None
    tts_ttfb_ms: int | None = None

    def total_ms(self) -> int | None:
        """Customer-felt wait, or None until all three parts of the turn are known."""
        if self.eou_delay_ms is None or self.llm_ttft_ms is None or self.tts_ttfb_ms is None:
            return None
        return self.eou_delay_ms + self.llm_ttft_ms + self.tts_ttfb_ms


def attach_metrics(session: AgentSession, ctx: JobContext) -> None:
    """Log per-turn latency metrics and a per-session usage summary."""
    usage = metrics.UsageCollector()
    turns: dict[str, _TurnParts] = {}

    @session.on("metrics_collected")
    def _on_metrics(ev: MetricsCollectedEvent) -> None:
        m = ev.metrics
        metrics.log_metrics(m)
        usage(m)

        fields: dict[str, object]
        speech_id = getattr(m, "speech_id", None)
        if isinstance(m, metrics.EOUMetrics):
            fields = {
                "kind": "eou",
                "end_of_utterance_delay_ms": _ms(m.end_of_utterance_delay),
                "transcription_delay_ms": _ms(m.transcription_delay),
                "on_user_turn_completed_delay_ms": _ms(m.on_user_turn_completed_delay),
            }
            _part(turns, speech_id).eou_delay_ms = _ms(m.end_of_utterance_delay)
        elif isinstance(m, metrics.LLMMetrics):
            fields = {
                "kind": "llm",
                "ttft_ms": _ms(m.ttft),
                "duration_ms": _ms(m.duration),
                "prompt_tokens": m.prompt_tokens,
                "completion_tokens": m.completion_tokens,
                "cancelled": m.cancelled,
            }
            _part(turns, speech_id).llm_ttft_ms = _ms(m.ttft)
        elif isinstance(m, metrics.TTSMetrics):
            fields = {
                "kind": "tts",
                "ttfb_ms": _ms(m.ttfb),
                "duration_ms": _ms(m.duration),
                "audio_duration_ms": _ms(m.audio_duration),
                "cancelled": m.cancelled,
            }
            # A reply is often split into several TTS segments; only the first one's
            # TTFB is on the customer's wait path.
            part = _part(turns, speech_id)
            if part.tts_ttfb_ms is None:
                part.tts_ttfb_ms = _ms(m.ttfb)
        elif isinstance(m, metrics.STTMetrics):
            fields = {
                "kind": "stt",
                "duration_ms": _ms(m.duration),
                "audio_duration_ms": _ms(m.audio_duration),
            }
        else:
            return

        if speech_id:
            fields["speech_id"] = speech_id
        logger.info("turn_metrics", extra=fields)

        part = turns.get(speech_id) if speech_id else None
        total = part.total_ms() if part else None
        if speech_id and part and total is not None:
            logger.info(
                "turn_latency",
                extra={
                    "speech_id": speech_id,
                    "turn_latency_ms": total,
                    "eou_delay_ms": part.eou_delay_ms,
                    "llm_ttft_ms": part.llm_ttft_ms,
                    "tts_ttfb_ms": part.tts_ttfb_ms,
                },
            )
            del turns[speech_id]

    async def _log_usage() -> None:
        summary = usage.get_summary()
        logger.info("usage_summary", extra={"usage": summary.__dict__})

    ctx.add_shutdown_callback(_log_usage)


def _part(turns: dict[str, _TurnParts], speech_id: str | None) -> _TurnParts:
    key = speech_id or "_none"
    if key not in turns:
        turns[key] = _TurnParts()
    return turns[key]
