import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ooink/services/vertex_ai_service.dart';
import '../config/app_config.dart';
import '../utils/logger.dart';

// Refusal phrase used when a query is off-topic — also asserted in tests to verify guardrails
const String _offTopicRefusal =
    "I'm Pig, Ooink's menu assistant! I can only help with questions about "
    "our ramen, menu items, prices, hours, or restaurant. "
    "What would you like to know? 🐷";

/// Top-level function for parsing JSON in an isolate
List<EmbeddingChunk> _parseEmbeddingsInIsolate(String jsonString) {
  final Map<String, dynamic> data = json.decode(jsonString);
  final List<dynamic> chunksData = data['chunks'] as List;

  return chunksData.map((chunk) {
    return EmbeddingChunk(
      id: chunk['id'] as String,
      text: chunk['text'] as String,
      embedding: List<double>.from(chunk['embedding'] as List),
      metadata: Map<String, dynamic>.from(chunk['metadata'] as Map),
    );
  }).toList();
}

/// Holds the result of similarity computation: top-K indices AND the highest score found.
/// Returned from the isolate so _findRelevantContext can check the threshold without
/// needing a second isolate round-trip.
class _SimilarityResult {
  final List<int> topIndices;
  final double topScore; // Highest cosine similarity across all chunks

  _SimilarityResult(this.topIndices, this.topScore);
}

/// Top-level function for computing similarities in an isolate.
/// Returns both the top-K chunk indices AND the best similarity score so the caller
/// can decide whether the query is on-topic before invoking Gemini.
_SimilarityResult _computeSimilaritiesInIsolate(
  _SimilarityRequest request,
) {
  final queryEmbedding = request.queryEmbedding;
  final chunks = request.chunks;
  final topK = request.topK;

  if (queryEmbedding.isEmpty) return _SimilarityResult([], 0.0);

  // Compute scores
  final List<_ScoreIndex> scores = [];
  for (int i = 0; i < chunks.length; i++) {
    final similarity = _calculateCosine(queryEmbedding, chunks[i].embedding);
    scores.add(_ScoreIndex(i, similarity));
  }

  // Sort descending
  scores.sort((a, b) => b.score.compareTo(a.score));

  // Take top K
  final topK_ = scores.take(topK).toList();
  final topScore = topK_.isNotEmpty ? topK_.first.score : 0.0;
  return _SimilarityResult(topK_.map((s) => s.index).toList(), topScore);
}

double _calculateCosine(List<double> a, List<double> b) {
  if (a.length != b.length) return 0.0;
  double dotProduct = 0.0;
  double magA = 0.0;
  double magB = 0.0;
  for (int i = 0; i < a.length; i++) {
    dotProduct += a[i] * b[i];
    magA += a[i] * a[i];
    magB += b[i] * b[i];
  }
  magA = math.sqrt(magA);
  magB = math.sqrt(magB);
  if (magA == 0 || magB == 0) return 0.0;
  return dotProduct / (magA * magB);
}

class _SimilarityRequest {
  final List<double> queryEmbedding;
  final List<EmbeddingChunk> chunks;
  final int topK;

  _SimilarityRequest(this.queryEmbedding, this.chunks, this.topK);
}

class _ScoreIndex {
  final int index;
  final double score;

  _ScoreIndex(this.index, this.score);
}

/// Service for Retrieval-Augmented Generation (RAG) using Firebase Vertex AI
class RAGService {
  List<EmbeddingChunk>? _embeddings;
  final VertexAIService _vertexAIService;
  bool _isInitialized = false;

  /// Default constructor — creates its own VertexAIService (production use).
  /// Optionally accepts a [vertexAIService] for dependency injection in unit tests
  /// without requiring actual Firebase initialization.
  RAGService({VertexAIService? vertexAIService})
      : _vertexAIService = vertexAIService ?? VertexAIService();

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      Logger.log('RAG service: Starting initialization...');
      
      // Load raw JSON string (fast I/O)
      final String embeddingsJson = await rootBundle.loadString('assets/menu_embeddings.json');
      
      // Offload parsing to background isolate to prevent UI freeze
      Logger.log('RAG service: Parsing embeddings in background isolate...');
      _embeddings = await compute(_parseEmbeddingsInIsolate, embeddingsJson);

      Logger.log('RAG service: Loaded ${_embeddings!.length} embedding chunks');

      _vertexAIService.initialize();
      _isInitialized = true;
    } catch (e, stackTrace) {
      Logger.error('Failed to initialize RAG service', e, stackTrace);
      _isInitialized = false;
      _embeddings = null;
      throw Exception('Failed to initialize RAG service: $e');
    }
  }

  void _ensureInitialized() {
    if (!_isInitialized || _embeddings == null) {
      throw Exception('RAG service not initialized. Call initialize() first.');
    }
  }

  Future<String> _findRelevantContext(String query) async {
    final topK = AppConfig.topKChunks;
    _ensureInitialized();

    try {
      Logger.log('RAG: Finding relevant context for query: "$query"');

      // 1. Generate embedding (Network call)
      final List<double> queryEmbedding = await _vertexAIService.generateEmbedding(query);

      // 2. Compute similarity (Heavy Math - Offloaded to Isolate)
      Logger.log('RAG: Computing similarities in background...');
      final result = await compute(
        _computeSimilaritiesInIsolate,
        _SimilarityRequest(queryEmbedding, _embeddings!, topK),
      );

      // 3. Log the top similarity score so we can tune the threshold after going live
      Logger.log('RAG: Top similarity score: ${result.topScore.toStringAsFixed(3)} for query: "$query"');

      // 4. Guard: if every menu chunk is a poor match, the query is almost certainly off-topic.
      // Skip Gemini entirely — return a sentinel that getResponse() converts to the refusal phrase.
      // This saves cost, latency, and prevents Gemini from being creative with unrelated topics.
      if (result.topScore < AppConfig.minSimilarityThreshold) {
        Logger.log('RAG: Score below threshold (${AppConfig.minSimilarityThreshold}), skipping AI — off-topic query blocked');
        return 'BELOW_THRESHOLD';
      }

      // 5. Retrieve chunks
      final relevantChunks = result.topIndices.map((i) => _embeddings![i]).toList();

      final relevantContext = relevantChunks.map((c) => c.text).join('\n\n');
      Logger.log('RAG: Retrieved ${relevantContext.length} chars of context');
      return relevantContext;

    } catch (e, stackTrace) {
      Logger.error('Error finding relevant context', e, stackTrace);

      // Pass specific error details to the prompt so the AI (or developer) knows what broke
      // This is crucial for debugging production issues like API quotas or permission errors
      if (e.toString().contains('API has not been used') || e.toString().contains('403')) {
        return 'SYSTEM_ERROR: Vertex AI API error. Please check API permissions and quota in Google Cloud Console.';
      }

      return 'Menu information available. Please ask about our ramen, appetizers, or restaurant details.';
    }
  }

  Future<String> getResponse(
    String userMessage, {
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    _ensureInitialized();

    try {

      // Step 1: Find relevant menu context using semantic search
      // This retrieves the top K most semantically similar chunks to the user's query
      final relevantContext = await _findRelevantContext(userMessage);

      // Critical Error Handling: If context search failed with a system error (e.g., App Check disabled),
      // report it immediately instead of hallucinating an answer.
      if (relevantContext.startsWith('SYSTEM_ERROR:')) {
        return "⚠️ ${relevantContext.split('SYSTEM_ERROR: ')[1]}";
      }

      // Threshold guard: similarity was too low — query is off-topic, skip Gemini entirely.
      // Return the shared refusal phrase so customers know to ask about the menu instead.
      if (relevantContext == 'BELOW_THRESHOLD') {
        Logger.log('RAG: Returning off-topic refusal (below similarity threshold)');
        return _offTopicRefusal;
      }

      // Step 2: Build the full prompt with hardened system instructions and context.
      // The STRICT RULES section below is Task 1.1 — explicit off-topic refusal clauses so
      // Gemini cannot comply with questions outside Ooink's menu even if it "wants" to.
      final StringBuffer prompt = StringBuffer();
      prompt.writeln('You are Pig, the friendly AI assistant at Ooink Ramen Fremont.');
      prompt.writeln('Your ONLY job is to help customers with questions about Ooink Ramen:');
      prompt.writeln('menu items, ingredients, prices, restaurant hours, location, parking, and dining experience.');
      prompt.writeln('Be warm, enthusiastic about the food, and keep responses concise (2-3 sentences max).');
      prompt.writeln('');
      prompt.writeln('STRICT RULES — follow these without exception:');
      prompt.writeln('1. Answer using ONLY the context provided below. Do not invent information.');
      prompt.writeln('2. ONLY answer questions about Ooink Ramen and its menu. For ANY other topic,');
      prompt.writeln('   respond with exactly: "I\'m Pig, Ooink\'s menu assistant! I can only help with');
      prompt.writeln('   menu questions. What would you like to know about our ramen? 🐷"');
      prompt.writeln('3. Topics you must REFUSE to discuss: math, coding, politics, general knowledge,');
      prompt.writeln('   other restaurants, personal advice, jokes, weather, or anything not about Ooink.');
      prompt.writeln('4. Never claim to be a different AI (ChatGPT, Gemini, etc.). You are Pig, exclusively.');
      prompt.writeln('5. If context is missing for a valid menu question, say: "I don\'t have that detail');
      prompt.writeln('   right now — our staff can help! Ask them directly. 🐷"');
      prompt.writeln('');
      prompt.writeln('MENU CONTEXT:');
      prompt.writeln(relevantContext);
      prompt.writeln();

      if (conversationHistory != null && conversationHistory.isNotEmpty) {
        final limitedHistory = conversationHistory.length > 5
            ? conversationHistory.sublist(conversationHistory.length - 5)
            : conversationHistory;

        final historyWithoutSystem =
            limitedHistory.where((msg) => msg['role'] != 'system').toList();
        for (var message in historyWithoutSystem) {
          prompt.writeln('${message['role']}: ${message['content']}');
        }
      }

      prompt.writeln('user: $userMessage');

      final response = await _vertexAIService.generateContent(prompt.toString());

      return response;
    } catch (e) {
      Logger.error('Error getting AI response', e, e is Error ? e.stackTrace : null);
      return "Sorry, I'm having trouble connecting right now. Please try again!";
    }
  }

  bool get isInitialized => _isInitialized;

  /// Injects fake embeddings directly, bypassing asset loading.
  /// Call this in unit tests instead of initialize() so tests run without real assets or Firebase.
  @visibleForTesting
  void setEmbeddingsForTesting(List<EmbeddingChunk> embeddings) {
    _embeddings = embeddings;
    _isInitialized = true;
  }
}

class EmbeddingChunk {
  final String id;
  final String text;
  final List<double> embedding;
  final Map<String, dynamic> metadata;

  EmbeddingChunk({
    required this.id,
    required this.text,
    required this.embedding,
    required this.metadata,
  });
}