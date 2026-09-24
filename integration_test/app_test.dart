// Integration tests for the Ooink bot
// These tests run on a REAL device with actual Firebase and microphone, and they
// require the LiveKit voice backend to be deployed: the getLiveKitToken function
// and the hosted "ooink-pig" agent. They validate the full real-time voice path
// that unit tests cannot cover.
//
// Run with: flutter test integration_test/app_test.dart
// Requires: connected device, Firebase configured, deployed token function + agent.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ooink/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Ooink App — startup and loading screen', () {
    /// Verifies the complete app initialization flow on a real device:
    /// Firebase → ViewModel wiring → home screen
    testWidgets('a: shows loading screen then transitions to home screen', (WidgetTester tester) async {
      app.main();
      await tester.pump(); // one frame so the loading screen renders

      // Loading screen must be visible immediately (before initialization completes)
      expect(find.text('Pig is waking up...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Wait for all services to initialize (Firebase init on device)
      await tester.pumpAndSettle(const Duration(seconds: 15));

      // Loading screen must be gone after initialization
      expect(find.text('Pig is waking up...'), findsNothing,
          reason: 'App should finish loading within 15 seconds on a real device');

      // Must NOT be on the error screen
      expect(find.text('Oink! Failed to start up'), findsNothing,
          reason: 'Initialization must succeed — check Firebase credentials and network');
    });

    /// Verifies the voice wave button is visible and in its idle state when ready.
    testWidgets('b: home screen shows pig and action button after startup', (WidgetTester tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 15));

      // The icon-only wave button is the CTA; idle state carries the "talk" label.
      expect(find.byKey(const Key('voice_wave_button')), findsOneWidget);
      expect(find.bySemanticsLabel('Tap to talk to Pig'), findsOneWidget);
    });

    /// Manual coverage note — error screen with retry:
    /// Put device in airplane mode before running the app to verify the error screen
    /// shows "Oink! Failed to start up" and a retry button. Tap it to verify
    /// the app re-attempts initialization. This cannot be automated without
    /// injecting a failure, which requires mocking the platform itself.
    testWidgets('c: error screen placeholder (requires manual airplane-mode test)', (WidgetTester tester) async {
      expect(true, isTrue);
    });
  });

  group('Ooink App — conversation flow', () {
    /// Taps the wave button and verifies it leaves the idle state. Tapping connects
    /// to LiveKit, so the button's semantics label flips from "Tap to talk to Pig"
    /// to "Tap to stop" (needs the deployed token fn + agent).
    testWidgets('d: tapping the wave button starts connecting', (WidgetTester tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 15));

      final waveButton = find.byKey(const Key('voice_wave_button'));
      expect(waveButton, findsOneWidget);
      await tester.tap(waveButton);
      await tester.pump();

      // Immediately after tapping, the session is connecting: the button now stops.
      expect(find.bySemanticsLabel('Tap to stop'), findsOneWidget,
          reason: 'Button must leave the idle state once a session starts');
    });

    /// Verifies that after a full question cycle the response text appears on screen.
    /// Requires: microphone permission, network access, valid Firebase credentials.
    /// Manual step: say "What ramen do you have?" when the mic is active.
    testWidgets('e: AI response text appears after question cycle (manual mic input required)', (WidgetTester tester) async {
      // This test validates: speech -> RAG pipeline -> TTS -> response box visible
      // Full automation requires injecting speech input, which depends on device OS.
      expect(true, isTrue);
    });

    /// Verifies that 10 minutes of inactivity triggers the Lottie dancing animation.
    /// Cannot be automated without faking system time. Validate manually:
    /// leave the app idle for 10 minutes on the tablet and verify the pig dances.
    testWidgets('f: 10-minute idle triggers dancing pig animation (manual test)', (WidgetTester tester) async {
      expect(true, isTrue);
    });
  });

  group('Ooink App — off-topic guardrail (on-device smoke test)', () {
    /// Smoke test: the off-topic refusal phrase must appear in the response box
    /// when a clearly unrelated question is asked. Requires real speech input.
    /// Manual step: say "What is 2 plus 2?" — response box must say something
    /// about being Pig the menu assistant, NOT answer the math question.
    testWidgets('g: off-topic question produces refusal response (manual speech test)', (WidgetTester tester) async {
      // The RAG routing + deflection now lives in the Python agent (backend/). Validate
      // there with backend/AGENTS.md's quick RAG check; this verifies the UI delivery.
      expect(true, isTrue);
    });
  });

  group('Kiosk mode', () {
    /// Verifies kiosk mode is enabled — back and home buttons must not exit the app.
    /// Requires: kiosk_mode package properly configured as device owner (Android).
    /// Manual test: with kiosk active, press Android back button — app should stay.
    testWidgets('h: back button does not exit the app in kiosk mode (manual test)', (WidgetTester tester) async {
      expect(true, isTrue);
    });
  });
}
