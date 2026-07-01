import 'dart:async';
import 'package:flutter/foundation.dart'
    show ChangeNotifier, ValueListenable, ValueNotifier, visibleForTesting;
import '../models/voice_session_status.dart';
import '../services/analytics_service.dart';
import '../services/voice_session_service.dart';
import '../repositories/session_repository.dart';
import '../utils/logger.dart';

/// Enum representing the different states of conversation.
/// Values are unchanged from the previous on-device pipeline so the View's
/// animation/status logic keeps working.
enum ConversationState {
  idle, // Waiting for user to tap Talk
  listening, // Connected, Pig is listening
  processing, // Connecting, or Pig is thinking
  speaking, // Pig is speaking
  error,
}

/// ViewModel for the conversation flow.
///
/// STT, the LLM, TTS, and the menu RAG pipeline all run server-side in the
/// LiveKit agent now. This ViewModel is a thin wrapper over [VoiceSessionService]:
/// it maps voice events to [ConversationState], mirrors transcripts for display,
/// and keeps logging sessions/messages to Firestore + Analytics exactly as before.
class ConversationViewModel extends ChangeNotifier {
  final VoiceSessionService _voiceService;
  final SessionRepository _sessionRepository;
  final AnalyticsService _analyticsService;

  ConversationState _state = ConversationState.idle;
  String _userInput = '';
  String _aiResponse = '';
  String _errorMessage = '';

  // Tracks when the session started so we can compute duration for session_ended.
  DateTime? _sessionStartTime;

  // Failsafe inactivity timer. The real 3-minute idle end happens server-side
  // (the agent says goodbye and deletes the room); this is only a backup in
  // case connectivity drops and no `ended` event arrives.
  Timer? _inactivityTimer;
  static const Duration _sessionTimeout = Duration(minutes: 5);

  StreamSubscription<VoiceServerEvent>? _voiceSub;
  StreamSubscription<List<double>>? _audioLevelsSub;

  // Real-time wave-bar amplitudes for the Pig's voice. Exposed as a ValueListenable
  // so only the wave widget rebuilds on each audio frame — not the whole Consumer
  // tree (which would thrash at audio frame rate).
  final ValueNotifier<List<double>> _audioLevels = ValueNotifier<List<double>>(const []);
  ValueListenable<List<double>> get audioLevels => _audioLevels;

  ConversationViewModel({
    required VoiceSessionService voiceService,
    required SessionRepository sessionRepository,
    required AnalyticsService analyticsService,
  })  : _voiceService = voiceService,
        _sessionRepository = sessionRepository,
        _analyticsService = analyticsService {
    _voiceSub = _voiceService.events.listen(_handleVoiceEvent);
    _audioLevelsSub = _voiceService.audioLevels.listen((levels) {
      _audioLevels.value = levels;
    });
  }

  // Getters
  ConversationState get state => _state;
  String get userInput => _userInput;
  String get aiResponse => _aiResponse;
  String get errorMessage => _errorMessage;
  bool get isIdle => _state == ConversationState.idle;
  bool get isListening => _state == ConversationState.listening;
  bool get isProcessing => _state == ConversationState.processing;
  bool get isSpeaking => _state == ConversationState.speaking;
  bool get hasError => _state == ConversationState.error;

  /// Nothing heavy to load on-device anymore (no embeddings/STT/TTS models).
  /// Kept so main.dart's startup flow doesn't need to change shape.
  Future<void> initialize() async {}

  /// Starts a voice conversation — fetches a token, connects to LiveKit, and
  /// the Pig agent is dispatched into the room.
  Future<void> startSession() async {
    if (_state != ConversationState.idle && _state != ConversationState.error) {
      return;
    }
    _userInput = '';
    _aiResponse = '';
    _errorMessage = '';
    _updateState(ConversationState.processing); // shows "Connecting…"
    await _voiceService.startSession();
  }

  /// Ends the voice conversation (user tapped Stop).
  Future<void> endSession() async {
    await _voiceService.endSession();
    _teardownSession(endedBy: 'user');
    _updateState(ConversationState.idle);
  }

  void _handleVoiceEvent(VoiceServerEvent event) {
    switch (event.type) {
      case VoiceEventType.ready:
        // Room connected, but the Pig agent hasn't necessarily joined yet. Create
        // the Firestore session, but stay in "Connecting…" (processing) until a real
        // agent state arrives via VoiceEventType.agentState. If the agent never joins,
        // the service emits an error instead (no more silent, fake "Listening").
        _ensureSession();
        _resetInactivityTimer();
        break;

      case VoiceEventType.agentState:
        _applyAgentState(event.agentState);
        break;

      case VoiceEventType.userTranscript:
        _userInput = event.text ?? '';
        _aiResponse = ''; // clear old answer while the user is asking
        _resetInactivityTimer();
        notifyListeners();
        break;

      case VoiceEventType.agentTranscript:
        _aiResponse = event.text ?? '';
        notifyListeners();
        break;

      case VoiceEventType.userFinal:
        final text = (event.text ?? '').trim();
        if (text.isNotEmpty) {
          _sessionRepository.addUserMessage(text); // Firestore log
          // Score/path/latency now live server-side; log the query as a count.
          _analyticsService.logQuerySent(
            path: 'voice',
            similarityScore: 0.0,
            responseLatencyMs: 0,
          );
        }
        _resetInactivityTimer();
        break;

      case VoiceEventType.agentFinal:
        final text = (event.text ?? '').trim();
        if (text.isNotEmpty) {
          _sessionRepository.addAssistantMessage(text); // Firestore log
        }
        break;

      case VoiceEventType.ended:
        _teardownSession(endedBy: 'agent');
        _updateState(ConversationState.idle);
        break;

      case VoiceEventType.error:
        _voiceService.endSession();
        _teardownSession(endedBy: 'error');
        _setError(event.errorMessage ?? 'Voice connection failed. Tap to try again.');
        break;
    }
  }

  void _applyAgentState(VoiceAgentState? s) {
    switch (s) {
      case VoiceAgentState.listening:
      case VoiceAgentState.idle:
        _updateState(ConversationState.listening);
        break;
      case VoiceAgentState.initializing:
      case VoiceAgentState.thinking:
        _updateState(ConversationState.processing);
        break;
      case VoiceAgentState.speaking:
        _updateState(ConversationState.speaking);
        break;
      case null:
        break;
    }
  }

  /// Ensures a Firestore session exists; created lazily once the room connects.
  Future<void> _ensureSession() async {
    if (!_sessionRepository.hasActiveSession) {
      await _sessionRepository.startSession();
      _sessionStartTime = DateTime.now();
      _analyticsService.logSessionStarted(
        hourOfDay: _sessionStartTime!.hour,
        dayOfWeek: _sessionStartTime!.weekday,
      );
      Logger.session('New voice session: ${_sessionRepository.currentSessionId}');
    }
  }

  /// Logs session_ended, clears the Firestore session, and resets transcripts.
  /// Does NOT change [_state] — callers decide the next state.
  void _teardownSession({required String endedBy}) {
    _inactivityTimer?.cancel();
    if (_sessionRepository.hasActiveSession) {
      final duration = _sessionStartTime != null
          ? DateTime.now().difference(_sessionStartTime!).inSeconds
          : 0;
      _analyticsService.logSessionEnded(
        durationSeconds: duration,
        messageCount: _sessionRepository.messageCount,
        endedBy: endedBy,
      );
      _sessionStartTime = null;
    }
    _sessionRepository.clearSession();
    _userInput = '';
    _aiResponse = '';
    _audioLevels.value = const []; // bars fall still when the session ends
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(_sessionTimeout, _onInactivityFailsafe);
  }

  void _onInactivityFailsafe() {
    Logger.session('Voice session inactivity failsafe (5 min) — ending');
    endSession();
  }

  /// Directly triggers the inactivity failsafe — for unit tests.
  @visibleForTesting
  void triggerInactivityForTesting() => _onInactivityFailsafe();

  void _updateState(ConversationState newState) {
    _state = newState;
    notifyListeners();
  }

  void _setError(String message) {
    _errorMessage = message;
    _state = ConversationState.error;
    _analyticsService.logErrorOccurred(errorType: message);
    notifyListeners();

    // Auto-recover to idle after a few seconds.
    Future.delayed(const Duration(seconds: 4), () {
      if (_state == ConversationState.error) {
        _errorMessage = '';
        _updateState(ConversationState.idle);
      }
    });
  }

  /// Resets to idle, ending any active voice session and Firestore session.
  void reset() {
    _voiceService.endSession();
    _teardownSession(endedBy: 'reset');
    _errorMessage = '';
    _updateState(ConversationState.idle);
  }

  @override
  void dispose() {
    _voiceSub?.cancel();
    _audioLevelsSub?.cancel();
    _audioLevels.dispose();
    _inactivityTimer?.cancel();
    _sessionRepository.dispose();
    _voiceService.dispose();
    super.dispose();
  }

  bool _isFeedbackSubmitting = false;
  bool get isFeedbackSubmitting => _isFeedbackSubmitting;

  /// Submits anonymous feedback through the session repository — returns true on success.
  Future<bool> submitFeedback(String text) async {
    if (text.trim().isEmpty) return false;
    _isFeedbackSubmitting = true;
    notifyListeners();
    try {
      await _sessionRepository.submitFeedback(text);
      _analyticsService.logFeedbackSubmitted(
        hasText: text.trim().isNotEmpty,
        messageCount: messageCount,
      );
      Logger.log('Feedback submitted successfully');
      _isFeedbackSubmitting = false;
      notifyListeners();
      return true;
    } catch (e, stackTrace) {
      Logger.error('Failed to submit feedback', e, stackTrace);
      _isFeedbackSubmitting = false;
      notifyListeners();
      return false;
    }
  }

  // Session info getters (handy for debugging).
  bool get hasActiveSession => _sessionRepository.hasActiveSession;
  int get messageCount => _sessionRepository.messageCount;
  String? get currentSessionId => _sessionRepository.currentSessionId;
}
