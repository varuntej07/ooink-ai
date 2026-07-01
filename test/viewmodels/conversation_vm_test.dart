// Unit tests for ConversationViewModel — the LiveKit voice state machine.
//
// Strategy: inject a fake VoiceSessionService whose event stream we drive
// manually, plus fake Analytics/Firestore so no network or LiveKit runs.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ooink/ViewModels/conversation_vm.dart';
import 'package:ooink/models/voice_session_status.dart';
import 'package:ooink/repositories/session_repository.dart';
import 'package:ooink/services/analytics_service.dart';
import 'package:ooink/services/firestore_service.dart';
import 'package:ooink/services/voice_session_service.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Fake voice service — lets the test push VoiceServerEvents into the VM.
// ---------------------------------------------------------------------------
class _FakeVoiceSessionService extends VoiceSessionService {
  final _ctrl = StreamController<VoiceServerEvent>.broadcast();
  bool startCalled = false;
  bool endCalled = false;

  @override
  Stream<VoiceServerEvent> get events => _ctrl.stream;

  @override
  Future<void> startSession() async => startCalled = true;

  @override
  Future<void> endSession() async => endCalled = true;

  void emit(VoiceServerEvent e) => _ctrl.add(e);

  @override
  void dispose() => _ctrl.close();
}

// ---------------------------------------------------------------------------
// Fake analytics — counts the events the VM is expected to log.
// ---------------------------------------------------------------------------
class _FakeAnalyticsService extends AnalyticsService {
  int sessionStarted = 0;
  int sessionEnded = 0;
  int querySent = 0;
  int errors = 0;

  @override
  void logSessionStarted({required int hourOfDay, required int dayOfWeek}) => sessionStarted++;
  @override
  void logSessionEnded({required int durationSeconds, required int messageCount, required String endedBy}) =>
      sessionEnded++;
  @override
  void logQuerySent({required String path, required double similarityScore, required int responseLatencyMs}) =>
      querySent++;
  @override
  void logErrorOccurred({required String errorType}) => errors++;
  @override
  void logFeedbackSubmitted({required bool hasText, required int messageCount}) {}
}

class _FakeFirestoreService extends FirestoreService {
  @override
  Future<void> createSession(session) async {}
  @override
  Future<void> addMessage(String sessionId, message) async {}
  @override
  Future<void> endSession(String sessionId) async {}
}

typedef _Harness = ({
  ConversationViewModel vm,
  _FakeVoiceSessionService voice,
  _FakeAnalyticsService analytics,
});

_Harness _build() {
  final voice = _FakeVoiceSessionService();
  final analytics = _FakeAnalyticsService();
  final vm = ConversationViewModel(
    voiceService: voice,
    sessionRepository: SessionRepository(firestoreService: _FakeFirestoreService()),
    analyticsService: analytics,
  );
  return (vm: vm, voice: voice, analytics: analytics);
}

/// Flush microtasks + the event loop so stream events reach the VM.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Connects a session: startSession + a `ready` event (creates the Firestore session).
Future<void> _connect(_Harness h) async {
  await h.vm.startSession();
  h.voice.emit(const VoiceServerEvent(type: VoiceEventType.ready));
  await _settle();
}

void main() {
  setUpAll(() async => initFirebaseForTesting());

  group('ConversationViewModel — voice state machine', () {
    test('a: initial state is idle', () {
      final h = _build();
      expect(h.vm.state, ConversationState.idle);
      expect(h.vm.isIdle, isTrue);
    });

    test('b: startSession → processing (connecting) and service called', () async {
      final h = _build();
      await h.vm.startSession();
      expect(h.voice.startCalled, isTrue);
      expect(h.vm.state, ConversationState.processing);
    });

    test('c: ready → still connecting (processing) until agent joins; session + analytics started',
        () async {
      final h = _build();
      await _connect(h);
      // Room is up but the Pig agent hasn't reported a state yet — stay "Connecting…".
      expect(h.vm.state, ConversationState.processing);
      expect(h.vm.hasActiveSession, isTrue);
      expect(h.analytics.sessionStarted, 1);

      // A real agent state then advances the UI out of "Connecting…".
      h.voice.emit(const VoiceServerEvent(
          type: VoiceEventType.agentState, agentState: VoiceAgentState.listening));
      await _settle();
      expect(h.vm.state, ConversationState.listening);
    });

    test('c2: audioLevels default to empty so the wave bars sit still', () {
      final h = _build();
      expect(h.vm.audioLevels.value, isEmpty);
    });

    test('d: agent states map to conversation states', () async {
      final h = _build();
      await _connect(h);

      h.voice.emit(const VoiceServerEvent(type: VoiceEventType.agentState, agentState: VoiceAgentState.speaking));
      await _settle();
      expect(h.vm.state, ConversationState.speaking);

      h.voice.emit(const VoiceServerEvent(type: VoiceEventType.agentState, agentState: VoiceAgentState.thinking));
      await _settle();
      expect(h.vm.state, ConversationState.processing);

      h.voice.emit(const VoiceServerEvent(type: VoiceEventType.agentState, agentState: VoiceAgentState.listening));
      await _settle();
      expect(h.vm.state, ConversationState.listening);
    });

    test('e: transcripts populate userInput and aiResponse', () async {
      final h = _build();
      await _connect(h);

      h.voice.emit(const VoiceServerEvent(type: VoiceEventType.userTranscript, text: 'what ramen do you have'));
      await _settle();
      expect(h.vm.userInput, 'what ramen do you have');

      h.voice.emit(const VoiceServerEvent(type: VoiceEventType.agentTranscript, text: 'We have Kotteri and Shoyu!'));
      await _settle();
      expect(h.vm.aiResponse, 'We have Kotteri and Shoyu!');
    });

    test('f: userFinal logs a message + query; agentFinal logs a message', () async {
      final h = _build();
      await _connect(h);
      final baseCount = h.vm.messageCount;

      h.voice.emit(const VoiceServerEvent(type: VoiceEventType.userFinal, text: 'do you have spicy ramen'));
      await _settle();
      expect(h.vm.messageCount, greaterThan(baseCount));
      expect(h.analytics.querySent, 1);

      final afterUser = h.vm.messageCount;
      h.voice.emit(const VoiceServerEvent(type: VoiceEventType.agentFinal, text: 'Yes, the spicy miso!'));
      await _settle();
      expect(h.vm.messageCount, greaterThan(afterUser));
    });

    test('g: ended → idle, session cleared and logged', () async {
      final h = _build();
      await _connect(h);
      expect(h.vm.hasActiveSession, isTrue);

      h.voice.emit(const VoiceServerEvent(type: VoiceEventType.ended));
      await _settle();
      expect(h.vm.state, ConversationState.idle);
      expect(h.vm.hasActiveSession, isFalse);
      expect(h.analytics.sessionEnded, 1);
    });

    test('h: error → error state with message, logged', () async {
      final h = _build();
      await _connect(h);

      h.voice.emit(const VoiceServerEvent(type: VoiceEventType.error, errorMessage: 'Voice connection failed.'));
      await _settle();
      expect(h.vm.hasError, isTrue);
      expect(h.vm.errorMessage, isNotEmpty);
      expect(h.analytics.errors, 1);
    });

    test('i: endSession → idle, service ended, session cleared', () async {
      final h = _build();
      await _connect(h);

      await h.vm.endSession();
      await _settle();
      expect(h.voice.endCalled, isTrue);
      expect(h.vm.state, ConversationState.idle);
      expect(h.vm.hasActiveSession, isFalse);
    });

    test('j: inactivity failsafe ends the session', () async {
      final h = _build();
      await _connect(h);
      expect(h.vm.hasActiveSession, isTrue);

      h.vm.triggerInactivityForTesting();
      await _settle();
      expect(h.voice.endCalled, isTrue);
      expect(h.vm.hasActiveSession, isFalse);
    });

    test('k: startSession is a no-op while already connected', () async {
      final h = _build();
      await _connect(h);
      h.voice.startCalled = false;

      await h.vm.startSession();
      expect(h.voice.startCalled, isFalse, reason: 'should not start a second session');
    });
  });
}
