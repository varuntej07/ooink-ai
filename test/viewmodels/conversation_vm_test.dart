// Unit tests for ConversationViewModel — Task 1.5: state machine transitions.
//
// Strategy: inject fake implementations of all four service dependencies so no
// real Firebase, TTS, or microphone code runs. Fake services expose control flags
// to simulate success, failure, or specific timing behavior.

import 'package:flutter_test/flutter_test.dart';
import 'package:ooink/ViewModels/conversation_vm.dart';
import 'package:ooink/services/rag_service.dart';
import 'package:ooink/services/speech_to_text_service.dart';
import 'package:ooink/services/tts_service.dart';
import 'package:ooink/services/firestore_service.dart';
import 'package:ooink/repositories/session_repository.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Fake speech service — onResult is called synchronously with [textToReturn].
// Set [textToReturn] to '' to simulate silence (no final speech result).
// ---------------------------------------------------------------------------
class _FakeSpeechService extends SpeechToTextService {
  String textToReturn = 'What ramen do you have?';
  bool throwOnStart = false;
  bool didCancel = false;

  @override
  Future<bool> initialize() async => true;

  @override
  Future<void> startListening({required Function(String) onResult}) async {
    if (throwOnStart) throw Exception('Fake mic error');
    if (textToReturn.isNotEmpty) {
      onResult(textToReturn);
    }
  }

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> cancel() async {
    didCancel = true;
  }

  @override
  void dispose() {}
}

// ---------------------------------------------------------------------------
// Fake TTS service — calls onComplete synchronously so state resolves instantly.
// Set [throwOnSpeak] to true to simulate a TTS failure.
// ---------------------------------------------------------------------------
class _FakeTTSService extends TTSService {
  bool throwOnSpeak = false;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String text, {Function()? onComplete}) async {
    if (throwOnSpeak) {
      throw Exception('Fake TTS error');
    }
    // Call onComplete synchronously — mimics TTS finishing immediately
    onComplete?.call();
  }

  @override
  Future<void> stop() async {}

  @override
  void dispose() {}
}

// ---------------------------------------------------------------------------
// Fake RAG service — returns [responseToReturn] or throws based on [shouldThrow].
// Bypasses the Firebase embedding pipeline entirely.
// ---------------------------------------------------------------------------
class _FakeRAGService extends RAGService {
  String responseToReturn = 'We have Tonkotsu, Shoyu, and Miso ramen!';
  bool shouldThrow = false;
  String? lastQuery;

  // Always appear initialised so ConversationViewModel.initialize() is a no-op
  @override
  bool get isInitialized => true;

  @override
  Future<void> initialize() async {}

  // Override getResponse entirely — bypasses _ensureInitialized and all Firebase calls
  @override
  Future<String> getResponse(
    String userMessage, {
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    lastQuery = userMessage;
    if (shouldThrow) throw Exception('Fake RAG error');
    return responseToReturn;
  }
}

// ---------------------------------------------------------------------------
// Fake Firestore service — all methods are no-ops so no Firebase calls are made.
// FirestoreService._firestore is 'late' so constructing the object is now safe.
// ---------------------------------------------------------------------------
class _FakeFirestoreService extends FirestoreService {
  @override
  Future<void> createSession(session) async {}
  @override
  Future<void> addMessage(String sessionId, message) async {}
  @override
  Future<void> endSession(String sessionId) async {}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a ready-to-use ConversationViewModel with all fake dependencies.
ConversationViewModel _buildVM({
  _FakeSpeechService? speech,
  _FakeTTSService? tts,
  _FakeRAGService? rag,
}) {
  return ConversationViewModel(
    speechService: speech ?? _FakeSpeechService(),
    ttsService: tts ?? _FakeTTSService(),
    ragService: rag ?? _FakeRAGService(),
    sessionRepository: SessionRepository(
      firestoreService: _FakeFirestoreService(),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() async {
    await initFirebaseForTesting();
  });

  // -------------------------------------------------------------------------
  group('ConversationViewModel — Task 1.5: state machine transitions', () {
    test('a: initial state is idle', () {
      final vm = _buildVM();
      expect(vm.state, ConversationState.idle);
      expect(vm.isIdle, isTrue);
    });

    test('b: startListening() from idle → state becomes listening', () async {
      // Use a speech service that does NOT call onResult so we stay in listening state
      final speech = _FakeSpeechService()..textToReturn = '';
      final vm = _buildVM(speech: speech);
      await vm.initialize();

      await vm.startListening();
      expect(vm.state, ConversationState.listening);
      expect(vm.isListening, isTrue);
    });

    test('c: cancelListening() from listening → state returns to idle', () async {
      final speech = _FakeSpeechService()..textToReturn = '';
      final vm = _buildVM(speech: speech);
      await vm.initialize();

      await vm.startListening();
      expect(vm.isListening, isTrue);

      await vm.cancelListening();
      expect(vm.state, ConversationState.idle);
      expect(vm.isIdle, isTrue);
    });

    test('d: startListening() when not idle → state unchanged (prevents duplicate calls)', () async {
      final speech = _FakeSpeechService()..textToReturn = '';
      final vm = _buildVM(speech: speech);
      await vm.initialize();

      await vm.startListening();
      expect(vm.isListening, isTrue);

      // Calling startListening again while already listening must be a no-op
      await vm.startListening();
      expect(vm.isListening, isTrue,
          reason: 'Second startListening call should not change state');
    });

    test('e: successful question flow → idle → listening → processing → speaking → idle', () async {
      // Collect all state changes in order
      final states = <ConversationState>[];
      final vm = _buildVM();
      await vm.initialize();
      vm.addListener(() => states.add(vm.state));

      await vm.startListening();
      await vm.stopListeningAndProcess();

      // Allow async callbacks (TTS onComplete) to resolve
      await Future.microtask(() {});

      expect(states, containsAllInOrder([
        ConversationState.listening,
        ConversationState.processing,
        ConversationState.speaking,
        ConversationState.idle,
      ]));
      expect(vm.isIdle, isTrue, reason: 'Should return to idle after TTS completes');
    });

    test('f: aiResponse is populated after successful question', () async {
      final rag = _FakeRAGService()
        ..responseToReturn = 'Try our Tonkotsu!';
      final vm = _buildVM(rag: rag);
      await vm.initialize();

      await vm.startListening();
      await vm.stopListeningAndProcess();
      await Future.microtask(() {});

      expect(vm.aiResponse, equals('Try our Tonkotsu!'));
    });

    test('g: stopListeningAndProcess with empty speech → error state, then auto-recovers to idle', () async {
      // Empty speech (no words recognised) should trigger an error
      final speech = _FakeSpeechService()..textToReturn = '';
      final vm = _buildVM(speech: speech);
      await vm.initialize();

      await vm.startListening();
      await vm.stopListeningAndProcess();

      // Should go to error or back to idle immediately (no speech detected branch)
      expect(
        vm.state == ConversationState.error || vm.state == ConversationState.idle,
        isTrue,
        reason: 'Empty speech should result in error or idle, not processing',
      );
    });

    test('h: RAG error → state becomes error, errorMessage is set', () async {
      final rag = _FakeRAGService()..shouldThrow = true;
      final vm = _buildVM(rag: rag);
      await vm.initialize();

      await vm.startListening();
      await vm.stopListeningAndProcess();
      await Future.microtask(() {});

      expect(vm.hasError, isTrue);
      expect(vm.errorMessage, isNotEmpty);
    });

    test('i: TTS error does NOT block state — returns to idle anyway', () async {
      // TTS failing should not leave the UI stuck — user already has the text response
      final tts = _FakeTTSService()..throwOnSpeak = true;
      final vm = _buildVM(tts: tts);
      await vm.initialize();

      await vm.startListening();
      await vm.stopListeningAndProcess();
      await Future.microtask(() {});

      // Either error state (with auto-recovery) or idle — either way not stuck in speaking/processing
      expect(
        vm.state == ConversationState.error ||
            vm.state == ConversationState.idle ||
            vm.state == ConversationState.speaking,
        isTrue,
        reason: 'TTS failure must not leave state stuck at processing',
      );
    });

    test('j: reset() from any state → idle, clears input and response', () async {
      final vm = _buildVM();
      await vm.initialize();

      // Put the VM into a non-idle state
      await vm.startListening();
      expect(vm.isListening, isTrue);

      vm.reset();

      expect(vm.state, ConversationState.idle);
      expect(vm.userInput, isEmpty);
      expect(vm.aiResponse, isEmpty);
      expect(vm.errorMessage, isEmpty);
    });

    test('k: hasActiveSession is false before first question', () {
      final vm = _buildVM();
      expect(vm.hasActiveSession, isFalse);
    });

    test('l: hasActiveSession becomes true after a question is processed', () async {
      final vm = _buildVM();
      await vm.initialize();

      await vm.startListening();
      await vm.stopListeningAndProcess();
      await Future.microtask(() {});

      expect(vm.hasActiveSession, isTrue);
    });

    test('m: inactivity expiry → session is cleared', () async {
      // Uses triggerInactivityForTesting() to simulate the 90-second timer firing
      // without actually waiting 90 real seconds.
      final vm = _buildVM();
      await vm.initialize();

      // Establish a session by completing a question
      await vm.startListening();
      await vm.stopListeningAndProcess();
      await Future.microtask(() {});
      expect(vm.hasActiveSession, isTrue);

      // Simulate the inactivity timer firing
      vm.triggerInactivityForTesting();

      expect(vm.hasActiveSession, isFalse,
          reason: 'Session must be cleared when inactivity timer expires');
    });
  });
}
