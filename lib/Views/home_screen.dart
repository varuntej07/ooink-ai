import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import '../ViewModels/conversation_vm.dart';

/// Displays pig bot images with state-based animations:
/// - Idle/Listening/Processing: static pig-bot-idle.png
/// - Speaking: alternating between pig-bot-idle.png and pig-bot-active.png
/// - After 10 min idle: Lottie dancing animation (returns to static on interaction)
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _idleTimer;
  Timer? _speakingAnimationTimer;
  bool _showIdleLottie = false;
  bool _showActiveImage = false; // Tracks if we're showing active or idle image during speaking

  @override
  void initState() {
    super.initState();
    _startIdleTimer();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _speakingAnimationTimer?.cancel();
    super.dispose();
  }

  /// Starts the 10-minute idle timer that triggers Lottie animation
  /// When timer expires, shows dancing Lottie animation instead of static pig
  void _startIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(minutes: 10), () {
      if (mounted) {
        setState(() {
          _showIdleLottie = true;
        });
      }
    });
  }

  /// Resets idle timer and returns to static pig image
  /// Called when user interacts with the screen (tap anywhere)
  void _resetIdleState() {
    if (_showIdleLottie) {
      setState(() {
        _showIdleLottie = false;
      });
    }
    _startIdleTimer();
  }

  /// Starts the speaking animation loop that alternates between idle and active images
  /// Switches every 300ms to create a talking effect
  void _startSpeakingAnimation() {
    _speakingAnimationTimer?.cancel();
    _speakingAnimationTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
      if (mounted) {
        setState(() {
          _showActiveImage = !_showActiveImage;
        });
      }
    });
  }

  /// Stops the speaking animation and resets to idle image
  void _stopSpeakingAnimation() {
    _speakingAnimationTimer?.cancel();
    setState(() {
      _showActiveImage = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _resetIdleState, // Reset idle timer when user taps anywhere
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Consumer<ConversationViewModel>(
            builder: (context, viewModel, child) {
              // Schedule state changes after the build phase to avoid setState during build
              // This uses addPostFrameCallback to defer setState calls until after the current frame
              WidgetsBinding.instance.addPostFrameCallback((_) {
                // Handle speaking animation start/stop based on state changes
                if (viewModel.isSpeaking && _speakingAnimationTimer == null) {
                  _startSpeakingAnimation();
                } else if (!viewModel.isSpeaking && _speakingAnimationTimer != null) {
                  _stopSpeakingAnimation();
                }

                // Reset idle timer when state changes (user interaction detected)
                if (!viewModel.isIdle) {
                  _resetIdleState();
                }
              });

              return Column(
                children: [
                  // Top section with status
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: _buildStatusText(viewModel),
                  ),

                  // Pig animation/image - changes based on state
                  Expanded(
                    child: Center(
                      child: _buildPigDisplay(viewModel),
                    ),
                  ),

                // User input display (only when listening or processing, not when speaking or after)
                if (viewModel.userInput.isNotEmpty && !viewModel.isSpeaking && viewModel.aiResponse.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.grey.shade100, Colors.grey.shade200],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.grey.withValues(alpha: 0.2),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Text(
                        viewModel.userInput,
                        style: TextStyle(
                          fontSize: 18,
                          fontStyle: FontStyle.italic,
                          color: Colors.grey.shade800,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),

                const SizedBox(height: 20),

                // AI response display (shown during speaking and after)
                if (viewModel.aiResponse.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.blue.shade50, Colors.cyan.shade50],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blue.withValues(alpha: 0.15),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Text(
                        viewModel.aiResponse,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.blue.shade900,
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
    ),
    );
  }

  /// Builds the pig display based on current state
  /// - Idle: static pig-bot-active.png (awake and ready)
  /// - Listening/Processing: static pig-bot-active.png
  /// - Speaking: alternating between idle and active
  /// - 10 min idle timeout: Lottie animation
  Widget _buildPigDisplay(ConversationViewModel viewModel) {
    // Show Lottie animation only after 10 min idle timeout
    if (_showIdleLottie) {
      return Lottie.asset(
        'assets/Pig-Dancing.json',
        width: 350,
        height: 350,
        fit: BoxFit.contain,
      );
    }

    // Show alternating images when speaking
    if (viewModel.isSpeaking) {
      return Image.asset(
        _showActiveImage ? 'assets/pig-bot-active.png' : 'assets/pig-bot-idle.png',
        width: 350,
        height: 350,
        fit: BoxFit.contain,
      );
    }

    // Default: show active image (pig looks awake and ready for idle, listening, and processing states)
    return Image.asset(
      'assets/pig-bot-active.png',
      width: 350,
      height: 350,
      fit: BoxFit.contain,
    );
  }

  Widget _buildStatusText(ConversationViewModel viewModel) {
    String statusText;
    List<Color> gradientColors;

    if (viewModel.isIdle) {
      statusText = "Hey! I'm your AI Pig!";
      gradientColors = [Colors.pink.shade400, Colors.purple.shade400];
    } else if (viewModel.isListening) {
      statusText = 'Listening...';
      gradientColors = [Colors.orange.shade400, Colors.deepOrange.shade400];
    } else if (viewModel.isProcessing) {
      statusText = 'Thinking...';
      gradientColors = [Colors.blue.shade400, Colors.cyan.shade400];
    } else if (viewModel.isSpeaking) {
      statusText = 'Oink oink! 🐷';
      gradientColors = [Colors.pink.shade400, Colors.pink.shade600];
    } else {
      statusText = 'Tap to try again';
      gradientColors = [Colors.red.shade400, Colors.red.shade600];
    }

    return ShaderMask(
      shaderCallback: (bounds) => LinearGradient(
        colors: gradientColors,
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(bounds),
      child: Text(
        statusText,
        style: const TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          letterSpacing: 0.5,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildActionButton(BuildContext context, ConversationViewModel viewModel) {
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(35)),
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
