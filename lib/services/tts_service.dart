import 'package:flutter_tts/flutter_tts.dart';
import '../utils/logger.dart';

/// Service to handle text-to-speech functionality
/// Wraps flutter_tts with configuration for the Ooink pig character
/// Includes robust error handling and progress tracking for long responses
class TTSService {
  final FlutterTts _flutterTts = FlutterTts();
  bool _isInitialized = false;
  bool _isSpeaking = false;
  Function()? _currentOnComplete;

  /// Initialize TTS with pig character voice settings and error handlers
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Configure TTS settings for a friendly, quirky character
      await _flutterTts.setLanguage('en-US');
      await _flutterTts.setSpeechRate(0.5); // Slightly slower for clarity
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.2); // Slightly higher pitch for pig character

      // Set up persistent handlers that work for all speech requests
      _flutterTts.setCompletionHandler(() {
        Logger.log('TTS: Speech completed');
        _isSpeaking = false;
        _currentOnComplete?.call();
        _currentOnComplete = null;
      });

      _flutterTts.setErrorHandler((msg) {
        Logger.error('TTS Error', msg, null);
        _isSpeaking = false;
        // Still call completion to prevent UI from hanging
        _currentOnComplete?.call();
        _currentOnComplete = null;
      });

      _flutterTts.setStartHandler(() {
        Logger.log('TTS: Speech started');
        _isSpeaking = true;
      });

      _isInitialized = true;
      Logger.log('TTS service initialized successfully');
    } catch (e, stackTrace) {
      Logger.error('Failed to initialize TTS service', e, stackTrace);
      throw Exception('TTS initialization failed: $e');
    }
  }

  /// Speak the given text with robust error handling
  /// [text] The text to speak
  /// [onComplete] Optional callback when speech completes (or errors)
  Future<void> speak(String text, {Function()? onComplete}) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      // Stop any ongoing speech
      if (_isSpeaking) {
        await stop();
      }

      // Store the completion callback
      _currentOnComplete = onComplete;

      Logger.log('TTS: Starting speech (${text.length} characters)');

      // For very long text, flutter_tts might fail - add safety timeout
      _isSpeaking = true;
      await _flutterTts.speak(text);

      // Calculate a safe timeout based on text length
      // approx 15 chars per second for slow speech + 10s buffer
      final timeoutDuration = Duration(seconds: 10 + (text.length / 5).ceil());

      // Safety fallback: if speech doesn't complete within reasonable time
      Future.delayed(timeoutDuration, () {
        if (_isSpeaking && _currentOnComplete != null) {
          Logger.error('TTS: Speech timeout - calling completion handler', 'Timeout after ${timeoutDuration.inSeconds}s', null);
          _isSpeaking = false;
          _currentOnComplete?.call();
          _currentOnComplete = null;
        }
      });
    } catch (e, stackTrace) {
      Logger.error('TTS speak error', e, stackTrace);
      _isSpeaking = false;
      // Call completion even on error to prevent UI hang
      onComplete?.call();
    }
  }

  /// Check if currently speaking
  bool get isSpeaking => _isSpeaking;

  /// Stop current speech
  Future<void> stop() async {
    try {
      await _flutterTts.stop();
      _isSpeaking = false;
      _currentOnComplete = null;
    } catch (e) {
      Logger.error('TTS stop error', e, null);
    }
  }

  /// Dispose resources
  void dispose() {
    _flutterTts.stop();
    _isSpeaking = false;
    _currentOnComplete = null;
  }
}
