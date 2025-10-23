import 'package:dart_openai/dart_openai.dart';

/// Service to handle OpenAI API interactions
/// Manages conversation with quirky pig personality
class OpenAIService {
  static const String _systemPrompt = '''
You are Ooink, a fun and quirky AI pig mascot for Ooink Ramen Restaurant! 🐷

Personality traits:
- LOVE making food puns and pig jokes
- Extremely enthusiastic about ramen
- Friendly and welcoming to hungry customers
- Use "oink" sound effects occasionally (but don't overdo it!)
- Keep responses SHORT and conversational (2-3 sentences max)
- Always try to make customers smile

Your job:
- Answer questions about the menu
- Make food recommendations
- Share what makes Ooink special
- Get customers excited to try the food!

Style:
✅ "Oink oink! That's my FAVORITE bowl! The tonkotsu broth is absolutely *sow*-perb!"
✅ "Great choice! That one really brings home the bacon! 🥓"
❌ Don't give long, boring explanations
❌ Don't be too formal or stiff

Remember: You're here to make the wait fun and help customers discover amazing ramen!
''';

  bool _isInitialized = false;

  /// Initialize OpenAI with API key
  /// TODO: Move API key to secure backend proxy for production
  void initialize(String apiKey) {
    if (_isInitialized) return;

    OpenAI.apiKey = apiKey;
    _isInitialized = true;
  }

  /// Get AI response for user question
  /// [userMessage] The customer's question
  /// Returns the pig's quirky response
  Future<String> getResponse(String userMessage) async {
    if (!_isInitialized) {
      throw Exception('OpenAI service not initialized. Please set API key first.');
    }

    try {
      final chatCompletion = await OpenAI.instance.chat.create(
        model: 'gpt-4o-mini',
        messages: [
          OpenAIChatCompletionChoiceMessageModel(
            role: OpenAIChatMessageRole.system,
            content: [
              OpenAIChatCompletionChoiceMessageContentItemModel.text(
                _systemPrompt,
              ),
            ],
          ),
          OpenAIChatCompletionChoiceMessageModel(
            role: OpenAIChatMessageRole.user,
            content: [
              OpenAIChatCompletionChoiceMessageContentItemModel.text(
                userMessage,
              ),
            ],
          ),
        ],
        temperature: 0.8, // More creative and playful responses
        maxTokens: 150, // Keep responses short
      );

      return chatCompletion.choices.first.message.content?.first.text ??
          "Oink! Sorry, I got a bit tongue-tied! Can you ask that again?";
    } catch (e) {
      // Using print here for MVP - will add proper logging later
      // ignore: avoid_print
      print('OpenAI API error: $e');
      return "Oink oink! My brain's a bit foggy right now. Could you try asking again?";
    }
  }

  /// Check if service is ready to use
  bool get isInitialized => _isInitialized;
}
