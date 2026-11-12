import 'dart:async';
import 'dart:math' as math;

import 'package:audio_fx/audio_fx.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';

/// Asks for the microphone permission Android requires for its visualizer.
/// Returns true if granted.
Future<bool> requestVisualizerPermission(BuildContext context) async {
  final status = await Permission.microphone.request();
  if (status.isGranted) return true;
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Android needs the microphone permission to read the music for '
          'the visualizer. Nothing is recorded.',
        ),
        action: status.isPermanentlyDenied
            ? const SnackBarAction(
                label: 'Settings',
                onPressed: openAppSettings,
              )
            : null,
      ),
    );
  }
  return false;
}

/// Mirrored spectrum bars that move with the music.
///
/// The native visualizer sends ~20 frames a second; this widget eases
/// towards each frame at the display's refresh rate (fast rise, slower fall)
/// so the motion stays smooth.
class SpectrumVisualizer extends StatefulWidget {
  const SpectrumVisualizer({super.key, this.height = 64, this.bands = 40});

  final double height;
  final int bands;

  @override
  State<SpectrumVisualizer> createState() => _SpectrumVisualizerState();
}

class _SpectrumVisualizerState extends State<SpectrumVisualizer>
    with SingleTickerProviderStateMixin {
  late final MusicHandler _handler = context.read<MusicHandler>();
  late final Ticker _ticker = createTicker(_tick);
  late List<double> _target = List.filled(widget.bands, 0);
  late final ValueNotifier<List<double>> _levels = ValueNotifier(
    List.filled(widget.bands, 0),
  );
  StreamSubscription<List<double>>? _spectrum;
  StreamSubscription<bool>? _playing;
  StreamSubscription<int?>? _session;
  int? _sessionId;
  bool _isPlaying = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _playing = _handler.playbackState.map((s) => s.playing).distinct().listen((
      p,
    ) {
      _isPlaying = p;
      _update();
    });
    _session = _handler.audioSessionIdStream.listen((id) {
      if (id == _sessionId) return;
      _sessionId = id;
      _spectrum?.cancel();
      _spectrum = null;
      _update();
    });
  }

  /// Only capture while playing: the visualizer costs battery.
  void _update() {
    if (_isPlaying && !_ticker.isActive) _ticker.start();
    final id = _sessionId;
    if (_isPlaying && id != null && id != 0 && !_failed) {
      _spectrum ??= AudioFx.spectrum(id, bands: widget.bands).listen(
        (frame) => _target = frame,
        onError: (Object _) {
          _failed = true;
          _target = List.filled(widget.bands, 0);
        },
      );
    } else {
      _spectrum?.cancel();
      _spectrum = null;
      _target = List.filled(widget.bands, 0);
    }
  }

  void _tick(Duration _) {
    final current = _levels.value;
    var moving = false;
    final next = List<double>.generate(current.length, (i) {
      final target = i < _target.length ? _target[i] : 0.0;
      final c = current[i];
      final rate = target > c ? 0.45 : 0.12;
      final v = c + (target - c) * rate;
      if ((v - c).abs() > 0.001) moving = true;
      return v;
    });
    if (moving) {
      _levels.value = next;
    } else if (!_isPlaying) {
      _ticker.stop(); // bars have settled; stop drawing frames
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _spectrum?.cancel();
    _playing?.cancel();
    _session?.cancel();
    _levels.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          painter: _SpectrumPainter(
            levels: _levels,
            colors: [scheme.primary, scheme.tertiary],
          ),
        ),
      ),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({required this.levels, required this.colors})
    : super(repaint: levels);

  final ValueNotifier<List<double>> levels;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final values = levels.value;
    if (values.isEmpty) return;
    // Low frequencies in the middle, mirrored outwards.
    final count = values.length * 2;
    final slot = size.width / count;
    final barWidth = math.max(2.0, slot * 0.55);
    final mid = size.height / 2;
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [colors[1], colors[0], colors[1]],
      ).createShader(Offset.zero & size)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;

    for (var i = 0; i < values.length; i++) {
      final h = math.max(barWidth, values[i] * size.height * 0.95) / 2;
      for (final x in [
        size.width / 2 + (i + 0.5) * slot,
        size.width / 2 - (i + 0.5) * slot,
      ]) {
        canvas.drawLine(Offset(x, mid - h), Offset(x, mid + h), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter old) => old.colors != colors;
}
