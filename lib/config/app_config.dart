/// Configuration class for the application
/// Uses Firebase Vertex AI which handles authentication automatically through Firebase
class AppConfig {
  static const String geminiModel = 'gemini-2.5-flash';
  static const double geminiTemperature = 0.7;
  // Max tokens - keeps responses snappy (naturally concise due to prompt) but allows up to 700 for detailed queries
  static const int geminiMaxTokens = 700;

  // RAG Configuration - Number of menu chunks to retrieve for context in semantic search
  static const int topKChunks = 3;
}