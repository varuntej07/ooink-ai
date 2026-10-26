"""Voice pipeline wiring: STT -> LLM -> TTS, the opening greeting, and the idle watcher."""

import asyncio
import logging
import os
import random
import time

from google.genai import types as genai_types
from livekit import api, rtc
from livekit.agents import (
    AgentSession,
    JobContext,
    TurnHandlingOptions,
    inference,
    llm,
    room_io,
    stt,
    tts,
)
from livekit.plugins import ai_coustics, deepgram, google

from . import rag_pipeline
from .cartesia_cancel import CancellingCartesiaTTS
from .pig_agent import PigAgent
from .telemetry import attach_metrics

logger = logging.getLogger(__name__)

# Spoken with session.say, so the first words need no LLM round trip.
GREETINGS = (
    "Oink! I'm Pig. Ask me anything about our ramen.",
    "Hey there, I'm Pig! Curious what's in the bowls today?",
    "Oink oink! I'm Pig, Ooink's resident ramen expert. What sounds good?",
)

GOODBYE = (
    "Oink! Looks like things got quiet out here. I'll be right here if you have more "
    "questions, come find me!"
)

IDLE_TIMEOUT_SECONDS = 180     # 3 min of no user speech: the customer walked away
IDLE_CHECK_INTERVAL = 15

# Hard caps so a scripted client (or looping audio) cannot keep one paid session
# alive indefinitely. A real menu conversation is a few minutes and a dozen turns.
MAX_SESSION_SECONDS = 15 * 60
MAX_TURNS = 60

# Gemini safety thresholds: the reply is spoken aloud in public under the
# restaurant's brand, so block anything the model itself rates medium-or-worse.
SAFETY_SETTINGS: list[genai_types.SafetySettingOrDict] = [
    genai_types.SafetySetting(
        category=genai_types.HarmCategory.HARM_CATEGORY_HARASSMENT,
        threshold=genai_types.HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
    ),
    genai_types.SafetySetting(
        category=genai_types.HarmCategory.HARM_CATEGORY_HATE_SPEECH,
        threshold=genai_types.HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
    ),
    genai_types.SafetySetting(
        category=genai_types.HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT,
        threshold=genai_types.HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
    ),
    genai_types.SafetySetting(
        category=genai_types.HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT,
        threshold=genai_types.HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
    ),
]
# A runaway ceiling, not a brevity control: reply length is set by the prompts. The old
# 200 was shared with Gemini's thinking tokens, which could truncate replies.
MAX_OUTPUT_TOKENS = 300

PIG_VOICE = os.getenv("CARTESIA_VOICE", "9626c31c-bec5-4cca-baa8-f8ba9e84c8bc")

# Deepgram keyterm prompting (nova-3): menu words customers say that STT otherwise
# mishears ("cot terry", "show you"). Deepgram's guidance is 20-50 terms.
MENU_KEYTERMS = [
    "Ooink", "Kotteri", "Mala Kotteri", "Mala", "Shoyu", "Shio", "Mapo Tofu", "Gyoza",
    "Ayam Goreng", "Miso", "Dashi", "Shanghai", "tare", "ramen", "Sichuan",
    "Capitol Hill", "Fremont", "Chef Ooi",
]


def _build_stt() -> stt.FallbackAdapter:
    """Deepgram nova-3 (with menu keyterms) -> nova-2. Values match Aura's pipeline."""
    return stt.FallbackAdapter(
        [
            deepgram.STT(model="nova-3", language="multi", mip_opt_out=True, keyterm=MENU_KEYTERMS),
            deepgram.STT(model="nova-2", language="multi", mip_opt_out=True),  # rejects keyterm
        ],
        attempt_timeout=10.0,
        max_retry_per_stt=0,
    )


def _build_llm() -> llm.FallbackAdapter:
    """gpt-4.1 on LiveKit Inference (LIVEKIT_API_KEY/SECRET) -> Gemini 2.5 Flash.

    attempt_timeout=2.5: healthy first tokens land well under 2 s, so a stalled
    provider fails over instead of leaving the customer in silence. Gemini runs with
    thinking off (thinking_budget=0); its default dynamic thinking delays the first
    token and spends the output budget on thoughts.
    """
    return llm.FallbackAdapter(
        [
            inference.LLM(
                model="openai/gpt-4.1",
                extra_kwargs={"temperature": 0.7, "max_completion_tokens": MAX_OUTPUT_TOKENS},
            ),
            google.LLM(  # AI Studio key via GOOGLE_API_KEY
                model="gemini-2.5-flash",
                temperature=0.7,
                max_output_tokens=MAX_OUTPUT_TOKENS,
                thinking_config={"thinking_budget": 0},
                safety_settings=SAFETY_SETTINGS,
            ),
        ],
        attempt_timeout=2.5,
        max_retry_per_llm=0,
    )


def _build_tts() -> tts.FallbackAdapter:
    """Cartesia sonic-3.6 -> sonic-3.5 (same Pig voice) -> Deepgram Aura-2 (outage only).

    CancellingCartesiaTTS tells Cartesia to stop when a reply is cut short (barge-in or
    a discarded preemptive reply) instead of generating audio nobody hears.
    """
    return tts.FallbackAdapter(
        [
            CancellingCartesiaTTS(model="sonic-3.6", voice=PIG_VOICE),
            CancellingCartesiaTTS(model="sonic-3.5", voice=PIG_VOICE),
            deepgram.TTS(model="aura-2-andromeda-en"),
        ],
        max_retry_per_tts=0,
    )


def _build_turn_handling() -> TurnHandlingOptions:
    """Turn-taking tuned like Aura (livekit-agents 1.8.3).

    - Audio end-of-turn model (runs alongside STT, unlike the old text MultilingualModel).
      The key is set only when construction succeeds: an explicit None would silently
      drop to VAD-only turn detection.
    - Dynamic endpointing 0.3-1.0 s. If customers get cut off mid-sentence, raise
      max_delay first.
    - Adaptive interruptions: backchannels ("yeah", "mm-hm") don't cut Pig off, and a
      false interruption resumes speech after 1.5 s.
    - Preemptive LLM and TTS, so the reply is often ready when the customer stops.
    """
    turn_handling = TurnHandlingOptions(
        endpointing={"mode": "dynamic", "min_delay": 0.3, "max_delay": 1.0},
        interruption={
            "mode": "adaptive",
            "min_duration": 0.5,
            "false_interruption_timeout": 1.5,
            "resume_false_interruption": True,
        },
        preemptive_generation={
            "enabled": True,
            "preemptive_tts": True,
            "max_retries": 6,
            "max_speech_duration": 20.0,
        },
    )
    try:
        turn_handling["turn_detection"] = inference.TurnDetector()
    except Exception:
        logger.exception("audio turn detector unavailable; using the session default")
    return turn_handling


def _noise_cancellation(params: room_io.types.NoiseCancellationParams):
    """ai-coustics voice isolation on the customer's mic: suppresses the queue's voices
    and street noise, not just steady background noise. Agents are skipped because
    isolation is billed per minute and their audio is already clean TTS."""
    if params.participant.kind == rtc.ParticipantKind.PARTICIPANT_KIND_AGENT:
        return None
    return ai_coustics.audio_enhancement(model=ai_coustics.EnhancerModel.QUAIL_VF_S)


async def entrypoint(ctx: JobContext) -> None:
    # Wake the embedding Cloud Function while the greeting plays ($0: one call).
    asyncio.create_task(rag_pipeline.warm_embedding())

    pig = PigAgent()
    session = AgentSession(
        stt=_build_stt(),
        llm=_build_llm(),
        tts=_build_tts(),
        vad=ctx.proc.userdata["vad"],
        turn_handling=_build_turn_handling(),
    )
    attach_metrics(session, ctx)  # per-turn latency + per-session usage logs

    # Voice-only kiosk: text_input=False closes the default lk.chat text channel so a
    # token holder cannot type straight into the LLM, bypassing speech.
    await session.start(
        room=ctx.room,
        agent=pig,
        room_options=room_io.RoomOptions(
            text_input=False,
            audio_input=room_io.AudioInputOptions(
                sample_rate=16000, frame_size_ms=20, noise_cancellation=_noise_cancellation
            ),
            audio_output=room_io.AudioOutputOptions(sample_rate=24000),
        ),
    )
    session.say(random.choice(GREETINGS))

    asyncio.create_task(_session_watcher(ctx, session, pig, started_at=time.monotonic()))


async def _session_watcher(
    ctx: JobContext, session: AgentSession, pig: PigAgent, *, started_at: float
) -> None:
    """End the session on 3 min of silence (kiosk walked away), or at the hard
    duration / turn caps (cost abuse guard). All three paths say goodbye first."""
    while True:
        await asyncio.sleep(IDLE_CHECK_INTERVAL)
        now = time.monotonic()
        idle = now - pig.last_user_speech_at >= IDLE_TIMEOUT_SECONDS
        too_long = now - started_at >= MAX_SESSION_SECONDS
        too_many = pig.turn_count >= MAX_TURNS
        if not (idle or too_long or too_many):
            continue
        try:
            await session.say(GOODBYE, allow_interruptions=False)
            await asyncio.sleep(1.0)  # let the goodbye finish
        finally:
            await _end_room(ctx)
        return


async def _end_room(ctx: JobContext) -> None:
    """Delete the room so the Flutter kiosk gets RoomDisconnected and returns to idle."""
    room_name = ctx.room.name
    lkapi = getattr(ctx, "api", None)
    created = False
    if lkapi is None:
        lkapi = api.LiveKitAPI()  # reads LIVEKIT_URL/API_KEY/API_SECRET from env
        created = True
    try:
        await lkapi.room.delete_room(api.DeleteRoomRequest(room=room_name))
    except Exception:
        try:
            await ctx.room.disconnect()
        except Exception:
            pass
    finally:
        if created:
            await lkapi.aclose()
