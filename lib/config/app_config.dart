/// Configuration class for the application
/// Uses Firebase Vertex AI which handles authentication automatically through Firebase
class AppConfig {
  static const String geminiModel = 'gemini-2.5-flash';
  static const double geminiTemperature = 0.7;
  // Max tokens - keeps responses snappy (naturally concise due to prompt) but allows up to 700 for detailed queries
  static const int geminiMaxTokens = 700;

  // RAG Configuration - Number of menu chunks to retrieve for context in semantic search
  static const int topKChunks = 6;

  // Minimum cosine similarity score for RAG context to be considered relevant.
  // Queries where the best-matching menu chunk scores below this skip Gemini entirely
  // and return the polite off-topic refusal directly — saving cost, latency, and preventing hallucination.
  static const double minSimilarityThreshold = 0.25;

  // Embedding model for semantic search
  // text-embedding-004 is the latest Vertex AI model (768 dimensions, best quality)
  static const String embeddingModel = 'text-embedding-004';

  // Silence detection for auto-send
  // Sound level (dB) above which we consider the user to be actively speaking
  static const double speechDetectedThreshold = 1.5;
  // Sound level (dB) below which we consider the user to have stopped speaking
  static const double silenceSoundThreshold = 0.5;
  // How long silence must last before auto-sending — gives user time to think mid-sentence
  static const Duration silenceAutoSendDelay = Duration(milliseconds: 2700);
}