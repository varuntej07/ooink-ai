import 'package:firebase_ai/firebase_ai.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../config/app_config.dart';
import '../utils/logger.dart';

/// Service wrapper for Firebase AI Gemini API
/// Uses Firebase AI SDK for text generation (Gemini) and Cloud Functions for embeddings (text-embedding-004)
class VertexAIService {
  GenerativeModel? _model;
  FirebaseFunctions? _functions;

  /// Initializes the AI service with Firebase AI SDK
  /// Sets up Gemini model for text generation (embeddings use Cloud Functions)
  void initialize() {
    try {
      // Initialize Gemini model for text generation (chat responses)
      // Uses the official firebase_ai package (migrated from firebase_vertexai)
      // vertexAI() is for production workloads using Vertex AI endpoint
      _model = FirebaseAI.vertexAI().generativeModel(
        model: AppConfig.geminiModel,
        generationConfig: GenerationConfig(
          temperature: AppConfig.geminiTemperature,
          maxOutputTokens: AppConfig.geminiMaxTokens,
        ),
      );

      // Initialize Cloud Functions for embeddings (us-central1 region matches Vertex AI)
      _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

      Logger.log('Firebase AI Service initialized with ${AppConfig.geminiModel}');
    } catch (e, stackTrace) {
      Logger.error('Failed to initialize Firebase AI Service', e, stackTrace);
      throw Exception('Failed to initialize Firebase AI Service: $e');
    }
  }

  /// Generates content based on the provided prompt using Firebase AI
  /// Takes a string prompt and returns the AI-generated response
  Future<String> generateContent(String prompt) async {
    if (_model == null) {
      throw Exception('Firebase AI Service not initialized. Call initialize() first.');
    }

    try {
      final response = await _model!.generateContent([Content.text(prompt)]);
      return response.text ?? '';
    } catch (e, stackTrace) {
      Logger.error('Error generating content with Firebase AI', e, stackTrace);
      return "Sorry, I'm having trouble connecting right now. Please try again!";
    }
  }

  /// Generates embedding vector for the given text using Vertex AI via Cloud Functions
  /// - Takes user query text (e.g., "kid friendly ramen")
  /// - Calls Cloud Function which securely calls Vertex AI embedding API (approximately 100-200ms latency)
  /// - Returns 768-dimensional vector representing semantic meaning
  /// - This vector is compared against pre-computed menu embeddings using cosine similarity
  Future<List<double>> generateEmbedding(String text) async {
    if (_functions == null) {
      throw Exception('Firebase AI Service not initialized. Call initialize() first.');
    }

    try {
      Logger.log('RAG: Calling Cloud Function to generate embedding...');

      // Call the generateEmbedding Cloud Function
      final callable = _functions!.httpsCallable('generateEmbedding');

      final result = await callable.call<Map<String, dynamic>>({
        'text': text,
      });

      // Extract embedding from response
      final data = result.data;

      if (!data.containsKey('embedding')) {
        throw Exception('Invalid response from Cloud Function: missing embedding data');
      }

      final embedding = List<double>.from(data['embedding'] as List);

      // Validate embedding dimensions (should be 768 for text-embedding-004)
      if (embedding.length != 768) {
        throw Exception('Invalid embedding dimensions: expected 768, got ${embedding.length}');
      }

      Logger.log('RAG: Embedding generated successfully (${embedding.length} dimensions)');
      return embedding;

    } on FirebaseFunctionsException catch (e) {

      String userMessage;
      switch (e.code) {
        case 'unauthenticated':
          userMessage = 'Authentication failed. Please check your internet connection.';
          break;
        case 'permission-denied':
          userMessage = 'Permission denied. Please contact support.';
          break;
        case 'resource-exhausted':
          userMessage = 'Service is busy. Please try again in a moment.';
          break;
        case 'invalid-argument':
          userMessage = 'Invalid input. Please try a shorter question.';
          break;
        case 'deadline-exceeded':
          userMessage = 'Request timed out. Please try again.';
          break;
        case 'failed-precondition':
          userMessage = e.message ?? 'Service not configured properly.';
          break;
        case 'internal':
          // For internal errors, include the actual error message from the Cloud Function
          userMessage = e.message ?? 'Failed to process your question. Please try again.';
          break;
        default:
          userMessage = 'Failed to process your question. Please try again.';
      }

      Logger.error('Cloud Function error generating embedding', e, e.stackTrace);
      throw Exception(userMessage);

    } catch (e, stackTrace) {
      Logger.error('Error generating embedding with Cloud Function', e, stackTrace);
      rethrow; // Rethrow so RAG service can handle embedding failures
    }
  }
}