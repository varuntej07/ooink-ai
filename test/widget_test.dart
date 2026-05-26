import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ooink/ViewModels/conversation_vm.dart';
import 'package:ooink/Views/home_screen.dart';
import 'package:ooink/repositories/session_repository.dart';
import 'package:ooink/services/analytics_service.dart';
import 'package:ooink/services/firestore_service.dart';
import 'package:ooink/services/rag_service.dart';
import 'package:ooink/services/speech_to_text_service.dart';
import 'package:ooink/services/tts_service.dart';
import 'package:provider/provider.dart';
import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initFirebaseForTesting();
    _mockAssetBundle();
  });

  testWidgets('all conversation states render without overflow', (
    tester,
  ) async {
    final scenarios =
        <
          ({
            ConversationState state,
            String statusText,
            String buttonText,
            String userInput,
            String aiResponse,
            String errorMessage,
            bool silenceCountdownActive,
          })
        >[
          (
            state: ConversationState.idle,
            statusText: "Hey! I'm your AI Pig!",
            buttonText: 'Tap to Talk',
            userInput: '',
            aiResponse: '',
            errorMessage: '',
            silenceCountdownActive: false,
          ),
          (
            state: ConversationState.listening,
            statusText: 'Listening...',
            buttonText: 'Tap to Cancel',
            userInput: 'Tonkotsu please',
            aiResponse: '',
            errorMessage: '',
            silenceCountdownActive: true,
          ),
          (
            state: ConversationState.processing,
            statusText: 'Thinking...',
            buttonText: 'Processing...',
            userInput: 'What is spicy?',
            aiResponse: '',
            errorMessage: '',
            silenceCountdownActive: false,
          ),
          (
            state: ConversationState.speaking,
            statusText: 'Oink oink! \u{1F437}',
            buttonText: 'Speaking...',
            userInput: 'Tell me about shoyu',
            aiResponse: 'Shoyu is savory and balanced.',
            errorMessage: '',
            silenceCountdownActive: false,
          ),
          (
            state: ConversationState.error,
            statusText: 'Tap to try again',
            buttonText: 'Tap to Talk',
            userInput: '',
            aiResponse: '',
            errorMessage: 'Oink! Something went wrong.',
            silenceCountdownActive: false,
          ),
        ];

    for (final scenario in scenarios) {
      await _pumpHomeScreen(
        tester,
        viewModel: FakeConversationViewModel(
          state: scenario.state,
          userInput: scenario.userInput,
          aiResponse: scenario.aiResponse,
          errorMessage: scenario.errorMessage,
          silenceCountdownActive: scenario.silenceCountdownActive,
        ),
      );

      expect(find.text(scenario.statusText), findsOneWidget);
      expect(find.text(scenario.buttonText), findsOneWidget);
      if (scenario.aiResponse.isNotEmpty) {
        expect(find.text(scenario.aiResponse), findsOneWidget);
      }
      if (scenario.errorMessage.isNotEmpty) {
        expect(find.text(scenario.errorMessage), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('response card is visible when aiResponse is non-empty', (
    tester,
  ) async {
    const response = 'The spicy miso has a rich broth and a kick of heat.';

    await _pumpHomeScreen(
      tester,
      viewModel: FakeConversationViewModel(
        state: ConversationState.idle,
        aiResponse: response,
      ),
    );

    expect(find.text(response), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pig image is not constrained to a fixed 350px size', (
    tester,
  ) async {
    await _pumpHomeScreen(
      tester,
      viewModel: FakeConversationViewModel(state: ConversationState.idle),
      logicalSize: const Size(800, 1280),
    );

    final imageSize = tester.getSize(find.byType(Image).first);

    expect(imageSize.height, greaterThan(350));
    expect(imageSize.width, greaterThan(350));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpHomeScreen(
  WidgetTester tester, {
  required FakeConversationViewModel viewModel,
  Size logicalSize = const Size(400, 900),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logicalSize;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ChangeNotifierProvider<ConversationViewModel>.value(
      value: viewModel,
      child: const MaterialApp(home: HomeScreen()),
    ),
  );

  await tester.pump();
}

void _mockAssetBundle() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMessageHandler('flutter/assets', (message) async {
    final key = utf8.decode(message!.buffer.asUint8List());
    if (key.endsWith('.png')) {
      return ByteData.sublistView(Uint8List.fromList(_transparentImageBytes));
    }
    if (key.endsWith('.json')) {
      return ByteData.sublistView(
        Uint8List.fromList(utf8.encode(_minimalLottieJson)),
      );
    }
    return null;
  });
}

class FakeConversationViewModel extends ConversationViewModel {
  FakeConversationViewModel({
    required ConversationState state,
    this.userInput = '',
    this.aiResponse = '',
    this.errorMessage = '',
    this.silenceCountdownActive = false,
  }) : _state = state,
       super(
         speechService: SpeechToTextService(),
         ttsService: TTSService(),
         ragService: RAGService(),
         sessionRepository: SessionRepository(
           firestoreService: FirestoreService(),
         ),
         analyticsService: AnalyticsService(),
       );

  ConversationState _state;

  @override
  final String userInput;

  @override
  final String aiResponse;

  @override
  final String errorMessage;

  @override
  final bool silenceCountdownActive;

  @override
  ConversationState get state => _state;

  @override
  bool get isIdle => _state == ConversationState.idle;

  @override
  bool get isListening => _state == ConversationState.listening;

  @override
  bool get isProcessing => _state == ConversationState.processing;

  @override
  bool get isSpeaking => _state == ConversationState.speaking;

  @override
  bool get hasError => _state == ConversationState.error;

  @override
  Future<void> startListening() async {}

  @override
  Future<void> stopListeningAndProcess() async {}

  @override
  Future<void> cancelListening() async {}

  @override
  Future<void> stopSpeaking() async {}

  @override
  Future<bool> submitFeedback(String text) async => true;
}

const List<int> _transparentImageBytes = <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  13,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  248,
  255,
  255,
  63,
  0,
  5,
  254,
  2,
  254,
  167,
  83,
  129,
  167,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
];

const String _minimalLottieJson =
    '{"v":"5.7.4","fr":30,"ip":0,"op":1,"w":1,"h":1,"nm":"test","ddd":0,"assets":[],"layers":[]}';
