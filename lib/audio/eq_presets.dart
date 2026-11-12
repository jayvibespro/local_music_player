import 'dart:math' as math;

/// An equalizer preset described as a frequency response curve, so it can be
/// applied to whatever bands the device's equalizer has (usually 5).
class EqPreset {
  const EqPreset(this.id, this.label, this.points);

  final String id;
  final String label;

  /// (frequency in Hz, gain in dB), ascending by frequency.
  final List<(double, double)> points;

  /// Gain in dB at [hz], interpolated on a log-frequency scale.
  double gainAt(double hz) {
    if (points.isEmpty) return 0;
    if (hz <= points.first.$1) return points.first.$2;
    if (hz >= points.last.$1) return points.last.$2;
    for (var i = 1; i < points.length; i++) {
      final (f1, g1) = points[i];
      if (hz <= f1) {
        final (f0, g0) = points[i - 1];
        final t = (math.log(hz) - math.log(f0)) / (math.log(f1) - math.log(f0));
        return g0 + (g1 - g0) * t;
      }
    }
    return points.last.$2;
  }

  static const custom = 'custom';

  static const all = [
    EqPreset('flat', 'Flat', [(20, 0), (20000, 0)]),
    EqPreset('bass', 'Bass boost', [
      (30, 6),
      (100, 5),
      (300, 2),
      (1000, 0),
      (20000, 0),
    ]),
    EqPreset('treble', 'Treble boost', [
      (30, 0),
      (1000, 0),
      (4000, 3),
      (14000, 6),
    ]),
    EqPreset('vocal', 'Vocal', [
      (30, -2),
      (200, -1),
      (1000, 3),
      (3000, 4),
      (8000, 1),
      (16000, 0),
    ]),
    EqPreset('drive', 'Driving', [
      // Lifts the lows and the presence range that road noise masks.
      (60, 4), (250, 1), (1000, 0), (3000, 3), (10000, 2),
    ]),
    EqPreset('rock', 'Rock', [
      (60, 4),
      (250, 2),
      (1000, -1),
      (4000, 3),
      (14000, 4),
    ]),
    EqPreset('pop', 'Pop', [
      (60, -1),
      (250, 2),
      (1000, 4),
      (4000, 2),
      (14000, -1),
    ]),
    EqPreset('hiphop', 'Hip-hop', [
      (60, 5),
      (250, 3),
      (1000, 0),
      (4000, 1),
      (14000, 2),
    ]),
    EqPreset('electronic', 'Electronic', [
      (60, 5),
      (250, 2),
      (1000, 0),
      (4000, 2),
      (14000, 4),
    ]),
    EqPreset('jazz', 'Jazz', [
      (60, 3),
      (250, 1),
      (1000, -1),
      (4000, 2),
      (14000, 3),
    ]),
    EqPreset('classical', 'Classical', [
      (60, 3),
      (250, 1),
      (1000, 0),
      (4000, 1),
      (14000, 3),
    ]),
  ];

  static EqPreset? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// "60 Hz", "1.2 kHz".
String formatHz(double hz) {
  if (hz < 1000) return '${hz.round()} Hz';
  final k = hz / 1000;
  return '${k >= 10 ? k.round() : k.toStringAsFixed(1).replaceAll('.0', '')} kHz';
}

/// Compact band label: "31", "500", "1k", "16k".
String formatHzShort(double hz) {
  if (hz < 1000) return '${hz.round()}';
  final k = hz / 1000;
  return '${k == k.roundToDouble() ? k.round() : k.toStringAsFixed(1)}k';
}
