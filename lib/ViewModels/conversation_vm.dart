import 'dart:async';
import 'package:flutter/foundation.dart';
import '../services/speech_to_text_service.dart';
import '../services/tts_service.dart';
import '../services/rag_service.dart';
import '../repositories/session_repository.dart';
import '../utils/logger.dart';

/// Enum representing the different states of conversation
enum ConversationState {
  idle, // Waiting for user to start
  listening, // Actively listening to user
  processing, // Sending to AI and waiting for response
  speaking, // Pig is speaking the response
  error,
}

/// ViewModel for the conversation flow
/// Coordinates speech recognition, AI responses, text-to-speech, and session management with 90-second inactivity timer
class ConversationViewModel extends ChangeNotifier {
  final SpeechToTextService _speechService;
  final TTSService _ttsService;
  final RAGService _ragService;
  final SessionRepository _sessionRepository;

  ConversationState _state = ConversationState.idle;
  String _userInput = '';
  String _aiResponse = '';
  String _errorMessage = '';

  // 90-second inactivity timer for session management
  Timer? _inactivityTimer;
  static const Duration _sessionTimeout = Duration(seconds: 90);

  ConversationViewModel({
    required SpeechToTextService speechService,
    required TTSService ttsService,
    required RAGService ragService,
    required SessionRepository sessionRepository,
  })  : _speechService = speechService,
        _ttsService = ttsService,
        _ragService = ragService,
        _sessionRepository = sessionRepository;

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

  // Initialize all services including RAG
  Future<void> initialize() async {
    try {
      Logger.log('Initializing services...');
      await _ttsService.initialize();
      await _speechService.initialize();
      await _ragService.initialize(); // Initialize RAG service with menu knowledge base
      Logger.log('All services initialized successfully');
    } catch (e, stackTrace) {
      Logger.error('Failed to initialize services', e, stackTrace);
      _setError('Oink! Having trouble starting up. Please restart the app.');
    }
  }

  /// Starts or resets the 90-second inactivity timer, called whenever there's user activity (new question)
  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(_sessionTimeout, _onSessionExpired);
  }

  /// Called when the 90-second timer expires, silently clears the session context without notifying the user
  void _onSessionExpired() {
    Logger.session('Session expired after 90 seconds of inactivity');
    _sessionRepository.clearSession();
  }

  /// Ensures a session exists, creates one if needed, this is called at the start of each conversation
  Future<void> _ensureSession() async {
    if (!_sessionRepository.hasActiveSession) {
      await _sessionRepository.startSession();
      Logger.session('New session started: ${_sessionRepository.currentSessionId}');
    }
  }

  // Start listening to user
  Future<void> startListening() async {
    if (_state != ConversationState.idle) {
      return;
    }

    _updateState(ConversationState.listening);
    _userInput = '';
    _errorMessage = '';

    try {
      await _speechService.startListening(
        onResult: (recognizedText) {
          _userInput = recognizedText;
          notifyListeners();
        },
      );
    } catch (e, stackTrace) {
      Logger.error('Failed to start speech recognition', e, stackTrace);
      _setError('Failed to start listening: $e');
    }
  }

  // Stop listening and process the user's speech
  Future<void> stopListeningAndProcess() async {
    if (_state != ConversationState.listening) {
      return;
    }

    await _speechService.stopListening();

    if (_userInput.isEmpty) {
      _setError('No speech detected. Please try again!');
      _updateState(ConversationState.idle);
      return;
    }

    // Process the user input
    await _processUserInput();
  }

  // Cancel current listening session
  Future<void> cancelListening() async {
    if (_state == ConversationState.listening) {
      await _speechService.cancel();
      _updateState(ConversationState.idle);
      _userInput = '';
      notifyListeners();
    }
  }

  // Process user input through AI and speak response, includes session management and conversation history
  Future<void> _processUserInput() async {
    _updateState(ConversationState.processing);

    try {
      // Ensure we have an active session
      await _ensureSession();

      // Add user message to session
      _sessionRepository.addUserMessage(_userInput);

      // Reset the 90-second inactivity timer
      _resetInactivityTimer();

      // Get conversation history for context
      final conversationHistory = _sessionRepository.getConversationHistory();

      // Get AI response using RAG service with conversation history
      // This allows follow-up questions like "Is it spicy?" to work
      _aiResponse = await _ragService.getResponse(
        _userInput,
        conversationHistory: conversationHistory,
      );

      // Add AI response to session
      _sessionRepository.addAssistantMessage(_aiResponse);

      // Reset timer again (activity detected)
      _resetInactivityTimer();

      // Speak the response - wrapped in separate try-catch so TTS errors don't kill the whole flow
      _updateState(ConversationState.speaking);
      try {
        Logger.log('Starting TTS for response (${_aiResponse.length} characters)');
        await _ttsService.speak(
          _aiResponse,
          onComplete: () {
            Logger.log('TTS completed, returning to idle');
            // Only update state if still in speaking state (user might have interrupted)
            if (_state == ConversationState.speaking) {
              _updateState(ConversationState.idle);
            }
          },
        );
      } catch (ttsError, ttsStackTrace) {
        // Log TTS error but don't show error to user - they already got the text response
        Logger.error('TTS failed but continuing', ttsError, ttsStackTrace);
        // Return to idle after a brief delay so user can read the response
        Future.delayed(const Duration(seconds: 2), () {
          if (_state == ConversationState.speaking) {
            _updateState(ConversationState.idle);
          }
        });
      }
    } catch (e, stackTrace) {
      Logger.error('Failed to process user input and get AI response', e, stackTrace);
      // User-friendly error message
      _setError('Oink! Something went wrong. Please try again!');
    }
  }

  Future<void> stopSpeaking() async {
    if (_state == ConversationState.speaking) {
      await _ttsService.stop();
      _updateState(ConversationState.idle);
    }
  }

  // Reset to idle state, also clearing the session
  void reset() {
    _speechService.cancel();
    _ttsService.stop();
    _inactivityTimer?.cancel();
    _sessionRepository.clearSession();
    _updateState(ConversationState.idle);
    _userInput = '';
    _aiResponse = '';
    _errorMessage = '';
  }

  void _updateState(ConversationState newState) {
    _state = newState;
    notifyListeners();
  }

  void _setError(String message) {
    _errorMessage = message;
    _state = ConversationState.error;
    notifyListeners();

    // Auto-recover from error after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (_state == ConversationState.error) {
        _updateState(ConversationState.idle);
        _errorMessage = '';
      }
    });
  }

  @override
  void dispose() {
    _inactivityTimer?.cancel();      // Cancel timer before disposing
    _sessionRepository.dispose();   // Clean up session repository
    _speechService.dispose();
    _ttsService.dispose();
    super.dispose();
  }

  // Additional getters for session info (handy for debugging)
  bool get hasActiveSession => _sessionRepository.hasActiveSession;
  int get messageCount => _sessionRepository.messageCount;
  String? get currentSessionId => _sessionRepository.currentSessionId;
}
