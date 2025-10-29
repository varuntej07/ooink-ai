import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/session_model.dart';
import '../models/message_model.dart';

/// Service for background Firestore operations (fire-and-forget)
/// This runs async so it never blocks the main conversation flow
/// Used purely for analytics and debugging - not for active session management
class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Creates a new session document in Firestore and is called when a customer starts asking questions
  /// Fire-and-forget: we don't wait for this to complete
  Future<void> createSession(Session session) async {
    try {
      await _firestore
          .collection('sessions')
          .doc(session.sessionId)
          .set(session.toJson());
    } catch (e) {
      // Silent fail -We don't want Firestore errors to break the kiosk
      print('Firestore createSession error (non-critical): $e');
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
      print('Firestore addMessage error (non-critical): $e');
    }
  }

  /// Marks a session as ended/inactive, Called when the 90-second timer expires or app shuts down
  Future<void> endSession(String sessionId) async {
    try {
      await _firestore.collection('sessions').doc(sessionId).update({
        'isActive': false,
      });
    } catch (e) {
      print('Firestore endSession error (non-critical): $e');
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
      print('Firestore getSessionMessages error: $e');
      return [];
    }
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
      print('Firestore getSessionAnalytics error: $e');
      return {
        'totalSessions': 0,
        'totalMessages': 0,
        'averageMessagesPerSession': 0,
      };
    }
  }
}
