import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Centralized logging utility using Firebase Crashlytics for monitoring and debugging
/// All logging is non-blocking and happens asynchronously to avoid impacting app performance
class Logger {
  /// Set to true in unit tests to silence all Firebase calls.
  /// Prevents "No Firebase App" errors when running tests without a real Firebase project.
  @visibleForTesting
  static bool suppressForTesting = false;

  /// Logs a general informational message to Crashlytics to help track the flow of execution and issues in production
  /// [message] The information to log (e.g., "User started conversation")
  static void log(String message) {
    if (suppressForTesting) return;
    FirebaseCrashlytics.instance.log(message);
  }

  /// Logs an error to Crashlytics with optional error object and stack trace
  /// [message] Description of what went wrong (e.g., "Failed to load embeddings")
  /// [error] Optional error object (Exception, Error, etc.)
  /// [stackTrace] Optional stack trace for debugging
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    if (suppressForTesting) return;
    FirebaseCrashlytics.instance.log('ERROR: $message');

    // If we have an error object, record it as a non-fatal error
    // This appears in the Crashlytics dashboard but doesn't count as a crash
    if (error != null) {
      FirebaseCrashlytics.instance.recordError(
        error,
        stackTrace,
        reason: message,
        fatal: false,
      );
    }
  }

  /// Logs session-related information, helps track user session lifecycle and conversation flow
  /// [message] Session event description (e.g., "Session started", "Session timeout")
  static void session(String message) {
    if (suppressForTesting) return;
    FirebaseCrashlytics.instance.log('[SESSION] $message');
  }
}
