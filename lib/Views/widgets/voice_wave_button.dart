import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

/// Visual mode for [VoiceWaveButton], derived from the conversation state.
enum VoiceWaveMode {
  /// Session off (idle/error). Bars sit still at a small baseline.
  off,

  /// Connecting to the room / waiting for the Pig to join. Bars do a gentle
  /// loading pulse so the kiosk doesn't look frozen.
  connecting,

  /// In conversation. Bars react to the Pig's real voice amplitude; they fall
  /// to a low idle wave while the Pig is silent (customer's turn).
  active,
}

/// The single, minimal voice control: a tappable circle of five rounded bars.
///
/// - OFF: still, flat bars (matches "stays still when turned off").
/// - CONNECTING: a soft sine pulse.
/// - ACTIVE: bars ride [audioLevels] — the Pig's live voice — so it "moves like a
///   wave when talking".
///
/// It carries no conversation logic: the parent supplies [mode], [color], the
/// [audioLevels] listenable, and the [onTap] toggle (start when off, end when on).
class VoiceWaveButton extends StatefulWidget {
  const VoiceWaveButton({
    super.key,
    required this.mode,
    required this.color,
    required this.audioLevels,
    required this.onTap,
    this.size = 104,
  });

  final VoiceWaveMode mode;
  final Color color;
  final ValueListenable<List<double>> audioLevels;
  final VoidCallback onTap;
  final double size;

  static const int barCount = 5;
  static const double _baseline = 0.16; // still-bar height as a fraction of max

  @override
  State<VoiceWaveButton> createState() => _VoiceWaveButtonState();
}

class _VoiceWaveButtonState extends State<VoiceWaveButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    );
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant VoiceWaveButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) _syncPulse();
  }

  /// Only spin the pulse controller when there's motion to show — keeps the idle
  /// kiosk truly still (and low-power).
  void _syncPulse() {
    if (widget.mode == VoiceWaveMode.off) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  /// Normalized [0..1] height for each of the five bars for the current frame.
  List<double> _bars(List<double> levels, double t) {
    const n = VoiceWaveButton.barCount;
    const base = VoiceWaveButton._baseline;

    switch (widget.mode) {
      case VoiceWaveMode.off:
        return List<double>.filled(n, base);

      case VoiceWaveMode.connecting:
        // Travelling sine — a calm "loading" ripple across the bars.
        return List<double>.generate(n, (i) {
          final phase = 2 * math.pi * (t + i / n);
          return base + 0.35 * (0.5 + 0.5 * math.sin(phase));
        });

      case VoiceWaveMode.active:
        if (levels.isNotEmpty) {
          // Ride the Pig's real amplitude. Fit/clamp the incoming bands to our
          // five bars.
          return List<double>.generate(n, (i) {
            final v = levels[i % levels.length].clamp(0.0, 1.0);
            return base + (1 - base) * v;
          });
        }
        // Connected but the Pig is silent (customer's turn): a low idle wave.
        return List<double>.generate(n, (i) {
          final phase = 2 * math.pi * (t + i / n);
          return base + 0.12 * (0.5 + 0.5 * math.sin(phase));
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.mode == VoiceWaveMode.off ? 'Tap to talk to Pig' : 'Tap to stop',
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: 0.12),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.25),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: SizedBox(
              width: widget.size * 0.52,
              height: widget.size * 0.42,
              child: ValueListenableBuilder<List<double>>(
                valueListenable: widget.audioLevels,
                builder: (context, levels, _) {
                  return AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, _) {
                      return CustomPaint(
                        painter: _WaveBarsPainter(
                          bars: _bars(levels, _pulse.value),
                          color: widget.color,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveBarsPainter extends CustomPainter {
  _WaveBarsPainter({required this.bars, required this.color});

  final List<double> bars;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final n = bars.length;
    if (n == 0) return;

    // Bars share the width evenly with a gap between them.
    const gapRatio = 0.55; // gap width relative to a bar's width
    final unit = size.width / (n + (n - 1) * gapRatio);
    final barWidth = unit;
    final gap = unit * gapRatio;
    final radius = Radius.circular(barWidth / 2);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    for (var i = 0; i < n; i++) {
      final h = (bars[i].clamp(0.0, 1.0)) * size.height;
      final left = i * (barWidth + gap);
      final top = (size.height - h) / 2; // vertically centered
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, h),
        radius,
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_WaveBarsPainter old) => old.bars != bars || old.color != color;
}
