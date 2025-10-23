import 'package:flutter/foundation.dart';
import '../services/speech_to_text_service.dart';
import '../services/openai_service.dart';
import '../services/tts_service.dart';

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
/// No UI logic - purely business logic following MVVM principles
class ConversationViewModel extends ChangeNotifier {
  final SpeechToTextService _speechService;
  final OpenAIService _openAIService;
  final TTSService _ttsService;

  ConversationState _state = ConversationState.idle;
  String _userInput = '';
  String _aiResponse = '';
  String _errorMessage = '';

  ConversationViewModel({
    required SpeechToTextService speechService,
    required OpenAIService openAIService,
    required TTSService ttsService,
  })  : _speechService = speechService,
        _openAIService = openAIService,
        _ttsService = ttsService;

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

  /// Initialize all services
  Future<void> initialize(String openAIApiKey) async {
    try {
      _openAIService.initialize(openAIApiKey);
      await _ttsService.initialize();
      await _speechService.initialize();
    } catch (e) {
      _setError('Failed to initialize: $e');
    }
  }

  /// Start listening to user
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

  /// Stop listening and process the user's speech
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

  /// Cancel current listening session
  Future<void> cancelListening() async {
    if (_state == ConversationState.listening) {
      await _speechService.cancel();
      _setState(ConversationState.idle);
      _userInput = '';
      notifyListeners();
    }
  }

  /// Process user input through AI and speak response
  Future<void> _processUserInput() async {
    _setState(ConversationState.processing);

    try {
      // Get AI response
      _aiResponse = await _openAIService.getResponse(_userInput);

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

  /// Stop current speech
  Future<void> stopSpeaking() async {
    if (_state == ConversationState.speaking) {
      await _ttsService.stop();
      _setState(ConversationState.idle);
    }
  }

  /// Reset to idle state
  void reset() {
    _speechService.cancel();
    _ttsService.stop();
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
    _speechService.dispose();
    _ttsService.dispose();
    super.dispose();
  }
}
