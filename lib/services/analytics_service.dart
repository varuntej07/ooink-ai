import 'dart:async';
import 'package:firebase_analytics/firebase_analytics.dart';

/// Thin typed wrapper over FirebaseAnalytics — one method per event, all fire-and-forget.
/// Never awaited by callers so analytics never blocks the conversation flow.
class AnalyticsService {
  // Lazy getter so Firebase.instance is only resolved on first event call,
  // not at construction time — keeps tests that don't init Firebase safe.
  FirebaseAnalytics get _analytics => FirebaseAnalytics.instance;

  /// Fired when a new session UUID is created (first message after idle)
  void logSessionStarted({required int hourOfDay, required int dayOfWeek}) {
    unawaited(_analytics.logEvent(
      name: 'session_started',
      parameters: {'hour_of_day': hourOfDay, 'day_of_week': dayOfWeek},
    ));
  }

  /// Fired when session ends via inactivity timeout or manual reset
  void logSessionEnded({
    required int durationSeconds,
    required int messageCount,
    required String endedBy, // 'timeout' | 'reset'
  }) {
    unawaited(_analytics.logEvent(
      name: 'session_ended',
      parameters: {
        'duration_seconds': durationSeconds,
        'message_count': messageCount,
        'ended_by': endedBy,
      },
    ));
  }

  /// Fired after every AI response: carries path, score, and end-to-end latency
  void logQuerySent({
    required String path, // 'rag' | 'persona' | 'error'
    required double similarityScore,
    required int responseLatencyMs,
  }) {
    unawaited(_analytics.logEvent(
      name: 'query_sent',
      parameters: {
        'path': path,
        'similarity_score': similarityScore,
        'response_latency_ms': responseLatencyMs,
      },
    ));
  }

  /// Fired after threshold check, this lets you track how often queries fall below 0.25
  void logRagThresholdEvent({required double score, required bool passed}) {
    unawaited(_analytics.logEvent(
      name: 'rag_threshold_event',
      parameters: {
        'score': score,
        'passed': passed ? 1 : 0,
      },
    ));
  }

  /// Fired when TTS finishes speaking, confirming the pig completed its response
  void logTtsCompleted({required int responseLength}) {
    unawaited(_analytics.logEvent(
      name: 'tts_completed',
      parameters: {'response_length_chars': responseLength},
    ));
  }

  /// Fired on any error state, maps to the user-facing error message
  void logErrorOccurred({required String errorType}) {
    unawaited(_analytics.logEvent(
      name: 'error_occurred',
      // Truncate to 100 chars to stay within Firebase Analytics parameter limits
      parameters: {'error_type': errorType.length > 100 ? errorType.substring(0, 100) : errorType},
    ));
  }

  /// Fired on successful feedback submission
  void logFeedbackSubmitted({required bool hasText, required int messageCount}) {
    unawaited(_analytics.logEvent(
      name: 'feedback_submitted',
      parameters: {
        'has_text': hasText ? 1 : 0,
        'message_count_at_time': messageCount,
      },
    ));
  }
}
