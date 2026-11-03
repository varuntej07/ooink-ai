"""Template (no-LLM) turns still get a turn_latency line; LLM turns are left alone."""

import logging

from agent import telemetry
from agent.telemetry import _TurnParts


def test_flush_logs_only_finished_no_llm_turns(caplog):
    turns = {
        "template": _TurnParts(eou_delay_ms=400, tts_ttfb_ms=200),
        "llm_pending": _TurnParts(eou_delay_ms=400, llm_ttft_ms=None, tts_ttfb_ms=None),
        "llm_done": _TurnParts(eou_delay_ms=400, llm_ttft_ms=900, tts_ttfb_ms=200),
    }
    with caplog.at_level(logging.INFO, logger=telemetry.__name__):
        telemetry._flush_no_llm_turns(turns)
    records = [r for r in caplog.records if r.getMessage() == "turn_latency"]
    assert len(records) == 1
    assert records[0].__dict__["turn_latency_ms"] == 600
    assert records[0].__dict__["path"] == "no_llm"
    assert set(turns) == {"llm_pending", "llm_done"}
