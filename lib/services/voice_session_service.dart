import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';

import '../config/app_config.dart';
import '../models/voice_session_status.dart';
import '../utils/logger.dart';

/// Wraps the livekit_client high-level [Session]. The Session connects to the
/// room, dispatches the Pig agent, enables the mic, and exposes agent state +
/// transcripts as a [ChangeNotifier]. This service translates those into a
/// stream of [VoiceServerEvent]s so the ViewModel stays free of LiveKit types.
class VoiceSessionService {
  Session? _session;

  final _events = StreamController<VoiceServerEvent>.broadcast();
  Stream<VoiceServerEvent> get events => _events.stream;

  // Diffing state so we only emit when something actually changes.
  VoiceAgentState? _lastAgentState;
  final Map<String, String> _lastTextById = {};
  final Set<String> _finalizedIds = {};
  bool _connectedOnce = false;
  bool _ended = false;
  bool _errored = false;

  /// Fetches a token from the getLiveKitToken function and connects.
  Future<void> startSession() async {
    _resetState();

    // Our function returns {token, url, room}; map it onto the shape Session wants.
    final tokenSource = CustomTokenSource((options) async {
      final resp = await http.get(Uri.parse(AppConfig.voiceTokenUrl));
      if (resp.statusCode != 200) {
        throw Exception('Token endpoint returned ${resp.statusCode}');
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return TokenSourceResponse(
        serverUrl: data['url'] as String,
        participantToken: data['token'] as String,
        roomName: data['room'] as String?,
      );
    });

    final session = Session.fromConfigurableTokenSource(tokenSource);
    _session = session;
    session.addListener(_onSessionChanged);

    try {
      await session.start();
      _events.add(const VoiceServerEvent(type: VoiceEventType.ready));
    } catch (e, st) {
      Logger.error('Voice session failed to start', e, st);
      _emitError('Voice connection failed. Tap to try again.');
    }
  }

  void _onSessionChanged() {
    final session = _session;
    if (session == null) return;

    if (session.connectionState == ConnectionState.connected) {
      _connectedOnce = true;
    }

    // Surface a session-level error once.
    if (session.error != null && !_errored) {
      _emitError('Voice connection dropped. Tap to try again.');
      return;
    }

    _emitAgentState(session.agent.agentState);
    _emitTranscripts(session.messages);

    // Room closed (user tapped stop, or the agent's idle watcher deleted the room).
    if (_connectedOnce &&
        session.connectionState == ConnectionState.disconnected &&
        !_ended) {
      _flushFinals(session.messages);
      _ended = true;
      _events.add(const VoiceServerEvent(type: VoiceEventType.ended));
    }
  }

  void _emitAgentState(AgentState? state) {
    final mapped = _mapAgentState(state);
    if (mapped == null || mapped == _lastAgentState) return;
    _lastAgentState = mapped;
    _events.add(VoiceServerEvent(type: VoiceEventType.agentState, agentState: mapped));
  }

  void _emitTranscripts(List<ReceivedMessage> messages) {
    if (messages.isEmpty) return;
    final lastId = messages.last.id;

    for (final m in messages) {
      final parsed = _transcriptOf(m);
      if (parsed == null) continue;
      final (isUser, text) = parsed;

      // Live update for display whenever the text grows/changes.
      if (_lastTextById[m.id] != text) {
        _lastTextById[m.id] = text;
        _events.add(VoiceServerEvent(
          type: isUser ? VoiceEventType.userTranscript : VoiceEventType.agentTranscript,
          text: text,
        ));
      }

      // A transcript is final once a newer message supersedes it.
      if (m.id != lastId && text.trim().isNotEmpty && _finalizedIds.add(m.id)) {
        _events.add(VoiceServerEvent(
          type: isUser ? VoiceEventType.userFinal : VoiceEventType.agentFinal,
          text: text,
        ));
      }
    }
  }

  /// On disconnect, flush the still-open last turns as final so they get logged.
  void _flushFinals(List<ReceivedMessage> messages) {
    for (final m in messages) {
      final parsed = _transcriptOf(m);
      if (parsed == null) continue;
      final (isUser, text) = parsed;
      if (text.trim().isEmpty || !_finalizedIds.add(m.id)) continue;
      _events.add(VoiceServerEvent(
        type: isUser ? VoiceEventType.userFinal : VoiceEventType.agentFinal,
        text: text,
      ));
    }
  }

  /// Returns (isUser, text) for transcript messages, or null for non-transcripts.
  (bool, String)? _transcriptOf(ReceivedMessage m) {
    final c = m.content;
    if (c is UserTranscript) return (true, c.text);
    if (c is AgentTranscript) return (false, c.text);
    return null; // UserInput (typed) — not used by this voice-only kiosk
  }

  VoiceAgentState? _mapAgentState(AgentState? s) => switch (s) {
        AgentState.initializing => VoiceAgentState.initializing,
        AgentState.listening => VoiceAgentState.listening,
        AgentState.thinking => VoiceAgentState.thinking,
        AgentState.speaking => VoiceAgentState.speaking,
        AgentState.idle => VoiceAgentState.idle,
        null => null,
      };

  void _emitError(String message) {
    if (_errored) return;
    _errored = true;
    _events.add(VoiceServerEvent(type: VoiceEventType.error, errorMessage: message));
  }

  void _resetState() {
    _lastAgentState = null;
    _lastTextById.clear();
    _finalizedIds.clear();
    _connectedOnce = false;
    _ended = false;
    _errored = false;
  }

  /// Ends the session (user tapped stop). Disconnects the room.
  Future<void> endSession() async {
    final session = _session;
    if (session == null) return;
    session.removeListener(_onSessionChanged);
    _session = null;
    try {
      await session.end();
    } catch (e, st) {
      Logger.error('Error ending voice session', e, st);
    }
    await session.dispose();
  }

  void dispose() {
    _session?.removeListener(_onSessionChanged);
    final session = _session;
    _session = null;
    if (session != null) {
      session.end();
      session.dispose();
    }
    _events.close();
  }
}
