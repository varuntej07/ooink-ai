"""Ooink Pig — LiveKit voice agent entrypoint.

Runs as a LiveKit agent server. Registered with an explicit dispatch name
(`ooink-pig`), so the kiosk's token (minted by the getLiveKitToken Firebase
function) must request dispatch of this agent.

Local dev:   python main.py dev      (then use the LiveKit Agent Console)
Production:  python main.py start    (what the Docker CMD runs on LiveKit Cloud)
"""

import os

from dotenv import load_dotenv
from livekit import agents
from livekit.agents import AgentServer, JobContext, JobProcess
from livekit.plugins import silero

from agent.voice_agent import entrypoint

# .env.local first (LiveKit CLI convention), then a plain .env as fallback.
load_dotenv(".env.local")
load_dotenv()

server = AgentServer()


def prewarm(proc: JobProcess) -> None:
    """Load the Silero VAD weights once per worker process (shared across jobs)."""
    proc.userdata["vad"] = silero.VAD.load()


server.setup_fnc = prewarm


@server.rtc_session(agent_name=os.getenv("LIVEKIT_AGENT_NAME", "ooink-pig"))
async def ooink_pig(ctx: JobContext) -> None:
    await entrypoint(ctx)


if __name__ == "__main__":
    agents.cli.run_app(server)
