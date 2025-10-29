import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import '../utils/logger.dart';

/// Service for Retrieval-Augmented Generation (RAG)
/// This loads the menu embeddings, performs semantic search, and calls OpenAI with relevant context
class RAGService {
  Map<String, dynamic>? _embeddingsData;      // Loaded embeddings data
  bool _isInitialized = false;

  // Initializes the RAG service by loading embeddings from assets, called once during app startup
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final String jsonString = await rootBundle.loadString('assets/ooink_embeddings.json');
      _embeddingsData = json.decode(jsonString);
      _isInitialized = true;
    } catch (e, stackTrace) {
      Logger.error('Failed to initialize RAG service', e, stackTrace);
      throw Exception('Failed to initialize RAG service: $e');
    }
  }

  // Ensures the service is initialized before use
  void _ensureInitialized() {
    if (!_isInitialized || _embeddingsData == null) {
      throw Exception('RAG service not initialized. Call initialize() first.');
    }
  }

  /// Performs semantic search to find relevant menu information
  /// Returns the top N most relevant text chunks based on keyword matching
  Future<List<String>> _semanticSearch(String query) async {
    final topK = AppConfig.topKChunks;
    _ensureInitialized();

    // For this implementation, using keyword matching instead of embeddings

    final chunks = _embeddingsData!['chunks'] as List<dynamic>;
    final queryLower = query.toLowerCase();

    // Score chunks based on keyword overlap
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
        'content': 'You are Pig, the friendly AI assistant at Ooink Ramen Restaurant.'
            'Answer customer questions about the menu using ONLY the context provided below.'
            'Be warm, enthusiastic about the food, and keep responses concise (2-3 sentences max).'
            'If asked about something not in the context, politely say you don\'t have that info with a joke.\n\n'
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
      final limitedMessages = messages.length > 5
          ? [messages.first, ...messages.sublist(messages.length - 5)]
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
        throw Exception('OpenAI API error: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      Logger.error('Error getting AI response', e, e is Error ? e.stackTrace : null);
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
