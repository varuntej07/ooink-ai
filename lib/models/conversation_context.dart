import 'dart:async';
import 'message_model.dart';

/// Lightweight in-memory holder for the current active conversation
/// This is kept in memory for fast access during a customer interaction
class ConversationContext {
  final String sessionId;
  final List<Message> messages;
  Timer? inactivityTimer;

  ConversationContext({
    required this.sessionId,
    required this.messages,
    this.inactivityTimer,
  });

  /// Creates a new conversation context with a unique session ID
  factory ConversationContext.create(String sessionId) {
    return ConversationContext(
      sessionId: sessionId,
      messages: [],
      inactivityTimer: null,
    );
  }

  /// Checks if this context has any conversation history
  /// Returns false for brand new conversations
  bool get hasContext => messages.isNotEmpty;

  /// Gets the number of messages in this conversation
  int get messageCount => messages.length;

  /// Adds a message to this conversation context
  /// Updates the messages list with the new message
  void addMessage(Message message) {
    messages.add(message);
  }

  /// Converts all messages to OpenAI API format
  /// This is what we send to OpenAI to give it the conversation history
  /// Format: [{ "role": "user", "content": "..." }, { "role": "assistant", "content": "..." }]
  List<Map<String, dynamic>> toOpenAIMessages() {
    return messages.map((msg) => msg.toOpenAIFormat()).toList();
  }

  /// Gets only the last N messages to avoid hitting token limits
  /// OpenAI has a maximum token limit, so we only send recent context
  List<Map<String, dynamic>> toOpenAIMessagesWithLimit(int maxMessages) {
    final limitedMessages = messages.length > maxMessages
        ? messages.sublist(messages.length - maxMessages)
        : messages;
    return limitedMessages.map((msg) => msg.toOpenAIFormat()).toList();
  }

  /// Clears all messages and cancels the inactivity timer
  /// Called when the 90-second session expires
  void clear() {
    messages.clear();
    inactivityTimer?.cancel();
    inactivityTimer = null;
  }

  /// Cancels the inactivity timer without clearing messages
  /// Useful when we're shutting down the app or switching contexts
  void cancelTimer() {
    inactivityTimer?.cancel();
    inactivityTimer = null;
  }

  @override
  String toString() {
    return 'ConversationContext(sessionId: $sessionId, messageCount: $messageCount, hasTimer: ${inactivityTimer != null})';
  }
}
