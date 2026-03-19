import 'dart:io';
import 'package:flutter_tts/flutter_tts.dart';
import '../utils/logger.dart';

/// Service to handle text-to-speech functionality
/// Wraps flutter_tts with configuration for the Ooink pig character
/// Includes robust error handling, progress tracking, and automatic instance refresh for long-running kiosk operation
class TTSService {
  FlutterTts _flutterTts = FlutterTts();
  bool _isInitialized = false;
  bool _isSpeaking = false;
  Function()? _currentOnComplete;
  int _speechCount = 0; // Track usage count to prevent memory buildup in all-day operation
  DateTime? _speechStartTime; // Track when speech started for timeout tuning analytics

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
        // Log actual speech duration for timeout tuning analytics
        if (_speechStartTime != null) {
          final actualDuration = DateTime.now().difference(_speechStartTime!);
          Logger.log('TTS: Speech completed in ${actualDuration.inSeconds}s');
        } else {
          Logger.log('TTS: Speech completed');
        }
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

  /// Speak the given text with robust error handling and automatic TTS engine refresh
  /// [text] The text to speak
  /// [onComplete] Optional callback when speech completes (or errors)
  /// Automatically refreshes TTS engine every 50 uses to prevent memory buildup during all-day kiosk operation
  Future<void> speak(String text, {Function()? onComplete}) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      // Stop any ongoing speech
      if (_isSpeaking) {
        await stop();
      }

      // Increment usage counter and refresh TTS engine every 50 speeches
      // This prevents Android/iOS TTS engine from accumulating state and degrading over hours of use
      _speechCount++;
      if (_speechCount % 50 == 0) {
        Logger.log('TTS: Refreshing engine after $_speechCount uses (prevents memory buildup)');
        await _flutterTts.stop();
        _flutterTts = FlutterTts();
        _isInitialized = false;
        await initialize();
      }

      // Store the completion callback
      _currentOnComplete = onComplete;

      // Strip emojis before speaking — TTS engines read them aloud as descriptions (e.g., "pig face")
      final cleanText = _stripEmojis(text);
      Logger.log('TTS: Starting speech #$_speechCount (${cleanText.length} characters)');

      // Check platform max length (Android-specific safety check)
      if (Platform.isAndroid) {
        try {
          final maxLength = await _flutterTts.getMaxSpeechInputLength;
          if (maxLength != null && cleanText.length > maxLength) {
            Logger.log('WARNING: TTS text length (${cleanText.length}) exceeds platform max ($maxLength). May be truncated.');
          }
        } catch (e) {
          // getMaxSpeechInputLength might not be available on all devices
          Logger.log('TTS: Could not check max speech length (not critical)');
        }
      }

      // For very long text, flutter_tts might fail - add safety timeout
      _isSpeaking = true;
      _speechStartTime = DateTime.now(); // Track start time for analytics
      await _flutterTts.speak(cleanText);

      // Calculate a conservative timeout based on actual speech rate
      // At 0.5 speech rate with 1.2 pitch: approximately 4-5 characters per second
      // Add 20s buffer for iOS/Android TTS engine initialization delays and sentence pausing
      // Example: 300 chars = 20 + (300/4) = 95 seconds (very safe)
      //          150 chars = 20 + (150/4) = 57 seconds (typical response)
      final timeoutDuration = Duration(seconds: 20 + (cleanText.length ~/ 4));

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

  /// Removes emoji characters from text so TTS reads words only, not descriptions like "pig face"
  /// Covers the main Unicode emoji blocks (emoticons, symbols, transport, misc)
  String _stripEmojis(String text) {
    return text.replaceAll(
      RegExp(
        r'[\u{1F300}-\u{1FAFF}]|'  // Misc symbols, emoticons, transport, supplemental
        r'[\u{2600}-\u{27BF}]|'    // Misc symbols and dingbats
        r'[\u{FE00}-\u{FE0F}]|'    // Variation selectors (emoji modifiers)
        r'[\u{1F000}-\u{1F02F}]',  // Mahjong / domino tiles
        unicode: true,
      ),
      '',
    );
  }

  /// Dispose resources and reset usage counter
  void dispose() {
    _flutterTts.stop();
    _isSpeaking = false;
    _currentOnComplete = null;
    _speechCount = 0;
  }
}
