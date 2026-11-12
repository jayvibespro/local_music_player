import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_waveform/just_waveform.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../audio/loudness.dart';

/// Number of amplitude points kept per song; the painter resamples to fit.
const waveformResolution = 240;

/// Extracts and caches per-song waveforms as [waveformResolution] amplitudes
/// in 0..1. Decoding happens natively (MediaCodec) and is written to disk, so
/// each song is only processed once.
class Waveforms {
  Waveforms._();
  static final instance = Waveforms._();

  final _memory = <String, List<double>>{};
  final _pending = <String, Future<List<double>?>>{};
  Directory? _dir;

  List<double>? cached(String trackId) => _memory[trackId];

  // Loudness estimates (LUFS-like) measured from the waveforms, for volume
  // normalisation of songs without ReplayGain tags.
  Map<String, double>? _loudness;
  Timer? _loudnessSave;

  Future<Directory> _directory() async => _dir ??= await Directory(
    p.join((await getApplicationSupportDirectory()).path, 'waveforms'),
  ).create(recursive: true);

  Future<File> get _loudnessFile async =>
      File(p.join((await _directory()).path, 'loudness.json'));

  Future<Map<String, double>> _loudnessMap() async {
    if (_loudness != null) return _loudness!;
    final map = <String, double>{};
    try {
      final file = await _loudnessFile;
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString()) as Map;
        json.forEach((k, v) => map[k as String] = (v as num).toDouble());
      }
    } catch (_) {}
    return _loudness ??= map;
  }

  /// Measured loudness of [trackId], if its waveform has been analysed.
  Future<double?> loudness(String trackId) async =>
      (await _loudnessMap())[trackId];

  Future<void> _recordLoudness(String trackId, Waveform w) async {
    final lufs = estimateLufs(w);
    if (lufs == null) return;
    final map = await _loudnessMap();
    if (map[trackId] == lufs) return;
    map[trackId] = lufs;
    _loudnessSave?.cancel();
    _loudnessSave = Timer(const Duration(seconds: 3), () async {
      try {
        await (await _loudnessFile).writeAsString(jsonEncode(map));
      } catch (_) {}
    });
  }

  Future<List<double>?> load(String trackId, String audioPath) {
    final hit = _memory[trackId];
    if (hit != null) return SynchronousFuture(hit);
    return _pending[trackId] ??= _load(
      trackId,
      audioPath,
    ).whenComplete(() => _pending.remove(trackId));
  }

  Future<List<double>?> _load(String trackId, String audioPath) async {
    try {
      final waveFile = File(p.join((await _directory()).path, '$trackId.wave'));

      Waveform? waveform;
      if (await waveFile.exists()) {
        try {
          waveform = await JustWaveform.parse(waveFile);
        } catch (_) {
          await waveFile.delete(); // corrupt; extract again
        }
      }
      waveform ??=
          await JustWaveform.extract(
                audioInFile: File(audioPath),
                waveOutFile: waveFile,
                zoom: const WaveformZoom.pixelsPerSecond(20),
              )
              .firstWhere((progress) => progress.waveform != null)
              .timeout(const Duration(minutes: 2))
              .then((progress) => progress.waveform!);

      await _recordLoudness(trackId, waveform!);
      final amps = _downsample(waveform);
      _memory[trackId] = amps;
      return amps;
    } catch (e) {
      debugPrint('Waveform extraction failed for $audioPath: $e');
      return null;
    }
  }

  /// Reduces [w] to [waveformResolution] bar heights in 0..1.
  ///
  /// Uses each bar's *average* peak level, then stretches the range between
  /// the 10th and 99th percentile. Taking the maximum instead (or scaling by
  /// the loudest point) makes modern, heavily compressed masters render as
  /// a solid block of full-height bars.
  static List<double> _downsample(Waveform w) {
    final pixels = w.length;
    if (pixels == 0) return List.filled(waveformResolution, 0.12);
    final levels = List<double>.filled(waveformResolution, 0);
    for (var i = 0; i < waveformResolution; i++) {
      final start = i * pixels ~/ waveformResolution;
      final end = math.max(start + 1, (i + 1) * pixels ~/ waveformResolution);
      var sum = 0;
      for (var px = start; px < end; px++) {
        sum += math.max(w.getPixelMax(px).abs(), w.getPixelMin(px).abs());
      }
      levels[i] = sum / (end - start);
    }

    final sorted = [...levels]..sort();
    final lo = sorted[(waveformResolution * 0.10).floor()];
    final hi = sorted[(waveformResolution * 0.99).floor()];
    if (hi <= lo) return List.filled(waveformResolution, 0.5);
    return [
      for (final v in levels)
        0.12 +
            0.88 *
                math
                    .pow(((v - lo) / (hi - lo)).clamp(0.0, 1.0), 1.2)
                    .toDouble(),
    ];
  }

  /// Stand-in shape shown while the real waveform loads (or if it fails):
  /// smooth, deterministic per song.
  static List<double> placeholder(String trackId) {
    final rnd = math.Random(trackId.hashCode);
    var v = 0.5;
    return List.generate(waveformResolution, (i) {
      v = (v + (rnd.nextDouble() - 0.5) * 0.35).clamp(0.2, 0.9);
      return v;
    });
  }
}
