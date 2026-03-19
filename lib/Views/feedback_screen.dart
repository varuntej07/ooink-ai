import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../ViewModels/conversation_vm.dart';

/// Full-screen feedback form that slides up from the home screen
/// After submit: switches to a success view that auto-closes after 2.5s
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen>
    with TickerProviderStateMixin {

  // Drives the staggered entrance — each element uses a different Interval slice of this controller
  late final AnimationController _entranceController;
  // Drives the success view pop-in after a submission
  late final AnimationController _successController;

  final TextEditingController _textController = TextEditingController();
  bool _submitted = false;

  // Each element gets its own slide + fade derived from _entranceController via Interval
  late final Animation<double> _pigScale;
  late final Animation<double> _pigFade;
  late final Animation<Offset> _titleSlide;
  late final Animation<double> _titleFade;
  late final Animation<Offset> _subtitleSlide;
  late final Animation<double> _subtitleFade;
  late final Animation<Offset> _fieldSlide;
  late final Animation<double> _fieldFade;
  late final Animation<double> _buttonFade;

  // Success pop-in animations
  late final Animation<double> _successScale;
  late final Animation<double> _successFade;

  @override
  void initState() {
    super.initState();

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );

    _successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    // Pig bounces in with easeOutBack — the slight overshoot gives it personality
    _pigScale = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOutBack),
      ),
    );
    _pigFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController, curve: const Interval(0.0, 0.35)),
    );

    // Title slides up from a slight offset with easeOutCubic
    _titleSlide = Tween<Offset>(begin: const Offset(0, 0.35), end: Offset.zero).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.2, 0.65, curve: Curves.easeOutCubic),
      ),
    );
    _titleFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController, curve: const Interval(0.2, 0.6)),
    );

    // Subtitle follows 100ms after title
    _subtitleSlide = Tween<Offset>(begin: const Offset(0, 0.35), end: Offset.zero).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.3, 0.75, curve: Curves.easeOutCubic),
      ),
    );
    _subtitleFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController, curve: const Interval(0.3, 0.7)),
    );

    // Text field follows 100ms after subtitle
    _fieldSlide = Tween<Offset>(begin: const Offset(0, 0.35), end: Offset.zero).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.4, 0.85, curve: Curves.easeOutCubic),
      ),
    );
    _fieldFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController, curve: const Interval(0.4, 0.8)),
    );

    // Button fades in last
    _buttonFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entranceController, curve: const Interval(0.6, 1.0)),
    );

    // Success view pops in with easeOutBack for a satisfying bounce
    _successScale = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _successController, curve: Curves.easeOutBack),
    );
    _successFade = Tween<double>(begin: 0.0, end: 1.0).animate(_successController);

    _entranceController.forward();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _successController.dispose();
    _textController.dispose();
    super.dispose();
  }

  /// Submits feedback through the ViewModel and switches to success view on success
  Future<void> _handleSubmit(ConversationViewModel viewModel) async {
    if (_textController.text.trim().isEmpty) return;
    final success = await viewModel.submitFeedback(_textController.text);
    if (success && mounted) {
      setState(() => _submitted = true);
      _successController.forward();
      // Auto-close after 3.5s so the user sees the thank-you message
      Timer(const Duration(milliseconds: 3500), () {
        if (mounted) Navigator.of(context).pop();
      });
    } else if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Ooink! Couldn't send that. Try again?"),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Consumer<ConversationViewModel>(
          builder: (context, viewModel, _) {
            return _submitted ? _buildSuccess() : _buildForm(viewModel);
          },
        ),
      ),
    );
  }

  /// Success view — bounces in and auto-closes after 2.5s
  Widget _buildSuccess() {
    return Center(
      child: FadeTransition(
        opacity: _successFade,
        child: ScaleTransition(
          scale: _successScale,
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/pig-bot-active.png', width: 140, height: 140),
                const SizedBox(height: 28),
                const Text(
                  'Ooink! Got it!',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    color: Colors.pink,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                Text(
                  "Pig will read this between ramen breaks.\nYou're basically a restaurant consultant now.",
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey.shade600,
                    height: 1.6,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Main feedback form with staggered entrance animations
  Widget _buildForm(ConversationViewModel viewModel) {
    return Column(
      children: [
        // Close button — always visible, no animation needed
        Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 4, right: 4),
            child: IconButton(
              icon: Icon(Icons.close_rounded, size: 28, color: Colors.grey.shade400),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 4),

                // Pig bounces in
                FadeTransition(
                  opacity: _pigFade,
                  child: ScaleTransition(
                    scale: _pigScale,
                    child: Image.asset('assets/pig-bot-active.png', width: 110, height: 110),
                  ),
                ),

                const SizedBox(height: 20),

                // Title with gradient
                SlideTransition(
                  position: _titleSlide,
                  child: FadeTransition(
                    opacity: _titleFade,
                    child: ShaderMask(
                      shaderCallback: (bounds) => LinearGradient(
                        colors: [Colors.pink.shade400, Colors.purple.shade400],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ).createShader(bounds),
                      child: const Text(
                        'Any thoughts of improving me?',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                // Subtitle — pig banter
                SlideTransition(
                  position: _subtitleSlide,
                  child: FadeTransition(
                    opacity: _subtitleFade,
                    child: Text(
                      "Don't be shy — Pig can take it.\nEven the spicy kind.",
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey.shade500,
                        height: 1.6,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // Feedback text field
                SlideTransition(
                  position: _fieldSlide,
                  child: FadeTransition(
                    opacity: _fieldFade,
                    child: TextField(
                      controller: _textController,
                      maxLines: 5,
                      maxLength: 500,
                      textInputAction: TextInputAction.newline,
                      style: const TextStyle(fontSize: 16),
                      decoration: InputDecoration(
                        hintText: "What's on your mind?\nPig is all snout.",
                        hintStyle: TextStyle(
                          color: Colors.grey.shade400,
                          height: 1.6,
                          fontSize: 15,
                        ),
                        filled: true,
                        fillColor: Colors.grey.shade50,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: Colors.grey.shade200),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: Colors.grey.shade200),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: Colors.pink.shade300, width: 2),
                        ),
                        contentPadding: const EdgeInsets.all(16),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // Submit button
                FadeTransition(
                  opacity: _buttonFade,
                  child: SizedBox(
                    width: double.infinity,
                    height: 58,
                    child: ElevatedButton(
                      onPressed: viewModel.isFeedbackSubmitting ? null : () => _handleSubmit(viewModel),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.pink,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.pink.shade200,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(29),
                        ),
                        elevation: 6,
                      ),
                      child: viewModel.isFeedbackSubmitting
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.5,
                              ),
                            )
                          : const Text(
                              'Send to Pig',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
