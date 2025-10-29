import 'message_model.dart';

/// Represents a conversation session with a customer
/// A session includes all the back-and-forth messages within a 90-second window
class Session {
  final String sessionId;
  final DateTime startTime;
  final DateTime lastActivityTime;
  final List<Message> messages;
  final bool isActive;

  Session({
    required this.sessionId,
    required this.startTime,
    required this.lastActivityTime,
    required this.messages,
    this.isActive = true,
  });

  /// Creates a new session with a unique ID
  /// This is called when a customer starts asking questions
  factory Session.create(String sessionId) {
    final now = DateTime.now();
    return Session(
      sessionId: sessionId,
      startTime: now,
      lastActivityTime: now,
      messages: [],
      isActive: true,
    );
  }

  /// Checks if this session has expired based on the timeout duration
  /// Returns true if the time since last activity exceeds the timeout
  bool isExpired(Duration timeout) {
    final now = DateTime.now();
    final inactivityDuration = now.difference(lastActivityTime);
    return inactivityDuration > timeout;
  }

  /// Gets how long it's been since the last customer interaction
  /// Used to track if we're close to the 90-second timeout
  Duration getInactivityDuration() {
    final now = DateTime.now();
    return now.difference(lastActivityTime);
  }

  /// Gets the total duration of this conversation session
  /// From when the customer first asked until now
  Duration getTotalDuration() {
    final now = DateTime.now();
    return now.difference(startTime);
  }

  /// Creates a new session with an added message
  /// This returns a new Session object because we want to keep sessions immutable
  Session addMessage(Message message) {
    return Session(
      sessionId: sessionId,
      startTime: startTime,
      lastActivityTime: DateTime.now(), // Update activity time
      messages: [...messages, message], // Add new message to the list
      isActive: isActive,
    );
  }

  /// Marks this session as ended/inactive
  /// Called when the 90-second timer expires or customer walks away
  Session end() {
    return Session(
      sessionId: sessionId,
      startTime: startTime,
      lastActivityTime: lastActivityTime,
      messages: messages,
      isActive: false,
    );
  }

  /// Gets only the user and assistant messages (excludes system prompts)
  /// Useful for displaying conversation history to the user
  List<Message> get conversationMessages {
    return messages
        .where((msg) => msg.role != MessageRole.system)
        .toList();
  }

  /// Gets the number of back-and-forth exchanges in this session
  /// One exchange = one user question + one AI answer
  int get messageCount => messages.length;

  /// Converts session to JSON for Firestore storage
  /// This saves the session metadata (not individual messages - those are in subcollection)
  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'startTime': startTime.toIso8601String(),
      'lastActivityTime': lastActivityTime.toIso8601String(),
      'isActive': isActive,
      'messageCount': messageCount,
    };
  }

  /// Creates a Session from Firestore JSON data
  /// Note: This only loads metadata, messages are loaded separately from subcollection
  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      sessionId: json['sessionId'] as String,
      startTime: DateTime.parse(json['startTime'] as String),
      lastActivityTime: DateTime.parse(json['lastActivityTime'] as String),
      messages: [], // Messages loaded separately
      isActive: json['isActive'] as bool? ?? false,
    );
  }

  /// Creates a copy of this session with some fields changed
  Session copyWith({
    String? sessionId,
    DateTime? startTime,
    DateTime? lastActivityTime,
    List<Message>? messages,
    bool? isActive,
  }) {
    return Session(
      sessionId: sessionId ?? this.sessionId,
      startTime: startTime ?? this.startTime,
      lastActivityTime: lastActivityTime ?? this.lastActivityTime,
      messages: messages ?? this.messages,
      isActive: isActive ?? this.isActive,
    );
  }

  @override
  String toString() {
    return 'Session(id: $sessionId, messages: $messageCount, active: $isActive, inactivity: ${getInactivityDuration().inSeconds}s)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Session && other.sessionId == sessionId;
  }

  @override
  int get hashCode => sessionId.hashCode;
}
