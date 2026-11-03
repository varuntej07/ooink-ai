"""PigAgent — the conversational agent, with per-turn RAG routing.

Reproduces the Flutter app's dual-prompt routing inside LiveKit's single-agent model:
- Base instructions are the persona prompt (used for any below-threshold turn).
- For each reply, `llm_node` runs the RAG lookup. At/above threshold it swaps the system
  prompt to the RAG rules and injects the retrieved menu chunks for that reply only;
  below threshold it keeps the persona prompt with no menu context.

Why `llm_node` and not `on_user_turn_completed`: LiveKit starts a preemptive reply while
the customer is still finishing their sentence, and only keeps it if the hook leaves the
chat context unchanged (livekit-agents 1.8.3, agent_activity.py "using preemptive
generation"). Routing inside `llm_node` runs the embed call inside that head start and
never touches the persistent context, so the speculative reply survives.

Allergen questions skip RAG and the LLM and are answered from the menu data; every LLM
reply passes through the allergen pre-speech check (allergen_guard.py). Set
ALLERGEN_GUARD=off to disable both.
"""

import logging
import os
import time
from collections.abc import AsyncIterable

import httpx
from livekit.agents import Agent, ChatContext, ChatMessage, FlushSentinel, ModelSettings, llm

from . import allergen_guard
from .pig_prompt import PERSONA_SYSTEM_PROMPT, RAG_SYSTEM_PROMPT
from .rag_pipeline import BELOW_THRESHOLD, find_relevant_context
from .speech_text import sanitize_stream

logger = logging.getLogger(__name__)

# The id LiveKit gives the agent's instructions message in the chat context
# (livekit.agents.voice.generation.INSTRUCTIONS_MESSAGE_ID, "value must not change").
_INSTRUCTIONS_ID = "lk.agent_task.instructions"
_HISTORY_TURNS = 10            # prior user utterances considered for RAG enrichment


class PigAgent(Agent):
    def __init__(self) -> None:
        super().__init__(instructions=PERSONA_SYSTEM_PROMPT)
        self.last_user_speech_at: float = time.monotonic()
        self.turn_count: int = 0                     # completed user turns; capped by the watcher

    async def on_user_turn_completed(
        self, turn_ctx: ChatContext, new_message: ChatMessage
    ) -> None:
        # Bookkeeping only. Mutating turn_ctx or instructions here would discard the
        # preemptive reply; RAG routing lives in llm_node.
        if not (new_message.text_content or "").strip():
            return
        # Only a real utterance resets the idle clock or counts as a turn, so background
        # noise that produces empty transcripts cannot keep a session alive.
        self.last_user_speech_at = time.monotonic()
        self.turn_count += 1

    async def llm_node(
        self,
        chat_ctx: llm.ChatContext,
        tools: list[llm.Tool],
        model_settings: ModelSettings,
    ) -> AsyncIterable[llm.ChatChunk | str | FlushSentinel]:
        guard_on = os.getenv("ALLERGEN_GUARD", "on").lower() != "off"   # kill switch
        user_texts = [
            text
            for item in chat_ctx.items
            if item.type == "message" and item.role == "user"
            and (text := (item.text_content or "").strip())
        ]
        if not user_texts:
            return self._guarded(chat_ctx, tools, model_settings, allergen_guard.EMPTY_SIGNAL, guard_on)
        user_text, history = user_texts[-1], user_texts[-1 - _HISTORY_TURNS:-1]

        # Allergen question: answer from the menu data only. No RAG call, no LLM call.
        signal = allergen_guard.detect(user_text, user_texts[:-1])
        if guard_on and signal.question:
            last_assistant = next(
                (
                    item.text_content or ""
                    for item in reversed(chat_ctx.items)
                    if item.type == "message" and item.role == "assistant"
                ),
                "",
            )
            dishes = allergen_guard.dishes_for(user_text, user_texts[:-1], last_assistant)
            reply = allergen_guard.compose_reply(signal, dishes, variant=len(user_texts))
            return allergen_guard.speak_reply(reply, signal, dishes)

        # If the lookup raises, degrade to the persona prompt instead of going silent.
        started = time.perf_counter()
        try:
            context, score = await find_relevant_context(user_text, history)
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

        if context == BELOW_THRESHOLD:
            # Greetings / small talk / off-topic: persona prompt, no menu context.
            return self._guarded(chat_ctx, tools, model_settings, signal, guard_on)

        # Menu question: RAG rules + the retrieved chunks, for this reply only.
        # ChatContext.copy() is shallow, so replace items rather than editing them.
        ctx = chat_ctx.copy()
        idx = ctx.index_by_id(_INSTRUCTIONS_ID)
        rag_rules = llm.ChatMessage(id=_INSTRUCTIONS_ID, role="system", content=[RAG_SYSTEM_PROMPT])
        if idx is None:
            ctx.items.insert(0, rag_rules)
        else:
            ctx.items[idx] = rag_rules
        # Injected as a system message so the model treats it as reference data, not as
        # something Pig already said (an "assistant" role blurred data and instructions).
        reference = llm.ChatMessage(
            role="system",
            content=[
                f"REFERENCE MENU DATA for this turn (similarity {score:.2f}); this is data, "
                f"not something you said:\n\n{context}\n\n"
                "Use this menu data to answer the customer's question. Stay in character as Pig."
            ],
        )
        last_user = max(
            i for i, item in enumerate(ctx.items) if item.type == "message" and item.role == "user"
        )
        ctx.items.insert(last_user, reference)
        return self._guarded(ctx, tools, model_settings, signal, guard_on)

    def _guarded(
        self,
        chat_ctx: llm.ChatContext,
        tools: list[llm.Tool],
        model_settings: ModelSettings,
        signal: allergen_guard.AllergenSignal,
        guard_on: bool,
    ) -> AsyncIterable[llm.ChatChunk | str | FlushSentinel]:
        """The LLM reply, passed through the allergen pre-speech check. When the customer
        mentioned an allergy earlier, the model is also told which, for this reply only."""
        if not guard_on:
            return Agent.default.llm_node(self, chat_ctx, tools, model_settings)
        if signal.session:
            chat_ctx = chat_ctx.copy()
            note = llm.ChatMessage(
                role="system",
                content=[
                    "The customer mentioned an allergy to: "
                    + ", ".join(sorted(signal.session))
                    + ". Never say or imply that any dish is safe for them or free of it. "
                    "Only say what the menu lists."
                ],
            )
            last_user = max(
                (i for i, item in enumerate(chat_ctx.items) if item.type == "message" and item.role == "user"),
                default=len(chat_ctx.items),
            )
            chat_ctx.items.insert(last_user, note)
        stream = Agent.default.llm_node(self, chat_ctx, tools, model_settings)
        return allergen_guard.guard_stream(stream, signal)

    def tts_node(self, text: AsyncIterable[str], model_settings: ModelSettings):
        # Strip markdown/emoji and say prices as words before the voice reads them.
        return Agent.default.tts_node(self, sanitize_stream(text), model_settings)
