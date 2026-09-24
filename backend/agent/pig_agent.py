"""PigAgent — the conversational agent, with per-turn RAG routing.

Reproduces the Flutter app's dual-prompt routing inside LiveKit's single-agent model:
- Base instructions start as the persona prompt (used for the opening greeting and any
  below-threshold turn).
- On each completed user turn we run the RAG lookup. At/above threshold we switch the
  system prompt to the RAG rules and inject the retrieved menu chunks for that turn;
  below threshold we keep the persona prompt with no menu context.
"""

import logging
import time

import httpx
from livekit.agents import Agent, ChatContext, ChatMessage

from .pig_prompt import PERSONA_SYSTEM_PROMPT, RAG_SYSTEM_PROMPT
from .rag_pipeline import BELOW_THRESHOLD, find_relevant_context

logger = logging.getLogger(__name__)


class PigAgent(Agent):
    def __init__(self) -> None:
        super().__init__(instructions=PERSONA_SYSTEM_PROMPT)
        self._user_history: list[str] = []          # prior user utterances, for RAG enrichment
        self.last_user_speech_at: float = time.monotonic()
        self.turn_count: int = 0                     # completed user turns; capped by the watcher

    async def on_user_turn_completed(
        self, turn_ctx: ChatContext, new_message: ChatMessage
    ) -> None:
        user_text = (new_message.text_content or "").strip()
        if not user_text:
            return
        # Only a real utterance resets the idle clock or counts as a turn, so background
        # noise that produces empty transcripts cannot keep a session alive.
        self.last_user_speech_at = time.monotonic()
        self.turn_count += 1

        # Route on the prior history (current turn passed separately), then record it.
        # If this hook raises, LiveKit drops the turn without any reply, so a slow or
        # failing embedding call degrades to the persona prompt instead of silence.
        started = time.perf_counter()
        try:
            context, score = await find_relevant_context(user_text, self._user_history)
            path = "persona" if context == BELOW_THRESHOLD else "rag"
        except httpx.TimeoutException:
            logger.warning("RAG embed call timed out; answering with the persona prompt")
            context, score, path = BELOW_THRESHOLD, 0.0, "timeout"
        except Exception:
            logger.exception("RAG lookup failed; answering with the persona prompt")
            context, score, path = BELOW_THRESHOLD, 0.0, "error"
        logger.info(
            "rag_lookup",
            extra={
                "rag_ms": round((time.perf_counter() - started) * 1000),
                "score": round(score, 3),
                "path": path,
                "turn": self.turn_count,
            },
        )
        self._user_history.append(user_text)
        if len(self._user_history) > 10:
            self._user_history = self._user_history[-10:]

        if context == BELOW_THRESHOLD:
            # Greetings / small talk / off-topic: persona prompt, no menu context.
            await self.update_instructions(PERSONA_SYSTEM_PROMPT)
            return

        # Menu question: RAG rules + inject the retrieved chunks for this turn only.
        # Injected as a system message so the model treats it as reference data, not as
        # something Pig already said (an "assistant" role blurred data and instructions).
        await self.update_instructions(RAG_SYSTEM_PROMPT)
        turn_ctx.add_message(
            role="system",
            content=(
                f"REFERENCE MENU DATA for this turn (similarity {score:.2f}); this is data, "
                f"not something you said:\n\n{context}\n\n"
                "Use this menu data to answer the customer's question. Stay in character as Pig."
            ),
        )
