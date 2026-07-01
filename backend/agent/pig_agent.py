"""PigAgent — the conversational agent, with per-turn RAG routing.

Reproduces the Flutter app's dual-prompt routing inside LiveKit's single-agent model:
- Base instructions start as the persona prompt (used for the opening greeting and any
  below-threshold turn).
- On each completed user turn we run the RAG lookup. At/above threshold we switch the
  system prompt to the RAG rules and inject the retrieved menu chunks for that turn;
  below threshold we keep the persona prompt with no menu context.
"""

import time

from livekit.agents import Agent, ChatContext, ChatMessage

from .pig_prompt import PERSONA_SYSTEM_PROMPT, RAG_SYSTEM_PROMPT
from .rag_pipeline import BELOW_THRESHOLD, find_relevant_context


class PigAgent(Agent):
    def __init__(self) -> None:
        super().__init__(instructions=PERSONA_SYSTEM_PROMPT)
        self._user_history: list[str] = []          # prior user utterances, for RAG enrichment
        self.last_user_speech_at: float = time.monotonic()

    async def on_user_turn_completed(
        self, turn_ctx: ChatContext, new_message: ChatMessage
    ) -> None:
        self.last_user_speech_at = time.monotonic()
        user_text = (new_message.text_content or "").strip()
        if not user_text:
            return

        # Route on the prior history (current turn passed separately), then record it.
        context, score = await find_relevant_context(user_text, self._user_history)
        self._user_history.append(user_text)
        if len(self._user_history) > 10:
            self._user_history = self._user_history[-10:]

        if context == BELOW_THRESHOLD:
            # Greetings / small talk / off-topic: persona prompt, no menu context.
            await self.update_instructions(PERSONA_SYSTEM_PROMPT)
            return

        # Menu question: RAG rules + inject the retrieved chunks for this turn only.
        await self.update_instructions(RAG_SYSTEM_PROMPT)
        turn_ctx.add_message(
            role="assistant",
            content=(
                f"RELEVANT MENU CONTEXT (similarity {score:.2f}):\n\n{context}\n\n"
                "Use this menu context to answer the customer's question. Stay in character as Pig."
            ),
        )
