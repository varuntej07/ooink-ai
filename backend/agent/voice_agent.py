"""Voice pipeline wiring: STT -> LLM -> TTS, the opening greeting, and the idle watcher."""

import asyncio
import os
import time

from google.genai import types as genai_types
from livekit import api
from livekit.agents import AgentSession, JobContext, RoomInputOptions, TurnHandlingOptions
from livekit.plugins import cartesia, deepgram, google
from livekit.plugins.turn_detector.multilingual import MultilingualModel

from .pig_agent import PigAgent
from .telemetry import attach_metrics

GREETING_INSTRUCTIONS = (
    "Greet the customer warmly and very briefly as Pig, the ramen-obsessed mascot of "
    "Ooink Ramen. One or two short sentences, then invite them to ask about the menu. "
    "Do not list menu items yet."
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
MAX_OUTPUT_TOKENS = 200        # ~3 short spoken sentences; the prompts ask for 1-3


async def entrypoint(ctx: JobContext) -> None:
    pig = PigAgent()
    session = AgentSession(
        stt=deepgram.STT(model="nova-3"),
        llm=google.LLM(  # AI Studio key via GOOGLE_API_KEY
            model="gemini-2.5-flash",
            max_output_tokens=MAX_OUTPUT_TOKENS,
            safety_settings=SAFETY_SETTINGS,
        ),
        tts=cartesia.TTS(
            model="sonic-2",
            voice=os.getenv("CARTESIA_VOICE", "9626c31c-bec5-4cca-baa8-f8ba9e84c8bc"),
        ),
        vad=ctx.proc.userdata["vad"],
        turn_handling=TurnHandlingOptions(turn_detection=MultilingualModel()),
    )
    attach_metrics(session, ctx)  # per-turn latency + per-session usage logs

    # Voice-only kiosk: close the default lk.chat text channel so a token holder
    # cannot type straight into the LLM, bypassing speech.
    await session.start(
        room=ctx.room,
        agent=pig,
        room_input_options=RoomInputOptions(text_enabled=False),
    )
    await session.generate_reply(instructions=GREETING_INSTRUCTIONS)

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
