import 'dart:async';
import 'dart:io';

import 'package:audio_fx/audio_fx.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// The bands a device's equalizer offers.
@immutable
class EqLayout {
  const EqLayout({
    required this.frequencies,
    required this.minDb,
    required this.maxDb,
    required this.hasPreamp,
  });

  /// Band centres in Hz, low to high.
  final List<double> frequencies;
  final double minDb;
  final double maxDb;
  final bool hasPreamp;
}

/// One front for two equalizers:
///  - Android 9+: a 10-band graphic EQ with preamp and a limiter
///    (DynamicsProcessing, via the local `audio_fx` plugin), which also
///    applies volume normalisation;
///  - older Android: the platform's built-in equalizer (usually 5 bands).
class EqualizerEngine {
  EqualizerEngine() : legacy = Platform.isAndroid ? AndroidEqualizer() : null;

  /// ISO octave bands.
  static const tenBands = <double>[
    31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000, //
  ];

  /// Fallback equalizer; must be part of the player's pipeline from the
  /// start, and simply stays disabled when the 10-band one is in use.
  final AndroidEqualizer? legacy;

  bool get available => legacy != null;

  late final Future<bool> multiBand = AudioFx.isEqualizerSupported().catchError(
    (Object _) => false,
  );

  final _layout = Completer<EqLayout>();

  /// Resolves once known (the fallback needs a song to have loaded).
  Future<EqLayout> get layout => _layout.future;

  int? _session;
  bool _enabled = false;
  List<double> _gains = const [];
  double _preamp = 0;
  double _loudness = 0;

  Future<void> init() async {
    if (!available) return;
    try {
      if (await multiBand) {
        _layout.complete(
          const EqLayout(
            frequencies: tenBands,
            minDb: -12,
            maxDb: 12,
            hasPreamp: true,
          ),
        );
      } else {
        final p = await legacy!.parameters;
        _layout.complete(
          EqLayout(
            frequencies: [for (final b in p.bands) b.centerFrequency],
            minDb: p.minDecibels,
            maxDb: p.maxDecibels,
            hasPreamp: false,
          ),
        );
      }
    } catch (e) {
      debugPrint('Equalizer unavailable: $e');
    }
  }

  /// The player's audio session; effects are re-attached when it changes.
  Future<void> attachSession(int? sessionId) async {
    if (sessionId == null || sessionId == 0 || sessionId == _session) return;
    if (!await multiBand) return;
    _session = sessionId;
    try {
      await AudioFx.attach(sessionId, tenBands);
      await _push();
    } catch (e) {
      debugPrint('Failed to attach equalizer: $e');
    }
  }

  Future<void> apply({
    required bool enabled,
    required List<double> gains,
    double preamp = 0,
  }) async {
    _enabled = enabled;
    _gains = gains;
    _preamp = preamp;
    if (!available) return;
    if (await multiBand) return _push();

    final eq = legacy!;
    await eq.setEnabled(enabled);
    final params = await eq.parameters;
    for (final band in params.bands) {
      final gain = band.index < gains.length ? gains[band.index] : 0.0;
      await band.setGain(gain.clamp(params.minDecibels, params.maxDecibels));
    }
  }

  /// Normalisation gain in dB. Returns false when this device can't apply it
  /// natively (then the caller lowers the player volume instead).
  Future<bool> setLoudness(double db) async {
    if (!available || !await multiBand) return false;
    _loudness = db;
    await _push();
    return true;
  }

  Future<void> _push() async {
    if (_session == null) return;
    try {
      await AudioFx.setEqualizer(
        enabled: _enabled,
        gains: _gains,
        preamp: _preamp,
      );
      await AudioFx.setLoudness(_loudness);
    } catch (e) {
      debugPrint('Equalizer update failed: $e');
    }
  }
}
