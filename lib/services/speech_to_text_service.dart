import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter/foundation.dart';

/// Service to handle speech recognition, Wraps the speech_to_text package
class SpeechToTextService {
  final SpeechToText _speechToText = SpeechToText();
  bool _isInitialized = false;

  // Check if speech recognition is available and initialize, The speech_to_text package handles permission requests automatically
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    // Initialize speech recognition (package handles permissions internally)
    _isInitialized = await _speechToText.initialize(
      onError: (error) => debugPrint('Speech recognition error: $error'),
      onStatus: (status) => debugPrint('Speech recognition status: $status'),
    );

    return _isInitialized;
  }

  // Start listening to user speech and invoked [onResult] callback receives the recognized text
  Future<void> startListening({
    required Function(String) onResult,
  }) async {
    if (!_isInitialized) {
      final initialized = await initialize();
      if (!initialized) {
        throw Exception('Failed to initialize speech recognition');
      }
    }

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

  // Dispose resources
  void dispose() {
    _speechToText.cancel();
  }
}
