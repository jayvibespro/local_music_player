import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Animated equaliser bars marking the current song. They bounce while
/// [playing] and settle to a still pattern when paused.
class PlayingIndicator extends StatefulWidget {
  const PlayingIndicator({
    super.key,
    required this.playing,
    this.size = 18,
    this.color,
  });

  final bool playing;
  final double size;
  final Color? color;

  @override
  State<PlayingIndicator> createState() => _PlayingIndicatorState();
}

class _PlayingIndicatorState extends State<PlayingIndicator>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _controller.repeat();
  }

  @override
  void didUpdateWidget(PlayingIndicator old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.playing && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _BarsPainter(
            t: _controller.value,
            playing: widget.playing,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({required this.t, required this.playing, required this.color});

  final double t;
  final bool playing;
  final Color color;

  static const _phases = [0.0, 0.55, 0.25, 0.8];
  static const _speeds = [1.0, 2.0, 1.0, 2.0];
  static const _rest = [0.45, 0.8, 0.6, 0.35];

  @override
  void paint(Canvas canvas, Size size) {
    const count = 4;
    final slot = size.width / count;
    final barWidth = slot * 0.62;
    final paint = Paint()..color = color;
    for (var i = 0; i < count; i++) {
      final level = playing
          ? 0.25 +
                0.75 *
                    (0.5 +
                        0.5 *
                            math.sin(
                              2 * math.pi * (t * _speeds[i] + _phases[i]),
                            ))
          : _rest[i];
      final h = size.height * level;
      final x = i * slot + (slot - barWidth) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - h, barWidth, h),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.t != t || old.playing != playing || old.color != color;
}
