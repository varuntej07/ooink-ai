import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:ooink/services/vertex_ai_service.dart';
import '../config/app_config.dart';
import '../utils/logger.dart';

/// Service for Retrieval-Augmented Generation (RAG) using Firebase Vertex AI
/// Loads menu knowledge base, performs keyword-based search, and calls Gemini AI with relevant context
/// Uses simple keyword matching instead of embeddings for efficient, lightweight menu search
class RAGService {
  Map<String, dynamic>? _menuData; // Loaded menu knowledge base
  final VertexAIService _vertexAIService = VertexAIService();
  bool _isInitialized = false;

  /// Initializes the RAG service by loading menu kb from assets and initializing Vertex AI
  /// Called once during app startup in ConversationViewModel
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      Logger.log('RAG service: Starting initialization...');

      // Load menu kb (JSON format with structured menu data)
      Logger.log('RAG service: Loading menu knowledge base from assets...');
      final String jsonString = await rootBundle.loadString('assets/menu_knowledge_base_json.txt');

      Logger.log('RAG service: Parsing menu data (${jsonString.length} bytes)...');
      _menuData = json.decode(jsonString);

      Logger.log('RAG service: Initializing Vertex AI service...');
      _vertexAIService.initialize();

      _isInitialized = true;
      Logger.log('RAG service: Initialization complete! ${menuInfo}');
    } catch (e, stackTrace) {
      Logger.error('Failed to initialize RAG service', e, stackTrace);
      _isInitialized = false;
      _menuData = null;
      throw Exception('Failed to initialize RAG service: $e');
    }
  }

  void _ensureInitialized() {
    if (!_isInitialized || _menuData == null) {
      throw Exception('RAG service not initialized. Call initialize() first.');
    }
  }

  /// Performs keyword-based search to find relevant menu information
  /// Returns concatenated relevant sections from menu categories, items, and FAQs
  String _findRelevantContext(String query) {
    final topK = AppConfig.topKChunks;
    _ensureInitialized();

    final queryLower = query.toLowerCase();
    final relevantSections = <String>[];

    try {
      // Search restaurant info for general questions
      if (_menuData!.containsKey('restaurant_info')) {
        final restaurantInfo = _menuData!['restaurant_info'];
        final infoText = json.encode(restaurantInfo).toLowerCase();
        if (_containsKeywords(infoText, queryLower)) {
          relevantSections.add(
            'Restaurant: ${restaurantInfo['name']} - ${restaurantInfo['cuisine_type']}. '
            '${restaurantInfo['philosophy']}'
          );
        }
      }

      // Search menu categories and items
      if (_menuData!.containsKey('menu_categories')) {
        final categories = _menuData!['menu_categories'] as List;
        for (var category in categories) {
          final items = category['items'] as List? ?? [];
          for (var item in items) {
            final itemText = json.encode(item).toLowerCase();
            if (_containsKeywords(itemText, queryLower)) {
              final description = item['description'] ?? '';
              final price = item['price'] ?? '';
              final name = item['name'] ?? '';
              relevantSections.add('$name: $description ($price)');
            }
          }
        }
      }

      // Search common customer questions/FAQs
      if (_menuData!.containsKey('common_customer_questions')) {
        final questions = _menuData!['common_customer_questions'] as List;
        for (var qa in questions) {
          final qaText = '${qa['question']} ${qa['answer']}'.toLowerCase();
          if (_containsKeywords(qaText, queryLower)) {
            relevantSections.add('Q: ${qa['question']}\nA: ${qa['answer']}');
          }
        }
      }

      // Return top K most relevant sections, or general fallback if no matches
      if (relevantSections.isEmpty) {
        return 'General menu information available. Ask about our ramen, appetizers, or restaurant details.';
      }

      return relevantSections.take(topK).join('\n\n');
    } catch (e) {
      Logger.error('Error finding relevant context', e, null);
      return 'Menu information available.';
    }
  }

  /// Helper method to check if text contains any keywords from the query
  /// Splits query into words and checks for presence in the text (ignores short words < 3 chars)
  bool _containsKeywords(String text, String query) {
    final queryWords = query.split(RegExp(r'\W+')).where((w) => w.length > 2);
    return queryWords.any((word) => text.contains(word));
  }

  /// Gets a response from Vertex AI Gemini with conversation history and relevant menu context
  /// This is the main method that orchestrates the RAG pipeline:
  /// 1. Find relevant menu context using keyword matching
  /// 2. Build prompt with system instructions + context + conversation history
  /// 3. Call Firebase Vertex AI Gemini model
  /// 4. Return AI response
  Future<String> getResponse(
    String userMessage, {
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    _ensureInitialized();

    try {
      // Step 1: Find relevant menu context using keyword-based search
      final relevantContext = _findRelevantContext(userMessage);

      // Step 2: Build the full prompt with system instructions and context
      final StringBuffer prompt = StringBuffer();

      // Add system persona and instructions
      prompt.writeln('You are Pig, the friendly AI assistant at Ooink Ramen Restaurant.');
      prompt.writeln('Answer customer questions about the menu using ONLY the context provided below.');
      prompt.writeln('Be warm, enthusiastic about the food, and keep responses concise (2-3 sentences max).');
      prompt.writeln('If asked about something not in the context, politely say you don\'t have that info with a friendly tone.\n');

      // Add relevant menu context
      prompt.writeln('MENU CONTEXT:');
      prompt.writeln(relevantContext);
      prompt.writeln();

      // Add conversation history (for follow-up questions like "Is it spicy?") with limit to last 5 messages
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

      // Add current user message
      prompt.writeln('user: $userMessage');

      // Step 3: Call Firebase Vertex AI Gemini model
      final aiResponse = await _vertexAIService.generateContent(prompt.toString());

      return aiResponse.trim();
    } catch (e) {
      Logger.error('Error getting AI response', e, e is Error ? e.stackTrace : null);
      return "Sorry, I'm having trouble connecting right now. Please try again!";
    }
  }

  /// Checks if the service is ready to use
  bool get isInitialized => _isInitialized;

  /// Gets information about loaded menu data for debugging purposes
  String get menuInfo {
    if (!_isInitialized || _menuData == null) return 'Not initialized';

    final categories = _menuData!['menu_categories'] as List? ?? [];
    final questions = _menuData!['common_customer_questions'] as List? ?? [];

    return 'Menu loaded: ${categories.length} categories, ${questions.length} FAQs';
  }
}
