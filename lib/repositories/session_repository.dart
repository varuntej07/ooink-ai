import 'package:uuid/uuid.dart';
import '../models/conversation_context.dart';
import '../models/message_model.dart';
import '../models/session_model.dart';
import '../services/firestore_service.dart';

/// Repository for managing conversation sessions
/// Uses hybrid storage: in-memory for speed + async Firestore for analytics
/// This keeps the kiosk responsive while still logging data for the restaurant
class SessionRepository {
  final FirestoreService _firestoreService;
  final Uuid _uuid = const Uuid();

  // In-memory cache - this is the primary source of truth during active conversations
  ConversationContext? _currentContext;

  // System prompt that tells the AI how to behave
  // This gets prepended to every conversation
  static const String _systemPrompt =
      "You are Pig, the friendly AI assistant at Ooink Ramen Fremont. "
      "Answer customer questions about the menu using ONLY the context provided. "
      "Be warm, enthusiastic about the food, and keep responses concise (2-3 sentences max). "
      "If asked about something not on the menu, politely say you don't have that info.";

  SessionRepository({required FirestoreService firestoreService})
      : _firestoreService = firestoreService;

  /// Checks if there's an active conversation session
  bool get hasActiveSession => _currentContext != null;

  /// Gets the current session ID (null if no active session)
  String? get currentSessionId => _currentContext?.sessionId;

  /// Gets the number of messages in the current session
  int get messageCount => _currentContext?.messageCount ?? 0;

  /// Starts a new conversation session
  /// This creates a new session ID and logs it to Firestore in the background
  Future<void> startSession() async {
    final sessionId = _uuid.v4(); // Generate unique ID

    // Create in-memory context immediately (zero latency)
    _currentContext = ConversationContext.create(sessionId);

    // Add system prompt as the first message
    // This tells the AI how to behave throughout the conversation
    final systemMessage = Message.system(_systemPrompt);
    _currentContext!.addMessage(systemMessage);

    // Create session in Firestore asynchronously (fire-and-forget)
    // We don't await this so it doesn't slow down the conversation
    final session = Session.create(sessionId);
    _firestoreService.createSession(session).catchError((error) {
      print('Failed to log session to Firestore (non-critical): $error');
    });
  }

  /// Adds a user message to the current session
  /// This is what the customer said/asked
  void addUserMessage(String content) {
    if (_currentContext == null) return;

    final messageId = _uuid.v4();
    final message = Message.user(content, messageId);

    // Add to in-memory context immediately
    _currentContext!.addMessage(message);

    // Log to Firestore asynchronously (fire-and-forget)
    _firestoreService
        .addMessage(_currentContext!.sessionId, message)
        .catchError((error) {
      print('Failed to log user message to Firestore (non-critical): $error');
    });
  }

  /// Adds an assistant (AI) message to the current session
  /// This is Pig's response to the customer
  void addAssistantMessage(String content) {
    if (_currentContext == null) return;

    final messageId = _uuid.v4();
    final message = Message.assistant(content, messageId);

    // Add to in-memory context immediately
    _currentContext!.addMessage(message);

    // Log to Firestore asynchronously (fire-and-forget)
    _firestoreService
        .addMessage(_currentContext!.sessionId, message)
        .catchError((error) {
      print(
          'Failed to log assistant message to Firestore (non-critical): $error');
    });
  }

  /// Gets the conversation history in OpenAI API format
  /// This is sent to OpenAI so it can understand the context of follow-up questions
  /// Returns format: [{"role": "system", "content": "..."}, {"role": "user", "content": "..."}, ...]
  List<Map<String, dynamic>> getConversationHistory() {
    if (_currentContext == null) return [];

    // Limit to last 20 messages to avoid hitting OpenAI token limits
    // This is about 10 back-and-forth exchanges, which is plenty for context
    return _currentContext!.toOpenAIMessagesWithLimit(20);
  }

  /// Gets all conversation messages (not limited)
  /// Useful for displaying full conversation history in UI
  List<Map<String, dynamic>> getAllMessages() {
    if (_currentContext == null) return [];
    return _currentContext!.toOpenAIMessages();
  }

  /// Clears the current session (silent reset after 90-second timeout)
  /// This ends the conversation and starts fresh for the next customer
  void clearSession() {
    if (_currentContext == null) return;

    final sessionId = _currentContext!.sessionId;

    // Cancel any active timers
    _currentContext!.cancelTimer();

    // Clear in-memory context
    _currentContext = null;

    // Mark session as ended in Firestore asynchronously
    _firestoreService.endSession(sessionId).catchError((error) {
      print('Failed to end session in Firestore (non-critical): $error');
    });
  }

  /// Disposes of resources (called when app is shutting down)
  /// Ensures we clean up timers and mark the session as ended
  void dispose() {
    if (_currentContext != null) {
      clearSession();
    }
  }

  /// Gets the current conversation context (for debugging)
  ConversationContext? get currentContext => _currentContext;

  /// Checks if the current session has any messages beyond the system prompt
  /// Returns false if it's a brand new session with no customer interaction yet
  bool get hasConversationStarted {
    if (_currentContext == null) return false;
    // System prompt is always first, so check if there's more than 1 message
    return _currentContext!.messageCount > 1;
  }

  /// Gets a human-readable summary of the current session
  String getSessionSummary() {
    if (_currentContext == null) {
      return 'No active session';
    }
    return 'Session ${_currentContext!.sessionId.substring(0, 8)}... '
        'with ${_currentContext!.messageCount} messages';
  }
}
