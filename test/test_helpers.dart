// Shared test helpers for the Ooink unit test suite.
//
// Unit tests must not depend on Firebase being initialized.
// Instead of mocking platform channels, we use Logger.suppressForTesting = true
// to silence all Crashlytics calls so tests run in pure Dart without any network,
// Firebase SDK, or native platform setup.

import 'package:flutter_test/flutter_test.dart';
import 'package:ooink/utils/logger.dart';

/// Sets up the minimal environment needed for unit tests:
/// - Ensures the Flutter test binding is active (required for compute() / isolates).
/// - Suppresses all Logger → Crashlytics calls so tests don't need Firebase initialized.
///
/// Call this once per test file inside setUpAll().
Future<void> initFirebaseForTesting() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.suppressForTesting = true;
}
