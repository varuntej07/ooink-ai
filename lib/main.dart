import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'firebase_options.dart';
import 'Views/home_screen.dart';
import 'ViewModels/conversation_vm.dart';
import 'services/speech_to_text_service.dart';
import 'services/tts_service.dart';
import 'services/rag_service.dart';
import 'services/firestore_service.dart';
import 'repositories/session_repository.dart';

/// Main entry point - initializes environment variables, Firebase, and Crashlytics
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase with the auto-generated config
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize Firebase Crashlytics for error logging and monitoring
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
  
  // Catch async errors that aren't handled by FlutterError
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  runApp(const OoinkApp());
}

class OoinkApp extends StatefulWidget {
  const OoinkApp({super.key});

  @override
  State<OoinkApp> createState() => _OoinkAppState();
}

class _OoinkAppState extends State<OoinkApp> {
  ConversationViewModel? _viewModel;
  bool _isInitializing = true;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  /// Initialize all services and wait for them to be ready before showing the app
  /// This prevents users from interacting before RAG service loads the knowledge base
  Future<void> _initializeApp() async {
    try {
      // Initialize all services
      final speechService = SpeechToTextService();
      final ttsService = TTSService();
      final ragService = RAGService();

      final firestoreService = FirestoreService();
      final sessionRepository = SessionRepository(firestoreService: firestoreService);

      // Create ViewModel
      final viewModel = ConversationViewModel(
        speechService: speechService,
        ttsService: ttsService,
        ragService: ragService,
        sessionRepository: sessionRepository,
      );

      // AWAIT initialization - this ensures RAG knowledge base loads before UI shows
      await viewModel.initialize();

      if (mounted) {
        setState(() {
          _viewModel = viewModel;
          _isInitializing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _initError = e.toString();
          _isInitializing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ooink AI Pig',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.pink),
        useMaterial3: true,
      ),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    // Show loading screen while initializing
    if (_isInitializing) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/pig-bot-active.png',
                width: 200,
                height: 200,
              ),
              const SizedBox(height: 24),
              const CircularProgressIndicator(color: Colors.pink),
              const SizedBox(height: 16),
              const Text(
                'Pig is waking up...',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.pink,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Show error screen if initialization failed
    if (_initError != null) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 80, color: Colors.red),
                const SizedBox(height: 24),
                const Text(
                  'Oink! Failed to start up',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  'Please restart the app or contact support.',
                  style: TextStyle(fontSize: 16, color: Colors.grey[700]),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _isInitializing = true;
                      _initError = null;
                    });
                    _initializeApp();
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.pink),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Show main app with initialized ViewModel
    return ChangeNotifierProvider.value(
      value: _viewModel!,
      child: const HomeScreen(),
    );
  }
}
