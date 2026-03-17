import 'package:firebase_ai/firebase_ai.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
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

  /// Returns true when the Gemini model is ready.
  /// Exposed so test subclasses can override to bypass the null-guard without calling initialize().
  @visibleForTesting
  bool get isModelReady => _model != null;

  /// Returns true when Cloud Functions is ready for embedding calls.
  /// Same pattern as isModelReady — allows test subclasses to bypass the guard.
  @visibleForTesting
  bool get isFunctionsReady => _functions != null;

  /// Delay function used between retries — injectable so unit tests can run at zero delay.
  /// In production this is the real Future.delayed; in tests override to a no-op.
  @visibleForTesting
  Future<void> Function(Duration) get delayFn => Future.delayed;

  /// Makes the actual Gemini generateContent API call.
  /// Extracted from the retry loop so tests can subclass and override just this call
  /// to simulate successes/failures without initializing Firebase.
  @visibleForTesting
  Future<String?> invokeModel(String prompt) async {
    final response = await _model!.generateContent([Content.text(prompt)]);
    return response.text;
  }

  /// Generates content based on the provided prompt using Firebase AI with automatic retry logic
  /// Takes a string prompt and returns the AI-generated response
  /// Implements exponential backoff retry (3 attempts) to handle transient network issues in kiosk environment
  /// This prevents single WiFi hiccups from causing customer-facing errors
  Future<String> generateContent(String prompt) async {
    if (!isModelReady) {
      throw Exception('Firebase AI Service not initialized. Call initialize() first.');
    }

    int retryCount = 0;
    const maxRetries = 3;

    while (retryCount < maxRetries) {
      try {
        final text = await invokeModel(prompt);

        // Success - return response immediately
        if (retryCount > 0) {
          Logger.log('AI request succeeded on retry #$retryCount');
        }
        return text ?? '';

      } catch (e, stackTrace) {
        retryCount++;

        // If this was the last retry, log error and return user-friendly message
        if (retryCount >= maxRetries) {
          Logger.error('Error generating content with Firebase AI after $maxRetries attempts', e, stackTrace);
          return "Sorry, I'm having trouble connecting right now. Please try again!";
        }

        // Exponential backoff: wait 2s, then 4s, then 6s before retrying
        // This gives WiFi time to recover from brief interruptions
        final delaySeconds = retryCount * 2;
        Logger.log('AI request failed (attempt $retryCount/$maxRetries), retrying in ${delaySeconds}s... Error: $e');
        await delayFn(Duration(seconds: delaySeconds));
      }
    }

    // Should never reach here, but safety fallback
    return "Sorry, I'm having trouble connecting right now. Please try again!";
  }

  /// Makes the actual Cloud Functions embedding API call.
  /// Extracted from the retry loop so tests can subclass and override just this call
  /// to simulate network failures without initializing Firebase or Cloud Functions.
  @visibleForTesting
  Future<List<double>> invokeEmbedding(String text) async {
    final callable = _functions!.httpsCallable('generateEmbedding');
    final result = await callable.call<Map<String, dynamic>>({'text': text});
    final data = result.data;
    if (!data.containsKey('embedding')) {
      throw Exception('Invalid response from Cloud Function: missing embedding data');
    }
    final embedding = List<double>.from(data['embedding'] as List);
    if (embedding.length != 768) {
      throw Exception('Invalid embedding dimensions: expected 768, got ${embedding.length}');
    }
    return embedding;
  }

  /// Generates embedding vector for the given text using Vertex AI via Cloud Functions with retry logic
  /// - Takes user query text (e.g., "kid friendly ramen")
  /// - Calls Cloud Function which securely calls Vertex AI embedding API (approximately 100-200ms latency)
  /// - Returns 768-dimensional vector representing semantic meaning
  /// - This vector is compared against pre-computed menu embeddings using cosine similarity
  /// - Implements retry logic for transient network failures in kiosk environment
  Future<List<double>> generateEmbedding(String text) async {
    if (!isFunctionsReady) {
      throw Exception('Firebase AI Service not initialized. Call initialize() first.');
    }

    int retryCount = 0;
    const maxRetries = 3;

    while (retryCount < maxRetries) {
      try {
        Logger.log('RAG: Calling Cloud Function to generate embedding (attempt ${retryCount + 1}/$maxRetries)...');

        final embedding = await invokeEmbedding(text);

        if (retryCount > 0) {
          Logger.log('RAG: Embedding request succeeded on retry #$retryCount');
        }
        Logger.log('RAG: Embedding generated successfully (${embedding.length} dimensions)');
        return embedding;

      } on FirebaseFunctionsException catch (e) {
        retryCount++;

        // For certain error codes, don't retry (they won't succeed on retry)
        final nonRetryableCodes = ['permission-denied', 'invalid-argument', 'failed-precondition'];

        if (nonRetryableCodes.contains(e.code) || retryCount >= maxRetries) {
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
              userMessage = e.message ?? 'Failed to process your question. Please try again.';
              break;
            default:
              userMessage = 'Failed to process your question. Please try again.';
          }

          Logger.error('Cloud Function error generating embedding after $retryCount attempts', e, e.stackTrace);
          throw Exception(userMessage);
        }

        // Retry transient errors (deadline-exceeded, resource-exhausted, unauthenticated)
        final delaySeconds = retryCount * 2;
        Logger.log('Embedding request failed (${e.code}), retrying in ${delaySeconds}s...');
        await delayFn(Duration(seconds: delaySeconds));

      } catch (e, stackTrace) {
        retryCount++;

        if (retryCount >= maxRetries) {
          Logger.error('Error generating embedding with Cloud Function after $maxRetries attempts', e, stackTrace);
          rethrow; // Rethrow so RAG service can handle embedding failures
        }

        // Retry on general network errors
        final delaySeconds = retryCount * 2;
        Logger.log('Embedding request failed, retrying in ${delaySeconds}s... Error: $e');
        await delayFn(Duration(seconds: delaySeconds));
      }
    }

    // Should never reach here, but safety fallback
    throw Exception('Failed to generate embedding after $maxRetries attempts');
  }
}