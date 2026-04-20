/// Which prompt path the RAG pipeline took for a given query
enum RagPath { rag, persona, error }

/// Wraps the AI response text with metadata the ViewModel needs for analytics
class RagResult {
  final String content;
  final double similarityScore;
  final RagPath path;

  const RagResult({
    required this.content,
    required this.similarityScore,
    required this.path,
  });
}
