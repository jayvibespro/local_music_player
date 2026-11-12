import 'dart:io';

import 'package:flutter/services.dart';

/// Audio effects on the player's Android audio session. See README.md.
abstract final class AudioFx {
  static const _methods = MethodChannel('audio_fx');
  static const _visualizer = EventChannel('audio_fx/visualizer');

  /// Whether the multi-band equalizer is available (Android 9+).
  static Future<bool> isEqualizerSupported() async {
    if (!Platform.isAndroid) return false;
    return await _methods.invokeMethod<bool>('isEqualizerSupported') ?? false;
  }

  /// Attaches the effects to [sessionId] with bands centred on
  /// [frequencies] (Hz). Call again whenever the session id changes.
  static Future<bool> attach(int sessionId, List<double> frequencies) async =>
      await _methods.invokeMethod<bool>('attach', {
        'sessionId': sessionId,
        'frequencies': frequencies,
      }) ??
      false;

  /// Band gains and preamp in dB.
  static Future<void> setEqualizer({
    required bool enabled,
    required List<double> gains,
    double preamp = 0,
  }) => _methods.invokeMethod('setEqualizer', {
    'enabled': enabled,
    'gains': gains,
    'preamp': preamp,
  });

  /// Volume-normalisation gain in dB (may be positive; a limiter prevents
  /// clipping).
  static Future<void> setLoudness(double gain) =>
      _methods.invokeMethod('setLoudness', {'gain': gain});

  /// Spectrum levels (0..1, low to high frequency), ~20 times a second.
  /// Needs the RECORD_AUDIO permission on Android.
  static Stream<List<double>> spectrum(int sessionId, {int bands = 48}) =>
      _visualizer
          .receiveBroadcastStream({'sessionId': sessionId, 'bands': bands})
          .map((e) => (e as List).cast<double>());
}
