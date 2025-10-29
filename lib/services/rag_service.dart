import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

/// Service for Retrieval-Augmented Generation (RAG)
/// This loads the menu embeddings, performs semantic search,
/// and calls OpenAI with relevant context
class RAGService {
  // Loaded embeddings data
  Map<String, dynamic>? _embeddingsData;
  bool _isInitialized = false;

  /// Initializes the RAG service by loading embeddings from assets
  /// This should be called once during app startup
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Load embeddings JSON from assets
      final String jsonString =
          await rootBundle.loadString('assets/ooink_embeddings.json');
      _embeddingsData = json.decode(jsonString);
      _isInitialized = true;
      print('RAG Service initialized with ${_embeddingsData!['chunks'].length} chunks');
    } catch (e) {
      print('Error loading embeddings: $e');
      throw Exception('Failed to initialize RAG service: $e');
    }
  }

  /// Ensures the service is initialized before use
  void _ensureInitialized() {
    if (!_isInitialized || _embeddingsData == null) {
      throw Exception('RAG service not initialized. Call initialize() first.');
    }
  }

  /// Computes cosine similarity between two vectors
  /// This measures how similar two embeddings are (1.0 = identical, 0.0 = orthogonal)
  /// NOTE: Reserved for future use with proper embedding-based search
  // ignore: unused_element
  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError('Vectors must have the same length');
    }

    // Calculate dot product
    double dotProduct = 0.0;
    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
    }

    // Calculate magnitudes
    double magnitudeA = 0.0;
    double magnitudeB = 0.0;
    for (int i = 0; i < a.length; i++) {
      magnitudeA += a[i] * a[i];
      magnitudeB += b[i] * b[i];
    }
    magnitudeA = sqrt(magnitudeA);
    magnitudeB = sqrt(magnitudeB);

    // Avoid division by zero
    if (magnitudeA == 0.0 || magnitudeB == 0.0) {
      return 0.0;
    }

    // Return cosine similarity
    return dotProduct / (magnitudeA * magnitudeB);
  }

  /// Gets embeddings for a query using OpenAI's embedding API
  /// This converts the user's question into a vector for semantic search
  /// NOTE: This method is not currently used due to simplification
  /// We use keyword matching instead to avoid additional API calls
  /// Reserved for future use with proper embedding-based search
  // ignore: unused_element
  Future<List<double>> _getQueryEmbedding(String query) async {
    try {
      final response = await http.post(
        Uri.parse(AppConfig.openAIEmbeddingEndpoint),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${AppConfig.openAIApiKey}',
        },
        body: json.encode({
          'input': query,
          'model': 'text-embedding-ada-002',
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final embedding = List<double>.from(data['data'][0]['embedding']);
        return embedding;
      } else {
        throw Exception(
            'Failed to get embedding: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      print('Error getting query embedding: $e');
      rethrow;
    }
  }

  /// Performs semantic search to find relevant menu information
  /// Returns the top N most relevant text chunks based on keyword matching
  Future<List<String>> _semanticSearch(String query) async {
    final topK = AppConfig.topKChunks;
    _ensureInitialized();

    // NOTE: For production, we would call OpenAI's embedding API to encode the query
    // For now, we'll use a simplified approach with keyword matching since we can't
    // replicate the exact all-MiniLM-L6-v2 model in Flutter

    // TODO: Either call OpenAI embedding API or implement a simpler keyword search
    // For this implementation, let's use keyword matching as a fallback

    final chunks = _embeddingsData!['chunks'] as List<dynamic>;
    final queryLower = query.toLowerCase();

    // Score chunks based on keyword overlap (simple but effective for menu queries)
    final scoredChunks = <Map<String, dynamic>>[];

    for (var chunk in chunks) {
      final text = (chunk['text'] as String).toLowerCase();

      // Calculate simple relevance score based on keyword presence
      double score = 0.0;

      // Split query into words
      final queryWords = queryLower.split(RegExp(r'\W+'));
      for (var word in queryWords) {
        if (word.length > 2 && text.contains(word)) {
          score += 1.0;
        }
      }

      if (score > 0) {
        scoredChunks.add({
          'text': chunk['text'],
          'score': score,
        });
      }
    }

    // Sort by score descending
    scoredChunks.sort((a, b) => (b['score'] as double).compareTo(a['score'] as double));

    // Return top K results
    final results = scoredChunks
        .take(topK)
        .map((chunk) => chunk['text'] as String)
        .toList();

    // If no keyword matches, return first few chunks as fallback
    if (results.isEmpty) {
      return chunks
          .take(topK)
          .map((chunk) => chunk['text'] as String)
          .toList();
    }

    return results;
  }

  /// Gets a response from OpenAI with conversation history and relevant context
  /// This is the main method that orchestrates the RAG pipeline
  Future<String> getResponse(
    String userMessage, {
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    _ensureInitialized();

    try {
      // Step 1: Perform semantic search to find relevant menu context
      final relevantChunks = await _semanticSearch(userMessage);

      // Step 2: Build context string from relevant chunks
      final contextString = relevantChunks.join('\n\n');

      // Step 3: Build messages array for OpenAI
      final messages = <Map<String, dynamic>>[];

      // Add system message with context
      messages.add({
        'role': 'system',
        'content': 'You are Pig, the friendly AI assistant at Ooink Ramen Fremont. '
            'Answer customer questions about the menu using ONLY the context provided below. '
            'Be warm, enthusiastic about the food, and keep responses concise (2-3 sentences max). '
            'If asked about something not in the context, politely say you don\'t have that info.\n\n'
            'MENU CONTEXT:\n$contextString',
      });

      // Add conversation history (if any)
      if (conversationHistory != null && conversationHistory.isNotEmpty) {
        // Skip system messages from history (we already added our own)
        final historyWithoutSystem = conversationHistory
            .where((msg) => msg['role'] != 'system')
            .toList();
        messages.addAll(historyWithoutSystem);
      }

      // Add current user message
      messages.add({
        'role': 'user',
        'content': userMessage,
      });

      // Limit context window to avoid token limits (keep last 10 messages + system)
      final limitedMessages = messages.length > 11
          ? [messages.first, ...messages.sublist(messages.length - 10)]
          : messages;

      // Step 4: Call OpenAI API
      final response = await http.post(
        Uri.parse(AppConfig.openAIEndpoint),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${AppConfig.openAIApiKey}',
        },
        body: json.encode({
          'model': AppConfig.openAIModel,
          'messages': limitedMessages,
          'temperature': AppConfig.openAITemperature,
          'max_tokens': AppConfig.openAIMaxTokens,
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final aiResponse = data['choices'][0]['message']['content'] as String;
        return aiResponse.trim();
      } else {
        throw Exception(
            'OpenAI API error: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      print('Error getting AI response: $e');
      // Return friendly error message instead of crashing
      return "Sorry, I'm having trouble connecting right now. Please try again!";
    }
  }

  /// Checks if the service is ready to use
  bool get isInitialized => _isInitialized;

  /// Gets the number of chunks loaded
  int get chunkCount {
    if (!_isInitialized || _embeddingsData == null) return 0;
    return (_embeddingsData!['chunks'] as List).length;
  }
}
