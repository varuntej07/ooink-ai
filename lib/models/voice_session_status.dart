// Voice-session domain types, kept free of any livekit_client imports so the
// ViewModel and View depend only on this file. VoiceSessionService maps the
// livekit AgentState enum onto VoiceAgentState.

/// The agent's conversational state, surfaced to the UI.
enum VoiceAgentState { initializing, listening, thinking, speaking, idle }

/// Events VoiceSessionService emits to the ViewModel.
enum VoiceEventType {
  ready, // ROOM connected (agent dispatch requested) — NOT yet agent-ready. The UI
  // stays in "Connecting…" until the first agentState arrives; if the agent never
  // joins, an `error` event is emitted instead. Live audio amplitudes for the wave
  // bars travel on VoiceSessionService.audioLevels, a separate stream.
  agentState, // agent conversational state changed
  userTranscript, // live user speech-to-text (for display)
  agentTranscript, // live agent text (for display)
  userFinal, // a user turn finalized (log to Firestore)
  agentFinal, // an agent turn finalized (log to Firestore)
  ended, // session disconnected
  error,
}

class VoiceServerEvent {
  final VoiceEventType type;
  final String? text;
  final VoiceAgentState? agentState;
  final String? errorMessage;

  const VoiceServerEvent({
    required this.type,
    this.text,
    this.agentState,
    this.errorMessage,
  });
}
