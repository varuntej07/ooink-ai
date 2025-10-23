import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'Views/home_screen.dart';
import 'ViewModels/conversation_viewmodel.dart';
import 'services/speech_to_text_service.dart';
import 'services/openai_service.dart';
import 'services/tts_service.dart';

Future<void> main() async {
  await dotenv.load(fileName: ".env");      // Load environment variables
  runApp(const OoinkApp());
}

class OoinkApp extends StatelessWidget {
  const OoinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) {
        final speechService = SpeechToTextService();
        final openAIService = OpenAIService();
        final ttsService = TTSService();

        // Create ViewModel with services
        final viewModel = ConversationViewModel(
          speechService: speechService,
          openAIService: openAIService,
          ttsService: ttsService,
        );

        // Load API key from environment
        final apiKey = dotenv.env['OPENAI_API_KEY'] ?? '';
        if (apiKey.isEmpty) {
          throw Exception('OPENAI_API_KEY not found in .env file');
        }
        viewModel.initialize(apiKey);

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
