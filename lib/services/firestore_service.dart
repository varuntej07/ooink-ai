import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/session_model.dart';
import '../models/message_model.dart';
import '../utils/logger.dart';

/// Service for background Firestore operations (fire-and-forget)
/// This runs async so it never blocks the main conversation flow
/// Used purely for analytics and debugging - not for active session management
class FirestoreService {
  // 'late' defers initialization to first method call rather than at object construction.
  // This lets unit tests construct FirestoreService without Firebase being initialized yet.
  late final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Creates a new session document in Firestore and is called when a customer starts asking questions
  /// Fire-and-forget: we don't wait for this to complete
  Future<void> createSession(Session session) async {
    try {
      await _firestore
          .collection('sessions')
          .doc(session.sessionId)
          .set(session.toJson());
    } catch (e) {
      // Silent fail - We don't want Firestore errors to break the kiosk
      Logger.error('Firestore createSession error (non-critical)', e, e is Error ? e.stackTrace : null);
    }
  }

  /// Adds a message to the session's messages subcollection
  /// Each message is stored separately so we can query them efficiently
  Future<void> addMessage(String sessionId, Message message) async {
    try {
      await _firestore
          .collection('sessions')
          .doc(sessionId)
          .collection('messages')
          .doc(message.id)
          .set(message.toJson());

      // Also update the session's lastActivityTime
      await _firestore.collection('sessions').doc(sessionId).update({
        'lastActivityTime': message.timestamp.toIso8601String(),
      });
    } catch (e) {
      Logger.error('Firestore addMessage error (non-critical)', e, e is Error ? e.stackTrace : null);
    }
  }

  /// Marks a session as ended/inactive, Called when the 90-second timer expires or app shuts down
  Future<void> endSession(String sessionId) async {
    try {
      await _firestore.collection('sessions').doc(sessionId).update({
        'isActive': false,
      });
    } catch (e) {
      Logger.error('Firestore endSession error (non-critical)', e, e is Error ? e.stackTrace : null);
    }
  }

  /// Gets all messages for a session from Firestore (rarely used)
  /// Mainly for debugging or recovering from app crashes
  Future<List<Message>> getSessionMessages(String sessionId) async {
    try {
      final querySnapshot = await _firestore
          .collection('sessions')
          .doc(sessionId)
          .collection('messages')
          .orderBy('timestamp')
          .get();

      return querySnapshot.docs
          .map((doc) => Message.fromJson(doc.data()))
          .toList();
    } catch (e) {
      Logger.error('Firestore getSessionMessages error', e, e is Error ? e.stackTrace : null);
      return [];
    }
  }

  /// Saves anonymous customer feedback to root-level 'feedback' collection
  /// Throws on error so the ViewModel can tell the user it failed (unlike fire-and-forget session writes)
  Future<void> submitFeedback({
    required String text,
    String? sessionId,
    int? messageCount,
  }) async {
    await _firestore.collection('feedback').add({
      'text': text.trim(),
      'timestamp': FieldValue.serverTimestamp(),
      'sessionId': sessionId,           // anonymous — links feedback to its conversation context
      'messageCount': messageCount ?? 0, // how deep into the chat they were when they gave feedback
    });
  }

  /// Gets analytics data (optional - for restaurant owner to see usage patterns)
  /// Can query: How many conversations per day? Peak hours? Common questions?
  Future<Map<String, dynamic>> getSessionAnalytics({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final querySnapshot = await _firestore
          .collection('sessions')
          .where('startTime',
              isGreaterThanOrEqualTo: startDate.toIso8601String())
          .where('startTime', isLessThanOrEqualTo: endDate.toIso8601String())
          .get();

      final totalSessions = querySnapshot.docs.length;
      int totalMessages = 0;

      for (var doc in querySnapshot.docs) {
        final messageCount = doc.data()['messageCount'] as int? ?? 0;
        totalMessages += messageCount;
      }

      return {
        'totalSessions': totalSessions,
        'totalMessages': totalMessages,
        'averageMessagesPerSession':
            totalSessions > 0 ? totalMessages / totalSessions : 0,
      };
    } catch (e) {
      Logger.error('Firestore getSessionAnalytics error', e, e is Error ? e.stackTrace : null);
      return {
        'totalSessions': 0,
        'totalMessages': 0,
        'averageMessagesPerSession': 0,
      };
    }
  }
}
