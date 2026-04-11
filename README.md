# Ooink AI

Flutter kiosk app for Ooink Ramen. An animated AI pig answers customer questions about the menu via voice while they wait outside.

## Stack

- **Flutter** — Android kiosk UI
- **Firebase Vertex AI** — Gemini 2.5 Flash for responses
- **RAG pipeline** — semantic search over pre-embedded menu chunks (text-embedding-004)
- **Cloud Functions** — Node.js function for embedding generation
- **Firestore** — conversation logging
- **Provider** — state management (MVVM)

## Project Structure

```
lib/
  ViewModels/       # Business logic (ConversationViewModel)
  services/         # RAG, Vertex AI, TTS, STT, Firestore
  repositories/     # Session and conversation history
  models/           # Message, ConversationContext
  config/           # AppConfig (model, thresholds, timeouts)
functions/          # Cloud Function — generateEmbedding
assets/             # menu_embeddings.json, Pig animation
```

## Setup

1. Connect to Firebase project `ooinkai`
2. `flutter pub get`
3. `cd functions && npm install`

## Running

```bash
flutter run                  # app
flutter test                 # unit tests
firebase deploy --only functions   # deploy embedding function
```
