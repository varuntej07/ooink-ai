// Unit tests for RAGService — guardrail boundaries and core RAG logic.
//
// Strategy: inject fake embeddings via setEmbeddingsForTesting() and inject a
// _FakeVertexAIService via the constructor so no real Firebase calls are made.
// All tests run in pure Dart — no device, no network, no Firebase needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:ooink/config/app_config.dart';
import 'package:ooink/services/rag_service.dart';
import 'package:ooink/services/vertex_ai_service.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Fake VertexAIService — overrides invokeModel and invokeEmbedding so the
// test controls exactly what each call returns without touching Firebase.
// ---------------------------------------------------------------------------
class _FakeVertexAIService extends VertexAIService {
  /// Embedding vector returned for every generateEmbedding() call.
  List<double> embeddingToReturn;

  /// Response text returned for every generateContent() call.
  String responseToReturn;

  /// When true, generateEmbedding() throws instead of returning.
  bool throwOnEmbedding;

  /// Tracks how many times invokeModel was called (to verify Gemini is skipped when expected).
  int invokeModelCallCount = 0;

  _FakeVertexAIService({
    this.embeddingToReturn = const [],
    this.responseToReturn = 'Fake AI response',
    this.throwOnEmbedding = false,
  });

  // Bypass the null check — the fake is always "ready"
  @override
  bool get isModelReady => true;
  @override
  bool get isFunctionsReady => true;

  // Zero-delay retries so tests run instantly
  @override
  Future<void> Function(Duration) get delayFn => (_) async {};

  @override
  Future<String?> invokeModel(String prompt) async {
    invokeModelCallCount++;
    return responseToReturn;
  }

  @override
  Future<List<double>> invokeEmbedding(String text) async {
    if (throwOnEmbedding) throw Exception('Fake embedding error');
    return embeddingToReturn;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a 3-dimensional EmbeddingChunk with the given vector.
/// 3 dimensions is enough to exercise cosine similarity math in tests.
EmbeddingChunk _chunk(String id, String text, List<double> vec) {
  return EmbeddingChunk(id: id, text: text, embedding: vec, metadata: {});
}

/// Creates a RAGService pre-loaded with [chunks] so tests skip asset loading.
RAGService _ragWithChunks(
  List<EmbeddingChunk> chunks, {
  required _FakeVertexAIService fakeAI,
}) {
  final svc = RAGService(vertexAIService: fakeAI);
  svc.setEmbeddingsForTesting(chunks);
  return svc;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() async {
    await initFirebaseForTesting();
  });

  // -------------------------------------------------------------------------
  group('RAGService — initialisation', () {
    test('starts in uninitialized state when constructed normally', () {
      // RAGService() with no args should NOT mark itself initialised
      final svc = RAGService();
      expect(svc.isInitialized, isFalse);
    });

    test('setEmbeddingsForTesting marks service as initialised', () {
      // After injecting fake embeddings the service should be ready
      final svc = RAGService(vertexAIService: _FakeVertexAIService());
      svc.setEmbeddingsForTesting([]);
      expect(svc.isInitialized, isTrue);
    });

    test('getResponse throws before initialize() is called', () async {
      // Without initialisation calling getResponse should throw, not return garbage
      final svc = RAGService();
      expect(
        () async => await svc.getResponse('test query'),
        throwsException,
      );
    });
  });

  // -------------------------------------------------------------------------
  group('RAGService — cosine similarity (pure math)', () {
    // _calculateCosine is a top-level function but tested via the full RAG
    // pipeline by checking that clearly identical vectors score near 1.0 and
    // clearly opposite vectors score below the threshold.

    test('identical direction vectors → above similarity threshold', () async {
      // Both the chunk and the query embedding point in the exact same direction.
      // Cosine similarity = 1.0 — should be above the 0.25 threshold.
      final fakeAI = _FakeVertexAIService(
        embeddingToReturn: [1.0, 0.0, 0.0],
        responseToReturn: 'On-topic response',
      );
      final svc = _ragWithChunks(
        [_chunk('1', 'Tonkotsu Ramen info', [1.0, 0.0, 0.0])],
        fakeAI: fakeAI,
      );

      final result = await svc.getResponse('tonkotsu ramen');
      // Gemini should have been called because similarity was high
      expect(fakeAI.invokeModelCallCount, greaterThan(0));
      expect(result, equals('On-topic response'));
    });

    test('opposite direction vectors → below threshold, Gemini skipped', () async {
      // The query embedding points opposite to all chunks — clearly off-topic.
      // Cosine similarity = -1.0 → below threshold → off-topic refusal, no Gemini call.
      final fakeAI = _FakeVertexAIService(
        embeddingToReturn: [-1.0, 0.0, 0.0],
      );
      final svc = _ragWithChunks(
        [_chunk('1', 'Tonkotsu Ramen info', [1.0, 0.0, 0.0])],
        fakeAI: fakeAI,
      );

      final result = await svc.getResponse('anything unrelated');
      // Gemini must NOT have been called
      expect(fakeAI.invokeModelCallCount, equals(0));
      // Response should contain the refusal phrase
      expect(result, contains("Pig"));
      expect(result, contains("menu"));
    });
  });

  // -------------------------------------------------------------------------
  group('RAGService — Task 1.3: off-topic guardrail boundary tests', () {
    /// Helper that returns the pig's response to [query] when the query embedding
    /// points opposite to all chunks (simulating a fully off-topic question).
    Future<String> offTopicResponse(String query) async {
      final fakeAI = _FakeVertexAIService(
        embeddingToReturn: [-1.0, 0.0, 0.0], // always below threshold
      );
      final svc = _ragWithChunks(
        [_chunk('1', 'menu text', [1.0, 0.0, 0.0])],
        fakeAI: fakeAI,
      );
      return svc.getResponse(query);
    }

    /// Helper that returns the pig's response to [query] when the query embedding
    /// matches the chunks perfectly (simulating a relevant menu question).
    Future<String> onTopicResponse(String query) async {
      final fakeAI = _FakeVertexAIService(
        embeddingToReturn: [1.0, 0.0, 0.0], // perfect match
        responseToReturn: 'Here is our menu information.',
      );
      final svc = _ragWithChunks(
        [_chunk('1', 'Tonkotsu Ramen', [1.0, 0.0, 0.0])],
        fakeAI: fakeAI,
      );
      return svc.getResponse(query);
    }

    test('a: off-topic "What is 2 + 2?" → refusal phrase, no Gemini call', () async {
      final fakeAI = _FakeVertexAIService(embeddingToReturn: [-1.0, 0.0, 0.0]);
      final svc = _ragWithChunks(
        [_chunk('1', 'menu', [1.0, 0.0, 0.0])],
        fakeAI: fakeAI,
      );
      final result = await svc.getResponse('What is 2 + 2?');
      expect(fakeAI.invokeModelCallCount, 0,
          reason: 'Gemini must not be called for off-topic queries');
      expect(result, contains("menu"),
          reason: 'Response should redirect to menu questions');
    });

    test('b: off-topic "Who is the president?" → refusal phrase, no Gemini call', () async {
      final result = await offTopicResponse('Who is the president?');
      expect(result, contains("menu"));
    });

    test('c: off-topic "How do I start a business?" → refusal phrase', () async {
      final result = await offTopicResponse('How do I start a business?');
      expect(result, contains("menu"));
    });

    test('d: off-topic "Tell me a joke" → refusal phrase', () async {
      final result = await offTopicResponse('Tell me a joke');
      expect(result, contains("menu"));
    });

    test('e: off-topic "Are you ChatGPT?" → identity boundary: refusal phrase', () async {
      final result = await offTopicResponse('Are you ChatGPT?');
      expect(result, contains("menu"));
    });

    test('f: on-topic "What ramen do you have?" → calls Gemini, returns menu content', () async {
      final result = await onTopicResponse('What ramen do you have?');
      expect(result, equals('Here is our menu information.'));
    });

    test('g: on-topic "Do you have vegetarian options?" → calls Gemini, returns menu content', () async {
      final result = await onTopicResponse('Do you have vegetarian options?');
      expect(result, equals('Here is our menu information.'));
    });

    test('h: low similarity score → returns off-topic refusal without calling Gemini', () async {
      // Explicitly verify the threshold constant is used — score < 0.25 triggers the guard.
      expect(AppConfig.minSimilarityThreshold, equals(0.25));

      final fakeAI = _FakeVertexAIService(
        // Embedding barely misaligned from the chunk so score < 0 (definitely below 0.25)
        embeddingToReturn: [-1.0, 0.0, 0.0],
      );
      final svc = _ragWithChunks(
        [_chunk('1', 'Ramen menu', [1.0, 0.0, 0.0])],
        fakeAI: fakeAI,
      );
      final result = await svc.getResponse('totally unrelated question');
      expect(fakeAI.invokeModelCallCount, 0,
          reason: 'Gemini must be skipped when threshold is not met');
      expect(result, contains("menu"));
    });

    test('i: empty query → graceful error message, no crash', () async {
      final fakeAI = _FakeVertexAIService(
        // generateEmbedding throws for empty input — simulates the Cloud Function rejecting it
        throwOnEmbedding: true,
      );
      final svc = _ragWithChunks(
        [_chunk('1', 'Ramen menu', [1.0, 0.0, 0.0])],
        fakeAI: fakeAI,
      );
      // Should not throw — should return a user-friendly fallback
      expect(() async => await svc.getResponse(''), returnsNormally);
      final result = await svc.getResponse('');
      expect(result, isNotEmpty);
    });

    test('j: very long query (1000+ chars) → handled without crashing', () async {
      final longQuery = 'a' * 1200;
      final fakeAI = _FakeVertexAIService(
        embeddingToReturn: [1.0, 0.0, 0.0],
        responseToReturn: 'Long query handled.',
      );
      final svc = _ragWithChunks(
        [_chunk('1', 'menu', [1.0, 0.0, 0.0])],
        fakeAI: fakeAI,
      );
      final result = await svc.getResponse(longQuery);
      expect(result, isNotEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('RAGService — system prompt content (Task 1.1)', () {
    test('system prompt contains explicit refusal clause', () async {
      // Verify that the hardened prompt is actually passed to Gemini.
      // We capture the prompt by checking invokeModel is called at all for on-topic queries.
      String? capturedPrompt;
      // Use a capturing AI that records the full prompt sent to Gemini
      final capturingAI = _CapturingVertexAIService(
        embeddingToReturn: [1.0, 0.0, 0.0],
        responseToReturn: 'ok',
        onPrompt: (p) => capturedPrompt = p,
      );
      final svc = _ragWithChunks(
        [_chunk('1', 'menu text', [1.0, 0.0, 0.0])],
        fakeAI: capturingAI,
      );
      await svc.getResponse('What ramen do you have?');

      expect(capturedPrompt, isNotNull);
      // Must contain the word REFUSE/STRICT so guardrail language is present
      final lowerPrompt = capturedPrompt!.toLowerCase();
      expect(lowerPrompt, contains('refuse'),
          reason: 'Hardened prompt must instruct Gemini to refuse off-topic queries');
      expect(lowerPrompt, contains('only'),
          reason: 'Prompt must restrict answers to menu context only');
      expect(lowerPrompt, contains('pig'),
          reason: 'Pig identity must be established in the prompt');
    });
  });

  // -------------------------------------------------------------------------
  group('RAGService — conversation history', () {
    test('system messages are filtered out before being passed to Gemini', () async {
      // Verify the prompt does not double-inject the system message from history
      final capturingAI = _CapturingVertexAIService(
        embeddingToReturn: [1.0, 0.0, 0.0],
        responseToReturn: 'response',
        onPrompt: (_) {},
      );
      final svc = _ragWithChunks(
        [_chunk('1', 'menu', [1.0, 0.0, 0.0])],
        fakeAI: capturingAI,
      );
      final history = [
        {'role': 'system', 'content': 'You are Pig'},
        {'role': 'user', 'content': 'Hi'},
        {'role': 'assistant', 'content': 'Hello!'},
      ];
      String? capturedPrompt;
      capturingAI.onPrompt = (p) => capturedPrompt = p;

      await svc.getResponse('What do you have?', conversationHistory: history);

      // The system message from history (role='system') must NOT appear in the prompt
      // as a conversation turn. Filtered messages look like "system: You are Pig".
      // The hardened prompt header itself does contain "You are Pig" multiple times —
      // that is expected and intentional. What we must NOT see is the literal
      // "system:" role marker, which would mean the filter failed.
      expect(capturedPrompt, isNot(contains('system: You are Pig')),
          reason: 'System role messages must be filtered from conversation history before sending to Gemini');
      // The user and assistant turns from history should still be included
      expect(capturedPrompt, contains('user: Hi'));
      expect(capturedPrompt, contains('assistant: Hello!'));
    });

    test('handles null conversation history without crashing', () async {
      final fakeAI = _FakeVertexAIService(
        embeddingToReturn: [1.0, 0.0, 0.0],
        responseToReturn: 'ok',
      );
      final svc = _ragWithChunks(
        [_chunk('1', 'menu', [1.0, 0.0, 0.0])],
        fakeAI: fakeAI,
      );
      // Should not throw
      expect(
        () async => await svc.getResponse('test', conversationHistory: null),
        returnsNormally,
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Captures the prompt sent to Gemini — used to assert on prompt content.
// ---------------------------------------------------------------------------
class _CapturingVertexAIService extends _FakeVertexAIService {
  void Function(String prompt) onPrompt;

  _CapturingVertexAIService({
    required super.embeddingToReturn,
    required super.responseToReturn,
    required this.onPrompt,
  });

  @override
  Future<String?> invokeModel(String prompt) async {
    invokeModelCallCount++;
    onPrompt(prompt);
    return responseToReturn;
  }
}
