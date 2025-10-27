import 'dart:convert';
import 'package:http/http.dart' as http;

/// Service to handle OpenAI API interactions through secure backend proxy
class OpenAIService {
  // Backend API URL - should update this with deployed backend URL
  static const String _backendUrl = 'http://192.168.4.20:3000';

  bool _isInitialized = false;
  final http.Client _httpClient;

  // Constructor that allows dependency injection for testing
  // [httpClient] Optional HTTP client for testing purposes
  OpenAIService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  // Initialize the service
  void initialize() {
    if (_isInitialized) return;
    _isInitialized = true;
  }

  // Get AI response for user question via backend proxy
  // [userMessage] The customer's question; Returns the pig's quirky response
  Future<String> getResponse(String userMessage) async {
    if (!_isInitialized) {
      throw Exception('OpenAI service not initialized. Call initialize() first.');
    }

    try {
      // Make request to our secure backend proxy
      final response = await _httpClient.post(
        Uri.parse('$_backendUrl/api/chat'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'message': userMessage,
        }),
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw Exception('Request timeout - backend not responding');
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['response'] as String? ??
            "Oink! Sorry, I got a bit tongue-tied! Can you ask that again?";
      } else {
        // Using print here for MVP - will add proper logging later
        print('Backend API error: ${response.statusCode} - ${response.body}');
        return "Oink oink! My brain's a bit foggy right now. Could you try asking again?";
      }
    } catch (e) {
      print('OpenAI service error: $e');
      return "Oink oink! My brain's a bit foggy right now. Could you try asking again?";
    }
  }

  // Check if service is ready to use
  bool get isInitialized => _isInitialized;

  // Dispose of resources
  void dispose() {
    _httpClient.close();
  }
}
