import 'dart:async';
import 'package:flutter/foundation.dart';
import '../services/speech_to_text_service.dart';
import '../services/openai_service.dart';
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
  error, // Something went wrong
}

/// ViewModel handling all conversation business logic
/// Coordinates speech recognition, AI responses, and text-to-speech
/// Now includes session management with 90-second inactivity timer
class ConversationViewModel extends ChangeNotifier {
  final SpeechToTextService _speechService;
  final OpenAIService _openAIService;
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
    required OpenAIService openAIService,
    required TTSService ttsService,
    required RAGService ragService,
    required SessionRepository sessionRepository,
  })  : _speechService = speechService,
        _openAIService = openAIService,
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
      _openAIService.initialize();
      await _ttsService.initialize();
      await _speechService.initialize();
      await _ragService.initialize(); // Initialize RAG service with embeddings
    } catch (e) {
      _setError('Failed to initialize: $e');
    }
  }

  /// Starts or resets the 90-second inactivity timer
  /// Called whenever there's user activity (new question)
  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(_sessionTimeout, _onSessionExpired);
  }

  /// Called when the 90-second timer expires
  /// Silently clears the session context without notifying the user
  void _onSessionExpired() {
    Logger.session('Session expired after 90 seconds of inactivity');
    _sessionRepository.clearSession();
    // No UI update - silent reset as per requirements
  }

  /// Ensures a session exists, creates one if needed
  /// This is called at the start of each conversation
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

    _setState(ConversationState.listening);
    _userInput = '';
    _errorMessage = '';

    try {
      await _speechService.startListening(
        onResult: (recognizedText) {
          _userInput = recognizedText;
          notifyListeners();
        },
      );
    } catch (e) {
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
      _setState(ConversationState.idle);
      return;
    }

    // Process the user input
    await _processUserInput();
  }

  // Cancel current listening session
  Future<void> cancelListening() async {
    if (_state == ConversationState.listening) {
      await _speechService.cancel();
      _setState(ConversationState.idle);
      _userInput = '';
      notifyListeners();
    }
  }

  // Process user input through AI and speak response
  // Now includes session management and conversation history
  Future<void> _processUserInput() async {
    _setState(ConversationState.processing);

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

      // Speak the response
      _setState(ConversationState.speaking);
      await _ttsService.speak(
        _aiResponse,
        onComplete: () {
          _setState(ConversationState.idle);
        },
      );
    } catch (e) {
      _setError('Failed to process: $e');
    }
  }

  // Stop current speech
  Future<void> stopSpeaking() async {
    if (_state == ConversationState.speaking) {
      await _ttsService.stop();
      _setState(ConversationState.idle);
    }
  }

  // Reset to idle state
  // Now also clears the session
  void reset() {
    _speechService.cancel();
    _ttsService.stop();
    _inactivityTimer?.cancel();
    _sessionRepository.clearSession();
    _setState(ConversationState.idle);
    _userInput = '';
    _aiResponse = '';
    _errorMessage = '';
  }

  void _setState(ConversationState newState) {
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
        _setState(ConversationState.idle);
        _errorMessage = '';
      }
    });
  }

  @override
  void dispose() {
    _inactivityTimer?.cancel(); // Cancel timer before disposing
    _sessionRepository.dispose(); // Clean up session repository
    _speechService.dispose();
    _ttsService.dispose();
    _openAIService.dispose();
    super.dispose();
  }

  // Additional getters for session info (useful for debugging)
  bool get hasActiveSession => _sessionRepository.hasActiveSession;
  int get messageCount => _sessionRepository.messageCount;
  String? get currentSessionId => _sessionRepository.currentSessionId;
}
