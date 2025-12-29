import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
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

/// Top-level function for computing similarities in an isolate
/// Returns the indices of the top K chunks
List<int> _computeSimilaritiesInIsolate(
  _SimilarityRequest request,
) {
  final queryEmbedding = request.queryEmbedding;
  final chunks = request.chunks;
  final topK = request.topK;

  if (queryEmbedding.isEmpty) return [];

  // Compute scores
  final List<_ScoreIndex> scores = [];
  for (int i = 0; i < chunks.length; i++) {
    final similarity = _calculateCosine(queryEmbedding, chunks[i].embedding);
    scores.add(_ScoreIndex(i, similarity));
  }

  // Sort descending
  scores.sort((a, b) => b.score.compareTo(a.score));

  // Take top K
  return scores.take(topK).map((s) => s.index).toList();
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
  final VertexAIService _vertexAIService = VertexAIService();
  bool _isInitialized = false;

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
      final topIndices = await compute(
        _computeSimilaritiesInIsolate,
        _SimilarityRequest(queryEmbedding, _embeddings!, topK)
      );

      // 3. Retrieve chunks
      final relevantChunks = topIndices.map((i) => _embeddings![i]).toList();

      final relevantContext = relevantChunks.map((c) => c.text).join('\n\n');
      Logger.log('RAG: Retrieved ${relevantContext.length} chars of context');
      return relevantContext;

    } catch (e, stackTrace) {
      Logger.error('Error finding relevant context', e, stackTrace);
      
      // Pass specific error details to the prompt so the AI (or developer) knows what broke
      // This is crucial for debugging production issues like API quotas or App Check failures
      if (e.toString().contains('API has not been used') || e.toString().contains('403')) {
        return 'SYSTEM_ERROR: Firebase App Check API is disabled. Please enable it in Google Cloud Console.';
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

      // Step 2: Build the full prompt with system instructions and context
      final StringBuffer prompt = StringBuffer();
      prompt.writeln('You are Pig, the friendly AI assistant at Ooink Ramen Restaurant.');
      prompt.writeln('Answer customer questions about the menu using ONLY the context provided below.');
      prompt.writeln('Be warm, enthusiastic about the food, and keep responses concise (2-3 sentences max).');
      prompt.writeln('If asked about something not in the context, politely say you don\'t have that info with a friendly tone.\n');
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