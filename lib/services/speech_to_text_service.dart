import 'package:speech_to_text/speech_to_text.dart';
import '../utils/logger.dart';

/// Service to handle speech recognition with automatic session refresh for all-day kiosk operation
/// Wraps the speech_to_text package and prevents Android/iOS STT session degradation
class SpeechToTextService {
  SpeechToText _speechToText = SpeechToText();
  bool _isInitialized = false;
  int _sessionCount = 0; // Track recognition sessions to prevent degradation in long-running operation

  // Check if speech recognition is available and initialize, The speech_to_text package handles permission requests automatically
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    // Initialize speech recognition
    _isInitialized = await _speechToText.initialize(
      onError: (error) => Logger.error('Speech recognition error', error),
      onStatus: (status) => Logger.log('Speech recognition status: $status'),
    );

    return _isInitialized;
  }

  // Start listening to user speech and invoked [onResult] callback receives the recognized text
  // Automatically reinitializes STT engine every 30 sessions to prevent Android/iOS recognition degradation
  // This is critical for all-day kiosk operation where the same STT instance may process 100+ customer interactions
  Future<void> startListening({
    required Function(String) onResult,
  }) async {
    if (!_isInitialized) {
      final initialized = await initialize();
      if (!initialized) {
        throw Exception('Failed to initialize speech recognition');
      }
    }

    // Increment session counter and force reinitialization every 30 sessions
    // Android/iOS STT engines have undocumented session limits and may degrade after prolonged use
    // Refreshing the engine prevents recognition failures and maintains accuracy
    _sessionCount++;
    if (_sessionCount % 30 == 0) {
      Logger.log('STT: Reinitializing engine after $_sessionCount sessions (prevents degradation)');
      _isInitialized = false;
      _speechToText = SpeechToText();
      final reinitialized = await initialize();
      if (!reinitialized) {
        throw Exception('Failed to reinitialize speech recognition after session refresh');
      }
    }

    Logger.log('STT: Starting listening session #$_sessionCount');

    await _speechToText.listen(
      onResult: (result) {
        if (result.finalResult) {
          onResult(result.recognizedWords);
        }
      },
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.confirmation,
      ),
    );
  }

  // Stop listening
  Future<void> stopListening() async {
    await _speechToText.stop();
  }

  // Check if currently listening
  bool get isListening => _speechToText.isListening;

  // Check if speech recognition is available on this device
  bool get isAvailable => _isInitialized;

  // Cancel current listening session
  Future<void> cancel() async {
    await _speechToText.cancel();
  }

  // Dispose resources and reset session counter
  void dispose() {
    _speechToText.cancel();
    _sessionCount = 0;
  }
}
