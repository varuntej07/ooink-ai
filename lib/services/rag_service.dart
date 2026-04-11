import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ooink/services/vertex_ai_service.dart';
import '../config/app_config.dart';
import '../utils/logger.dart';

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

      // Step 1: Build a context-enriched search query before embedding.
      // The raw userMessage alone loses context for vague follow-ups like "what about the price?"
      // or "is it good?" — without knowing what "it" refers to, the embedding lands on the wrong chunks.
      // We prepend the last two user turns from history so the embedding carries the topic being discussed.
      // Example: "user: tell me about shoyu \n user: what's the price?" embeds far better than just "what's the price?"
      String searchQuery = userMessage;
      if (conversationHistory != null && conversationHistory.length > 1) {
        final recentUserTurns = conversationHistory
            .where((m) => m['role'] == 'user')
            .toList();
        // Take up to the last 2 user messages (excluding the current one which is already in userMessage)
        final contextTurns = recentUserTurns.length > 2
            ? recentUserTurns.sublist(recentUserTurns.length - 2)
            : recentUserTurns;
        if (contextTurns.isNotEmpty) {
          final contextPrefix = contextTurns.map((m) => m['content'] as String).join('\n');
          searchQuery = '$contextPrefix\n$userMessage';
          Logger.log('RAG: Context-enriched search query: "$searchQuery"');
        }
      }

      // Step 2: Find relevant menu context using semantic search on the enriched query
      // This retrieves the top K most semantically similar chunks
      final relevantContext = await _findRelevantContext(searchQuery);

      // Critical Error Handling: If context search failed with a system error (e.g., App Check disabled),
      // report it immediately instead of hallucinating an answer.
      if (relevantContext.startsWith('SYSTEM_ERROR:')) {
        return "⚠️ ${relevantContext.split('SYSTEM_ERROR: ')[1]}";
      }

      // Threshold guard: similarity was too low meaning query is not menu-related.
      // Route to persona prompt so Pig handles greetings, jokes, and small talk naturally,
      // while soft-deflecting truly off-topic topics (math, politics) back to the menu.
      if (relevantContext == 'BELOW_THRESHOLD') {
        Logger.log('RAG: Below threshold — routing to persona prompt');
        return await _getPersonaResponse(userMessage, conversationHistory: conversationHistory);
      }

      // Step 2: Build the full prompt with hardened system instructions and context.
      // The STRICT RULES section below is Task 1.1 — explicit off-topic refusal clauses so
      // Gemini cannot comply with questions outside Ooink's menu even if it "wants" to.
      final StringBuffer prompt = StringBuffer();
      prompt.writeln('You are Pig, the fun and friendly AI bot answering user questions at Ooink Ramen Capitol Hill.');
      prompt.writeln('Your main job is helping customers with menu questions, but you are also warm and personable.');
      prompt.writeln('Keep all responses concise — 1 to 3 sentences max. Customers want to interact with you.');
      prompt.writeln('');
      prompt.writeln('RULES:');
      prompt.writeln('1. Answer menu questions using ONLY the context provided below. Do not invent information.');
      prompt.writeln('2. For greetings, small talk, or personal questions directed at Pig ("hi", "how are you",');
      prompt.writeln('   "what did you eat today", "are you hungry", "what\'s your favorite", "thanks", "bye"),');
      prompt.writeln('   respond in character as a ramen-obsessed pig — be fun, weave in the food naturally.');
      prompt.writeln('   Example: "Oink! I had three bowls of Kotteri for breakfast and I\'m already eyeing');
      prompt.writeln('   the spicy miso for dinner. Want to try one?"');
      prompt.writeln('3. For truly unrelated topics (math, politics, coding, other restaurants), soft-deflect:');
      prompt.writeln('   "Ha, that\'s above my snout\'s pay grade! I\'m much better at helping you pick a bowl 🐷"');
      prompt.writeln('4. Never claim to be ChatGPT, Gemini, or another AI. You are Pig developed by Varun.');
      prompt.writeln('5. If context is missing for a valid menu question, say: "I don\'t have that detail');
      prompt.writeln('   right now, why not ask our staff directly? They can help!"');
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

  /// Called when menu similarity is below threshold — Pig responds in character
  /// without any menu context injected. Handles greetings, jokes, identity questions,
  /// and soft-deflects truly off-topic topics (math, politics) back to the food.
  Future<String> _getPersonaResponse(
    String userMessage, {
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    Logger.log('RAG: Building persona prompt for non-menu query');
    final prompt = _buildPersonaPrompt(userMessage, conversationHistory);
    return await _vertexAIService.generateContent(prompt);
  }

  /// Builds the persona-only prompt (no menu context) passed to Gemini for non-menu queries.
  /// Conversation history is included so Pig remembers the exchange and stays coherent.
  String _buildPersonaPrompt(
    String userMessage,
    List<Map<String, dynamic>>? conversationHistory,
  ) {
    final StringBuffer prompt = StringBuffer();
    prompt.writeln('You are Pig, the fun and playful mascot at Ooink Ramen Fremont.');
    prompt.writeln('You are chatting with customers waiting outside the restaurant.');
    prompt.writeln('');
    prompt.writeln('YOUR PERSONALITY:');
    prompt.writeln('- Warm, enthusiastic, and a little goofy');
    prompt.writeln('- Loves ramen, loves people, and has a great sense of humor');
    prompt.writeln('- Can make a quick pig-themed or ramen joke when asked — keep it short and fun');
    prompt.writeln('- Naturally steers the conversation back to food without being pushy');
    prompt.writeln('');
    prompt.writeln('HOW TO RESPOND:');
    prompt.writeln('- Greetings or "how are you" → reply warmly in character, then invite a menu question');
    prompt.writeln('- Joke requests → tell one short fun one (pig or ramen-themed if possible), then pivot to menu');
    prompt.writeln('- Identity questions ("are you a robot?") → stay in character as Pig, keep it light');
    prompt.writeln('- Math, politics, news, other restaurants → soft-deflect:');
    prompt.writeln('  "Ha, that\'s above my snout\'s pay grade! I\'m much better at helping you pick the perfect bowl 🐷"');
    prompt.writeln('- Harmful or inappropriate topics → decline warmly and redirect to food');
    prompt.writeln('');
    prompt.writeln('IMPORTANT:');
    prompt.writeln('- Keep responses SHORT — 1 to 3 sentences max. Customers are standing outside.');
    prompt.writeln('- Never claim to be ChatGPT, Gemini, or any other AI. You are Pig.');
    prompt.writeln('- After any social exchange, naturally invite them to ask about the menu.');
    prompt.writeln('');

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
    return prompt.toString();
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