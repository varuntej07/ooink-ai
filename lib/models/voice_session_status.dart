// Voice-session domain types, kept free of any livekit_client imports so the
// ViewModel and View depend only on this file. VoiceSessionService maps the
// livekit AgentState enum onto VoiceAgentState.

/// The agent's conversational state, surfaced to the UI.
enum VoiceAgentState { initializing, listening, thinking, speaking, idle }

/// Events VoiceSessionService emits to the ViewModel.
enum VoiceEventType {
  ready, // connected to the room, agent dispatched
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
