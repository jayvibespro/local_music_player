import 'dart:math' as math;

import 'package:just_waveform/just_waveform.dart';

/// Target loudness for volume normalisation, in LUFS (the level most
/// streaming services use).
const targetLufs = -14.0;

/// ReplayGain 2 tags are relative to -18 LUFS.
const _replayGainReference = -18.0;

/// Gain (dB) that brings a track with ReplayGain [trackGainDb] to
/// [targetLufs].
double gainFromReplayGain(double trackGainDb) =>
    trackGainDb + (targetLufs - _replayGainReference);

/// Parses "-7.89 dB" / "+1.2 dB" / "-7.89".
double? parseReplayGain(String? value) {
  if (value == null) return null;
  final match = RegExp(r'[-+]?\d+(\.\d+)?').firstMatch(value);
  return match == null ? null : double.tryParse(match.group(0)!);
}

/// Rough loudness estimate (LUFS-like) from a waveform's peak envelope, for
/// songs without ReplayGain tags.
///
/// The waveform keeps only the min/max sample of each 50 ms slice, so this
/// is the RMS of those peaks, offset by a constant calibrated to land modern
/// masters near their real integrated loudness. Good enough to stop loud and
/// quiet songs being far apart; less precise than real tags.
double? estimateLufs(Waveform w) {
  if (w.length == 0) return null;
  final fullScale = (w.flags & 1) == 1 ? 128.0 : 32768.0;
  var sum = 0.0;
  var counted = 0;
  for (var i = 0; i < w.length; i++) {
    final peak =
        math.max(w.getPixelMax(i).abs(), w.getPixelMin(i).abs()) / fullScale;
    if (peak < 0.003) continue; // silence (gaps, fade-outs) shouldn't count
    sum += peak * peak;
    counted++;
  }
  if (counted == 0) return null;
  final envelopeDb = 10 * math.log(sum / counted) / math.ln10;
  return envelopeDb - 9;
}

/// Gain (dB) for a track measured at [lufs].
double gainFromLufs(double lufs) => targetLufs - lufs;

/// Keeps adjustments sensible: never boost by more than 6 dB.
double clampGain(double db) => db.clamp(-15.0, 6.0);
