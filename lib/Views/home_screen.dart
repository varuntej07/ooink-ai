import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import '../ViewModels/conversation_viewmodel.dart';

/// Home screen view for Ooink AI kiosk
/// Displays dancing pig animation and conversation interface
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Consumer<ConversationViewModel>(
          builder: (context, viewModel, child) {
            return Column(
              children: [
                // Top section with status
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: _buildStatusText(viewModel),
                ),

                // Pig animation
                Expanded(
                  child: Center(
                    child: Lottie.asset(
                      'assets/Pig-Dancing.json',
                      width: 350,
                      height: 350,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),

                // User input display (when listening or processing)
                if (viewModel.userInput.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.pink.shade50,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        viewModel.userInput,
                        style: const TextStyle(
                          fontSize: 18,
                          fontStyle: FontStyle.italic,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),

                const SizedBox(height: 20),

                // AI response display (when speaking)
                if (viewModel.isSpeaking)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.pink.shade100,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        viewModel.aiResponse,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),

                const SizedBox(height: 20),

                // Error message display
                if (viewModel.hasError)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.red.shade100,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        viewModel.errorMessage,
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.red,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),

                // Main action button
                Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: _buildActionButton(context, viewModel),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildStatusText(ConversationViewModel viewModel) {
    String statusText;
    Color statusColor;

    if (viewModel.isIdle) {
      statusText = 'Hello! Welcome, Im your AI pig assistant';
      statusColor = Colors.pink;
    } else if (viewModel.isListening) {
      statusText = 'Listening... 👂';
      statusColor = Colors.orange;
    } else if (viewModel.isProcessing) {
      statusText = 'Thinking... 🤔';
      statusColor = Colors.blue;
    } else if (viewModel.isSpeaking) {
      statusText = 'Oink oink! 🐷';
      statusColor = Colors.pink;
    } else {
      statusText = 'Tap to try again';
      statusColor = Colors.red;
    }

    return Text(
      statusText,
      style: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.bold,
        color: statusColor,
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _buildActionButton(
      BuildContext context, ConversationViewModel viewModel) {
    String buttonText;
    VoidCallback? onPressed;
    Color buttonColor;

    if (viewModel.isIdle || viewModel.hasError) {
      buttonText = 'Tap to Talk';
      onPressed = () => viewModel.startListening();
      buttonColor = Colors.pink;
    } else if (viewModel.isListening) {
      buttonText = 'Stop & Send';
      onPressed = () => viewModel.stopListeningAndProcess();
      buttonColor = Colors.orange;
    } else if (viewModel.isProcessing) {
      buttonText = 'Processing...';
      onPressed = null; // Disabled during processing
      buttonColor = Colors.grey;
    } else if (viewModel.isSpeaking) {
      buttonText = 'Speaking...';
      onPressed = () => viewModel.stopSpeaking();
      buttonColor = Colors.blue;
    } else {
      buttonText = 'Tap to Talk';
      onPressed = () => viewModel.startListening();
      buttonColor = Colors.pink;
    }

    return SizedBox(
      width: double.infinity,
      height: 70,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: buttonColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(35),
          ),
          elevation: 8,
        ),
        child: Text(
          buttonText,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
