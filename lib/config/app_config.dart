/// Configuration for the application.
///
/// Speech-to-text, the LLM, text-to-speech, and the menu RAG pipeline all run
/// server-side in the LiveKit agent now. The app only needs the endpoint that
/// mints a LiveKit token for the kiosk.
class AppConfig {
  /// The getLiveKitToken Firebase function (no auth — public kiosk).
  /// Confirm this URL after `firebase deploy --only functions` and update it
  /// if the deployed URL differs.
  static const String voiceTokenUrl =
      'https://us-central1-ooinkai.cloudfunctions.net/getLiveKitToken';
}
