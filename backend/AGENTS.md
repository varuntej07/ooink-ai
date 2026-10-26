# Ooink Pig — LiveKit voice agent

Real-time voice agent for the Ooink kiosk. STT (Deepgram nova-3 → nova-2) → LLM (gpt-4.1 on LiveKit
Inference → Gemini 2.5 Flash, thinking off) → TTS (Cartesia sonic-3.6 → 3.5 → Deepgram Aura-2) with
menu RAG. Turn-taking, interruption, and preemptive settings are ported from Aura's voice worker
(livekit-agents 1.8.3, pinned). Deployed to **LiveKit Cloud** (free Build plan).

## Layout
- `main.py` — `AgentServer`, prewarm (Silero VAD), `@server.rtc_session(agent_name="ooink-pig")`.
- `agent/voice_agent.py` — pipeline wiring, opening greeting, 3-min idle watcher.
- `agent/pig_agent.py` — `PigAgent`; per-reply RAG routing in `llm_node` (never mutate the chat
  context in `on_user_turn_completed`: it discards the preemptive reply); `tts_node` cleanup.
- `agent/speech_text.py` — strips markdown/emoji and says prices as words before TTS.
- `agent/cartesia_cancel.py` — sends Cartesia's cancel frame on barge-in (ported from Aura).
- `agent/rag_pipeline.py` — menu lookup, single source of truth (embed via Firebase CF, cosine, threshold 0.25, top-6).
- `agent/pig_prompt.py` — both system prompts, single source of truth (the on-device Dart copy was removed).
- `assets/menu_embeddings.json` — copy of the Flutter asset (52 chunks, 768-dim). Keep in sync.

## Secrets (set in `.env.local` locally; LiveKit Cloud secrets in prod)
`LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `GOOGLE_API_KEY`, `DEEPGRAM_API_KEY`,
`CARTESIA_API_KEY`, `CARTESIA_VOICE` (optional), `EMBEDDING_FUNCTION_URL` (optional override).
See `.env.example`.

## Local dev
```bash
cd backend
python -m venv .venv && source .venv/Scripts/activate   # Windows git-bash; use .venv/bin/activate on *nix
pip install -r requirements.txt
python main.py download-files          # model weights (Silero VAD, local turn-detector fallback)
cp .env.example .env.local             # then fill in keys
python main.py dev                     # connect via the LiveKit Agent Console (agent name: ooink-pig)
```

Quick RAG check (no LiveKit needed):
```bash
python -c "import asyncio; from agent.rag_pipeline import find_relevant_context as f; \
print(asyncio.run(f('what is kotteri', []))[1]); print(asyncio.run(f('hi there', []))[0])"
# expect: a score >= 0.25 for the menu query, and 'BELOW_THRESHOLD' for the greeting
```

## Deploy to LiveKit Cloud
```bash
lk agent create        # first deploy: registers + builds from this dir + Dockerfile
lk agent deploy        # subsequent updates
```
Set secrets in the LiveKit Cloud dashboard (or `lk` secrets) — never commit real keys.

## Cost notes
- Build plan: 1,000 agent-session-min free, then $0.01/min. ~$6/mo at expected volume.
- **TTS is the cost driver** (Cartesia ≈ $0.03/min of Pig speech). If monthly TTS exceeds budget,
  swap the single `tts=` line in `voice_agent.py` to `deepgram.TTS(...)` (Aura-2 ≈ $0.018/min).
- No "cold start prevention" on the free plan → first tap after idle may lag a few seconds.
