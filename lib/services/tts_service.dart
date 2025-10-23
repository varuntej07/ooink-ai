import 'package:flutter_tts/flutter_tts.dart';

/// Service to handle text-to-speech functionality
/// Wraps flutter_tts with configuration for the Ooink pig character
class TTSService {
  final FlutterTts _flutterTts = FlutterTts();
  bool _isInitialized = false;

  /// Initialize TTS with pig character voice settings
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Configure TTS settings for a friendly, quirky character
    await _flutterTts.setLanguage('en-US');
    await _flutterTts.setSpeechRate(0.5); // Slightly slower for clarity
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.2); // Slightly higher pitch for pig character

    _isInitialized = true;
  }

  /// Speak the given text
  /// [text] The text to speak
  /// [onComplete] Optional callback when speech completes
  Future<void> speak(String text, {Function()? onComplete}) async {
    if (!_isInitialized) {
      await initialize();
    }

    // Set completion handler
    if (onComplete != null) {
      _flutterTts.setCompletionHandler(() {
        onComplete();
      });
    }

    await _flutterTts.speak(text);
  }

  /// Stop current speech
  Future<void> stop() async {
    await _flutterTts.stop();
  }

  /// Dispose resources
  void dispose() {
    _flutterTts.stop();
  }
}
