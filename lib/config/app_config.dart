/// Configuration class for the application
/// Uses Firebase Vertex AI which handles authentication automatically through Firebase
class AppConfig {
  static const String geminiModel = 'gemini-2.5-flash';
  static const double geminiTemperature = 0.7;
  static const int geminiMaxTokens = 200;

  // RAG Configuration: Number of menu chunks to retrieve for context in semantic search
  static const int topKChunks = 3;
}