import 'package:firebase_ai/firebase_ai.dart';
import '../config/app_config.dart';
import '../utils/logger.dart';

/// Service wrapper for Firebase Vertex AI Gemini API
/// Uses Firebase Vertex AI SDK which handles authentication automatically without an API key
class VertexAIService {
  GenerativeModel? _model;

  /// Initializes the Vertex AI service with Firebase Vertex AI SDK
  void initialize() {
    try {
      _model = FirebaseAI.vertexAI().generativeModel(
        model: AppConfig.geminiModel,
        generationConfig: GenerationConfig(
          temperature: AppConfig.geminiTemperature,
          maxOutputTokens: AppConfig.geminiMaxTokens,
        ),
      );
      Logger.log('Vertex AI Service initialized with ${AppConfig.geminiModel}');
    } catch (e, stackTrace) {
      Logger.error('Failed to initialize Vertex AI Service', e, stackTrace);
      throw Exception('Failed to initialize Vertex AI Service: $e');
    }
  }

  /// Generates content based on the provided prompt using Firebase Vertex AI
  /// Takes a string prompt and returns the AI-generated response
  Future<String> generateContent(String prompt) async {
    if (_model == null) {
      throw Exception('Vertex AI Service not initialized. Call initialize() first.');
    }

    try {
      final response = await _model!.generateContent([Content.text(prompt)]);
      return response.text ?? '';
    } catch (e, stackTrace) {
      Logger.error('Error generating content with Vertex AI', e, stackTrace);
      return "Sorry, I'm having trouble connecting right now. Please try again!";
    }
  }
}
