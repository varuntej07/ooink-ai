"""Voice pipeline wiring: STT -> LLM -> TTS, the opening greeting, and the idle watcher."""

import asyncio
import os
import time

from livekit import api
from livekit.agents import AgentSession, JobContext, TurnHandlingOptions
from livekit.plugins import cartesia, deepgram, google
from livekit.plugins.turn_detector.multilingual import MultilingualModel

from .pig_agent import PigAgent

GREETING_INSTRUCTIONS = (
    "Greet the customer warmly and very briefly as Pig, the ramen-obsessed mascot of "
    "Ooink Ramen. One or two short sentences, then invite them to ask about the menu. "
    "Do not list menu items yet."
)

GOODBYE = (
    "Oink! Looks like things got quiet out here. I'll be right here if you have more "
    "questions, come find me!"
)

IDLE_TIMEOUT_SECONDS = 180     # mirrors the planned 3-minute server-side idle end
IDLE_CHECK_INTERVAL = 15


async def entrypoint(ctx: JobContext) -> None:
    pig = PigAgent()
    session = AgentSession(
        stt=deepgram.STT(model="nova-3"),
        llm=google.LLM(model="gemini-2.5-flash"),  # AI Studio key via GOOGLE_API_KEY
        tts=cartesia.TTS(
            model="sonic-2",
            voice=os.getenv("CARTESIA_VOICE", "9626c31c-bec5-4cca-baa8-f8ba9e84c8bc"),
        ),
        vad=ctx.proc.userdata["vad"],
        turn_handling=TurnHandlingOptions(turn_detection=MultilingualModel()),
    )

    await session.start(room=ctx.room, agent=pig)
    await session.generate_reply(instructions=GREETING_INSTRUCTIONS)

    asyncio.create_task(_idle_watcher(ctx, session, pig))


async def _idle_watcher(ctx: JobContext, session: AgentSession, pig: PigAgent) -> None:
    """End the session after 3 minutes of no user speech (kiosk walked away)."""
    while True:
        await asyncio.sleep(IDLE_CHECK_INTERVAL)
        if time.monotonic() - pig.last_user_speech_at < IDLE_TIMEOUT_SECONDS:
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
