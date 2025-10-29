/// Represents the role of a message in the conversation
/// Used to differentiate between user inputs, AI responses, and system prompts
enum MessageRole {
  user,
  assistant,
  system,
}

/// Represents a single message in the conversation
/// This can be from the user asking a question, the AI responding,
/// or a system message providing context
class Message {
  final String id;
  final MessageRole role;
  final String content;
  final DateTime timestamp;

  Message({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
  });

  /// Factory constructor to create a user message
  /// This is what the customer says/asks
  factory Message.user(String content, String id) {
    return Message(
      id: id,
      role: MessageRole.user,
      content: content,
      timestamp: DateTime.now(),
    );
  }

  /// Factory constructor to create an assistant (AI) message
  /// This is Pig's response to the customer
  factory Message.assistant(String content, String id) {
    return Message(
      id: id,
      role: MessageRole.assistant,
      content: content,
      timestamp: DateTime.now(),
    );
  }

  /// Factory constructor to create a system message
  /// This is used to give the AI context about how to behave
  factory Message.system(String content) {
    return Message(
      id: 'system',
      role: MessageRole.system,
      content: content,
      timestamp: DateTime.now(),
    );
  }

  /// Converts message to OpenAI API format
  /// OpenAI expects messages in the format: { "role": "user", "content": "..." }
  Map<String, dynamic> toOpenAIFormat() {
    return {
      'role': role.name,
      'content': content,
    };
  }

  /// Converts message to JSON for Firestore storage
  /// This lets us save conversation history to the database
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'role': role.name,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  /// Creates a Message from Firestore JSON data
  /// Used when reading conversation history from the database
  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as String,
      role: MessageRole.values.firstWhere(
        (e) => e.name == json['role'],
        orElse: () => MessageRole.user,
      ),
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  /// Creates a copy of this message with some fields changed
  /// Useful for updating message properties without creating a whole new object
  Message copyWith({
    String? id,
    MessageRole? role,
    String? content,
    DateTime? timestamp,
  }) {
    return Message(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  @override
  String toString() {
    return 'Message(id: $id, role: ${role.name}, content: $content, timestamp: $timestamp)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Message && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
