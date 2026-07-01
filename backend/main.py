"""Ooink Pig — LiveKit voice agent entrypoint.

Runs as a LiveKit agent server. Registered with an explicit dispatch name
(`ooink-pig`), so the kiosk's token (minted by the getLiveKitToken Firebase
function) must request dispatch of this agent.

Local dev:   python main.py dev      (then use the LiveKit Agent Console)
Production:  python main.py start    (what the Docker CMD runs on LiveKit Cloud)
"""

import os
from pathlib import Path

from dotenv import load_dotenv
from livekit import agents
from livekit.agents import AgentServer, JobContext, JobProcess
from livekit.plugins import silero

from agent.voice_agent import entrypoint

# .env.local first (LiveKit CLI convention), then a plain .env as fallback.
# Anchor to this file's directory (not the CWD): LiveKit spawns each job in a
# subprocess that re-imports this module, often from a different working
# directory, so a relative ".env.local" wouldn't be found and the job would
# crash with "GOOGLE_API_KEY is required". An absolute path loads the keys in
# both the worker and every spawned job process.
_ENV_DIR = Path(__file__).resolve().parent
load_dotenv(_ENV_DIR / ".env.local")
load_dotenv(_ENV_DIR / ".env")

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
