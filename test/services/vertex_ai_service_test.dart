// Unit tests for VertexAIService — exponential backoff logic.
//
// Strategy: subclass VertexAIService and override invokeModel / invokeEmbedding
// to control successes and failures. Also override isModelReady / isFunctionsReady
// to bypass the Firebase null-guard, and override delayFn to run at zero delay
// so tests are instant.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ooink/services/vertex_ai_service.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Controllable subclass — drives the retry loop without Firebase.
// ---------------------------------------------------------------------------

/// Each item in [modelResponses] / [embeddingResponses] is consumed in order.
/// A String entry = success (returned as the response text / embedding).
/// An Exception entry = failure (thrown to trigger a retry or final failure).
class _TestableVertexAIService extends VertexAIService {
  final List<dynamic> modelResponses;
  final List<dynamic> embeddingResponses;

  int _modelCallIndex = 0;
  int _embeddingCallIndex = 0;

  // Track actual call counts so tests can assert on them
  int modelCallCount = 0;
  int embeddingCallCount = 0;

  _TestableVertexAIService({
    this.modelResponses = const [],
    this.embeddingResponses = const [],
  });

  @override
  bool get isModelReady => true;

  @override
  bool get isFunctionsReady => true;

  // Zero-delay retries so tests do not wait real seconds
  @override
  Future<void> Function(Duration) get delayFn => (_) async {};

  @override
  Future<String?> invokeModel(String prompt) async {
    modelCallCount++;
    final response = _modelCallIndex < modelResponses.length
        ? modelResponses[_modelCallIndex]
        : 'default response';
    _modelCallIndex++;
    if (response is Exception) throw response;
    return response as String;
  }

  @override
  Future<List<double>> invokeEmbedding(String text) async {
    embeddingCallCount++;
    final response = _embeddingCallIndex < embeddingResponses.length
        ? embeddingResponses[_embeddingCallIndex]
        : [0.0];
    _embeddingCallIndex++;
    if (response is Exception) throw response;
    return List<double>.from(response as List);
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() async {
    await initFirebaseForTesting();
  });

  // -------------------------------------------------------------------------
  group('VertexAIService.generateContent — exponential backoff', () {
    test('a: first attempt succeeds → 1 call, no retry', () async {
      final svc = _TestableVertexAIService(
        modelResponses: ['Ramen is delicious!'],
      );
      final result = await svc.generateContent('Tell me about ramen');
      expect(result, equals('Ramen is delicious!'));
      expect(svc.modelCallCount, 1, reason: 'Only one call should be made');
    });

    test('b: first fails, second succeeds → 2 calls', () async {
      final svc = _TestableVertexAIService(
        modelResponses: [
          Exception('transient error'), // attempt 1 fails
          'Success on retry', // attempt 2 succeeds
        ],
      );
      final result = await svc.generateContent('any prompt');
      expect(result, equals('Success on retry'));
      expect(svc.modelCallCount, 2, reason: 'Should retry once after first failure');
    });

    test('c: two failures, third succeeds → 3 calls', () async {
      final svc = _TestableVertexAIService(
        modelResponses: [
          Exception('error 1'),
          Exception('error 2'),
          'Third time is the charm',
        ],
      );
      final result = await svc.generateContent('any prompt');
      expect(result, equals('Third time is the charm'));
      expect(svc.modelCallCount, 3, reason: 'Should retry twice before succeeding');
    });

    test('d: all 3 attempts fail → returns user-friendly fallback message', () async {
      final svc = _TestableVertexAIService(
        modelResponses: [
          Exception('fail 1'),
          Exception('fail 2'),
          Exception('fail 3'),
        ],
      );
      final result = await svc.generateContent('any prompt');
      // After 3 failures, generateContent returns the friendly error message (not throwing)
      expect(result, contains("trouble connecting"),
          reason: 'User should see a friendly message after all retries fail');
      expect(svc.modelCallCount, 3, reason: 'All 3 attempts should be made');
    });

    test('e: exactly 3 retries attempted, not more', () async {
      // Ensure the loop stops at maxRetries=3 even with unlimited failures queued
      final svc = _TestableVertexAIService(
        modelResponses: List.generate(10, (_) => Exception('always fail')),
      );
      await svc.generateContent('any prompt');
      expect(svc.modelCallCount, 3,
          reason: 'Retry loop must cap at 3 attempts regardless of failures');
    });
  });

  // -------------------------------------------------------------------------
  group('VertexAIService.generateEmbedding — exponential backoff', () {
    test('f: first attempt succeeds → 1 call, correct dimensions', () async {
      final fakeEmbedding = List<double>.filled(768, 0.1);
      final svc = _TestableVertexAIService(
        embeddingResponses: [fakeEmbedding],
      );
      final result = await svc.generateEmbedding('ramen');
      expect(result, equals(fakeEmbedding));
      expect(svc.embeddingCallCount, 1);
    });

    test('g: two failures, third succeeds → 3 calls', () async {
      final fakeEmbedding = List<double>.filled(768, 0.5);
      final svc = _TestableVertexAIService(
        embeddingResponses: [
          Exception('network error 1'),
          Exception('network error 2'),
          fakeEmbedding,
        ],
      );
      final result = await svc.generateEmbedding('spicy ramen');
      expect(result, equals(fakeEmbedding));
      expect(svc.embeddingCallCount, 3);
    });

    test('h: all 3 attempts fail → throws exception (rethrows for RAGService to handle)', () async {
      final svc = _TestableVertexAIService(
        embeddingResponses: [
          Exception('fail 1'),
          Exception('fail 2'),
          Exception('fail 3'),
        ],
      );
      bool threw = false;
      try {
        await svc.generateEmbedding('any text');
      } catch (_) {
        threw = true;
      }
      expect(threw, isTrue,
          reason: 'generateEmbedding must rethrow after all 3 retries fail so RAGService can handle it');
      expect(svc.embeddingCallCount, 3,
          reason: 'All 3 retry attempts must be made before giving up');
    });

    test('i: non-retryable FirebaseFunctionsException (permission-denied) → fails immediately, 1 call', () async {
      // permission-denied means the Cloud Function IAM is misconfigured —
      // retrying will never help, so the service must give up after the first attempt.
      final svc = _NonRetryableEmbeddingService('permission-denied');
      try {
        await svc.generateEmbedding('any text');
      } catch (_) {}
      expect(svc.embeddingCallCount, 1,
          reason: 'permission-denied is non-retryable: must stop after 1 attempt');
    });

    test('j: non-retryable (invalid-argument) → fails immediately, 1 call', () async {
      // invalid-argument means the request was malformed — retrying the same input won't help.
      final svc = _NonRetryableEmbeddingService('invalid-argument');
      try {
        await svc.generateEmbedding('any text');
      } catch (_) {}
      expect(svc.embeddingCallCount, 1,
          reason: 'invalid-argument is non-retryable: must stop after 1 attempt');
    });

    test('k: non-retryable (failed-precondition) → fails immediately, 1 call', () async {
      // failed-precondition means the Vertex AI API is not enabled — retrying won't fix it.
      final svc = _NonRetryableEmbeddingService('failed-precondition');
      try {
        await svc.generateEmbedding('any text');
      } catch (_) {}
      expect(svc.embeddingCallCount, 1,
          reason: 'failed-precondition is non-retryable: must stop after 1 attempt');
    });
  });
}

// ---------------------------------------------------------------------------
// Service that throws a specific FirebaseFunctionsException on every call.
// Used to verify non-retryable code paths exit the loop after 1 attempt.
// ---------------------------------------------------------------------------
class _NonRetryableEmbeddingService extends VertexAIService {
  final String errorCode;
  int embeddingCallCount = 0;

  _NonRetryableEmbeddingService(this.errorCode);

  @override
  bool get isModelReady => true;
  @override
  bool get isFunctionsReady => true;
  @override
  Future<void> Function(Duration) get delayFn => (_) async {};

  @override
  Future<List<double>> invokeEmbedding(String text) async {
    embeddingCallCount++;
    throw FirebaseFunctionsException(
      message: 'test $errorCode',
      code: errorCode,
    );
  }
}
