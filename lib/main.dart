import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'firebase_options.dart';
import 'Views/home_screen.dart';
import 'ViewModels/conversation_viewmodel.dart';
import 'services/speech_to_text_service.dart';
import 'services/openai_service.dart';
import 'services/tts_service.dart';
import 'services/rag_service.dart';
import 'services/firestore_service.dart';
import 'repositories/session_repository.dart';

/// Main entry point - initializes environment variables and Firebase
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables from .env file
  await dotenv.load(fileName: ".env");

  // Initialize Firebase with the auto-generated config
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(const OoinkApp());
}

class OoinkApp extends StatelessWidget {
  const OoinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) {
        // Initialize all services
        final speechService = SpeechToTextService();
        final openAIService = OpenAIService();
        final ttsService = TTSService();
        final ragService = RAGService();

        final firestoreService = FirestoreService();
        final sessionRepository = SessionRepository(firestoreService: firestoreService);

        // Create ViewModel with all services including session management
        final viewModel = ConversationViewModel(
          speechService: speechService,
          openAIService: openAIService,
          ttsService: ttsService,
          ragService: ragService,
          sessionRepository: sessionRepository,
        );

        // Initialize services (this loads embeddings and sets up speech/TTS)
        viewModel.initialize();

        return viewModel;
      },
      child: MaterialApp(
        title: 'Ooink AI Pig',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.pink),
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
