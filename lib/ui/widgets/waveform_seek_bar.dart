import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import '../../services/waveforms.dart';
import 'track_tile.dart' show formatDuration;

/// The song's waveform, filled with the accent gradient up to the playback
/// position. Tap or drag to seek.
class WaveformSeekBar extends StatefulWidget {
  const WaveformSeekBar({
    super.key,
    required this.trackId,
    required this.path,
    required this.duration,
  });

  final String trackId;
  final String? path;
  final Duration duration;

  @override
  State<WaveformSeekBar> createState() => _WaveformSeekBarState();
}

class _WaveformSeekBarState extends State<WaveformSeekBar> {
  late List<double> _from;
  late List<double> _to;
  double? _dragFraction;

  @override
  void initState() {
    super.initState();
    _loadFor(widget.trackId, initial: true);
  }

  @override
  void didUpdateWidget(WaveformSeekBar old) {
    super.didUpdateWidget(old);
    if (old.trackId != widget.trackId) _loadFor(widget.trackId);
  }

  void _loadFor(String trackId, {bool initial = false}) {
    final cached = Waveforms.instance.cached(trackId);
    final placeholder = Waveforms.placeholder(trackId);
    _from = initial ? List.filled(waveformResolution, 0.05) : _to;
    _to = cached ?? placeholder;

    final path = widget.path;
    if (cached != null || path == null) return;
    Waveforms.instance.load(trackId, path).then((amps) {
      if (!mounted || amps == null || widget.trackId != trackId) return;
      setState(() {
        _from = _to;
        _to = amps;
      });
    });
  }

  double _fractionAt(Offset local, double width) =>
      (local.dx / width).clamp(0.0, 1.0);

  void _seekTo(double fraction) {
    context.read<MusicHandler>().seek(
      Duration(
        milliseconds: (widget.duration.inMilliseconds * fraction).round(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final handler = context.read<MusicHandler>();
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;
    final totalMs = widget.duration.inMilliseconds;

    return StreamBuilder<Duration>(
      stream: handler.positionStream,
      builder: (context, snapshot) {
        final posMs = snapshot.data?.inMilliseconds ?? 0;
        final fraction =
            _dragFraction ??
            (totalMs > 0 ? (posMs / totalMs).clamp(0.0, 1.0) : 0.0);

        return Column(
          children: [
            LayoutBuilder(
              builder: (context, c) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: totalMs > 0
                    ? (d) => _seekTo(_fractionAt(d.localPosition, c.maxWidth))
                    : null,
                onHorizontalDragUpdate: totalMs > 0
                    ? (d) => setState(
                        () => _dragFraction = _fractionAt(
                          d.localPosition,
                          c.maxWidth,
                        ),
                      )
                    : null,
                onHorizontalDragEnd: totalMs > 0
                    ? (_) {
                        if (_dragFraction != null) _seekTo(_dragFraction!);
                        setState(() => _dragFraction = null);
                      }
                    : null,
                child: TweenAnimationBuilder<double>(
                  // Re-keyed per target so each new shape animates in.
                  key: ValueKey(identityHashCode(_to)),
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) => CustomPaint(
                    size: Size(c.maxWidth, 64),
                    painter: _WaveformPainter(
                      from: _from,
                      to: _to,
                      t: t,
                      fraction: fraction,
                      played: [scheme.primary, scheme.tertiary],
                      unplayed: scheme.onSurface.withValues(alpha: 0.16),
                      dragging: _dragFraction != null,
                      cursor: scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  formatDuration(
                    Duration(milliseconds: (fraction * totalMs).round()),
                  ),
                  style: style,
                ),
                Text(formatDuration(widget.duration), style: style),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.from,
    required this.to,
    required this.t,
    required this.fraction,
    required this.played,
    required this.unplayed,
    required this.dragging,
    required this.cursor,
  });

  final List<double> from;
  final List<double> to;
  final double t;
  final double fraction;
  final List<Color> played;
  final Color unplayed;
  final bool dragging;
  final Color cursor;

  static const _barWidth = 3.0;
  static const _gap = 2.0;

  double _sample(List<double> amps, double pos) {
    final i = (pos * (amps.length - 1)).round();
    return amps[i.clamp(0, amps.length - 1)];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final count = (size.width / (_barWidth + _gap)).floor();
    if (count <= 0) return;
    final step = size.width / count;
    final mid = size.height / 2;

    final bars = Path();
    for (var i = 0; i < count; i++) {
      final pos = count == 1 ? 0.0 : i / (count - 1);
      final amp = ui.lerpDouble(_sample(from, pos), _sample(to, pos), t)!;
      final h = (amp * size.height).clamp(3.0, size.height);
      bars.addRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(i * step + step / 2, mid),
            width: _barWidth,
            height: h,
          ),
          const Radius.circular(_barWidth / 2),
        ),
      );
    }

    // Unplayed part, then the played part clipped up to the position.
    canvas.drawPath(bars, Paint()..color = unplayed);
    final playedWidth = size.width * fraction;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, playedWidth, size.height));
    canvas.drawPath(
      bars,
      Paint()
        ..shader = LinearGradient(
          colors: played,
        ).createShader(Offset.zero & size),
    );
    canvas.restore();

    if (dragging) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(playedWidth, mid),
            width: 2,
            height: size.height,
          ),
          const Radius.circular(1),
        ),
        Paint()..color = cursor,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.t != t ||
      old.fraction != fraction ||
      !identical(old.to, to) ||
      !identical(old.from, from) ||
      old.dragging != dragging ||
      old.played.first != played.first;
}
