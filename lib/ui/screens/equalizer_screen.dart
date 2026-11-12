import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../audio/eq_presets.dart';
import '../../audio/equalizer.dart';
import '../../audio/music_handler.dart';
import '../../services/settings.dart';

class EqualizerScreen extends StatefulWidget {
  const EqualizerScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const EqualizerScreen());

  @override
  State<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<EqualizerScreen> {
  late final MusicHandler _handler = context.read<MusicHandler>();
  late final Future<(EqLayout, List<double>)>? _initial = _handler.eq.available
      ? _handler.eq.layout.then(
          (layout) async => (layout, await _handler.savedEqGains()),
        )
      : null;

  /// Live values, saved to settings when a slider is released.
  List<double>? _gains;
  double? _preamp;

  Future<void> _applyPreset(EqPreset preset, EqLayout layout) async {
    final gains = MusicHandler.gainsForPreset(preset, layout);
    setState(() {
      _gains = gains;
      _preamp = 0;
    });
    await context.read<Settings>().update((s) {
      s.eqPreset = preset.id;
      s.eqGains = gains;
      s.eqPreamp = 0;
      // Picking a preset implies wanting to hear it.
      s.eqEnabled = true;
    });
  }

  void _preview() => _handler.previewEqualizer([..._gains!], _preamp!);

  void _save() {
    final gains = [..._gains!];
    final preamp = _preamp!;
    context.read<Settings>().update((s) {
      s.eqGains = gains;
      s.eqPreamp = preamp;
      s.eqPreset = EqPreset.custom;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Equalizer'),
        actions: [
          if (_initial != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Switch(
                value: settings.eqEnabled,
                onChanged: (v) => settings.update((s) => s.eqEnabled = v),
              ),
            ),
        ],
      ),
      body: _initial == null
          ? const _Message(
              icon: Icons.equalizer_rounded,
              text: 'The equalizer is available on Android.',
            )
          : FutureBuilder<(EqLayout, List<double>)>(
              future: _initial,
              builder: (context, snapshot) {
                final data = snapshot.data;
                if (data == null) {
                  return const _Message(
                    icon: Icons.play_circle_outline_rounded,
                    text: 'Play a song to load the equalizer.',
                  );
                }
                final (layout, saved) = data;
                _gains ??= saved;
                _preamp ??= settings.eqPreamp;
                return _body(layout, settings);
              },
            ),
    );
  }

  Widget _body(EqLayout layout, Settings settings) {
    final gains = _gains!;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final enabled = settings.eqEnabled;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
      children: [
        AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          opacity: enabled ? 1 : 0.4,
          child: Column(
            children: [
              SizedBox(
                height: 110,
                child: TweenAnimationBuilder<List<double>>(
                  tween: _ListTween(end: gains),
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  builder: (context, animated, _) => CustomPaint(
                    size: Size.infinite,
                    painter: _ResponseCurvePainter(
                      gains: animated,
                      min: layout.minDb,
                      max: layout.maxDb,
                      color: scheme.primary,
                      gridColor: scheme.onSurface.withValues(alpha: 0.12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 260,
                child: Row(
                  children: [
                    for (var i = 0; i < layout.frequencies.length; i++)
                      Expanded(
                        child: _BandSlider(
                          label: formatHzShort(layout.frequencies[i]),
                          value: gains[i],
                          min: layout.minDb,
                          max: layout.maxDb,
                          onChanged: (v) {
                            setState(() => gains[i] = v);
                            _preview();
                          },
                          onChangeEnd: (_) => _save(),
                        ),
                      ),
                  ],
                ),
              ),
              Text('Hz', style: textTheme.labelSmall),
              if (layout.hasPreamp) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const SizedBox(width: 8),
                    Text('Preamp', style: textTheme.bodyMedium),
                    Expanded(
                      child: Slider(
                        value: _preamp!,
                        min: -12,
                        max: 12,
                        divisions: 48,
                        label:
                            '${_preamp! > 0 ? '+' : ''}'
                            '${_preamp!.toStringAsFixed(1)} dB',
                        onChanged: (v) {
                          setState(() => _preamp = v);
                          _preview();
                        },
                        onChangeEnd: (_) => _save(),
                      ),
                    ),
                    SizedBox(
                      width: 64,
                      child: Text(
                        '${_preamp! > 0 ? '+' : ''}'
                        '${_preamp!.toStringAsFixed(1)} dB',
                        textAlign: TextAlign.end,
                        style: textTheme.labelMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (!enabled)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'The equalizer is off. Turn it on to hear your changes.',
              textAlign: TextAlign.center,
              style: textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('Presets', style: textTheme.titleSmall),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in EqPreset.all)
              ChoiceChip(
                label: Text(preset.label),
                selected: settings.eqPreset == preset.id,
                onSelected: (_) => _applyPreset(preset, layout),
              ),
            if (settings.eqPreset == EqPreset.custom)
              const ChoiceChip(
                label: Text('Custom'),
                selected: true,
                onSelected: null,
              ),
          ],
        ),
        if (!layout.hasPreamp)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              'This phone\'s built-in equalizer has '
              '${layout.frequencies.length} bands. Android 9 or newer gets '
              '10 bands and a preamp.',
              style: textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _BandSlider extends StatelessWidget {
  const _BandSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final db = value.abs() < 0.05 ? '0' : value.toStringAsFixed(1);
    return Column(
      children: [
        Text(
          '${value > 0.05 ? '+' : ''}$db',
          maxLines: 1,
          style: textTheme.labelSmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(trackHeight: 6),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ),
        ),
        Text(label, style: textTheme.labelSmall),
      ],
    );
  }
}

/// A smooth curve through the band gains, with a 0 dB line.
class _ResponseCurvePainter extends CustomPainter {
  _ResponseCurvePainter({
    required this.gains,
    required this.min,
    required this.max,
    required this.color,
    required this.gridColor,
  });

  final List<double> gains;
  final double min;
  final double max;
  final Color color;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (gains.isEmpty) return;
    double y(double db) => size.height - (db - min) / (max - min) * size.height;
    final step = size.width / gains.length;
    // Points sit over each band's slider column.
    final points = [
      Offset(0, y(gains.first)),
      for (var i = 0; i < gains.length; i++)
        Offset(step * (i + 0.5), y(gains[i])),
      Offset(size.width, y(gains.last)),
    ];

    final zero = y(0);
    canvas.drawLine(
      Offset(0, zero),
      Offset(size.width, zero),
      Paint()
        ..color = gridColor
        ..strokeWidth = 1,
    );

    // Catmull-Rom spline through the points.
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[i == 0 ? 0 : i - 1];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = points[i + 2 < points.length ? i + 2 : i + 1];
      path.cubicTo(
        p1.dx + (p2.dx - p0.dx) / 6,
        p1.dy + (p2.dy - p0.dy) / 6,
        p2.dx - (p3.dx - p1.dx) / 6,
        p2.dy - (p3.dy - p1.dy) / 6,
        p2.dx,
        p2.dy,
      );
    }

    final fill = Path.from(path)
      ..lineTo(size.width, zero)
      ..lineTo(0, zero)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.35),
            color.withValues(alpha: 0.05),
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    for (final p in points.skip(1).take(gains.length)) {
      canvas.drawCircle(p, 4, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_ResponseCurvePainter old) =>
      old.gains != gains || old.color != color || old.gridColor != gridColor;
}

/// Animates between two equal-length lists of gains.
class _ListTween extends Tween<List<double>> {
  _ListTween({required List<double> end}) : super(end: [...end]);

  @override
  List<double> lerp(double t) {
    final a = begin ?? end!;
    final b = end!;
    if (a.length != b.length) return b;
    return [for (var i = 0; i < b.length; i++) a[i] + (b[i] - a[i]) * t];
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
