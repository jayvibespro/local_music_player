import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

@immutable
class LyricLine {
  const LyricLine(this.text, [this.time]);

  /// When the line starts; null for unsynced lyrics.
  final Duration? time;
  final String text;
}

@immutable
class Lyrics {
  const Lyrics(this.lines, {required this.source});

  final List<LyricLine> lines;

  /// Where they came from, e.g. "Song.lrc" or "embedded".
  final String source;

  bool get synced => lines.isNotEmpty && lines.first.time != null;

  /// Index of the line being sung at [position] (-1 before the first).
  int lineAt(Duration position) {
    if (!synced) return -1;
    var lo = 0, hi = lines.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time! <= position) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }
}

final _timeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
final _offsetTag = RegExp(r'^\[offset:\s*([+-]?\d+)\]', caseSensitive: false);
final _metaTag = RegExp(r'^\[[a-zA-Z#]+:.*\]$');

/// Parses LRC text. Lines without time tags make the result unsynced.
Lyrics? parseLyrics(String text, {required String source}) {
  final timed = <LyricLine>[];
  final plain = <LyricLine>[];
  var offset = Duration.zero;

  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    final off = _offsetTag.firstMatch(line);
    if (off != null) {
      // Positive offset = lyrics appear sooner.
      offset = Duration(milliseconds: -int.parse(off.group(1)!));
      continue;
    }
    final tags = _timeTag.allMatches(line).toList();
    if (tags.isEmpty) {
      if (_metaTag.hasMatch(line)) continue; // [ar:…], [ti:…]
      plain.add(LyricLine(line));
      continue;
    }
    final words = line.substring(tags.last.end).trim();
    for (final t in tags) {
      final fraction = t.group(3) ?? '0';
      final ms = int.parse(fraction.padRight(3, '0').substring(0, 3));
      final time = Duration(
        minutes: int.parse(t.group(1)!),
        seconds: int.parse(t.group(2)!),
        milliseconds: ms,
      );
      final shifted = time + offset;
      timed.add(LyricLine(words, shifted.isNegative ? Duration.zero : shifted));
    }
  }

  if (timed.isNotEmpty) {
    timed.sort((a, b) => a.time!.compareTo(b.time!));
    return Lyrics(timed, source: source);
  }
  // Trim blank lines at the ends of plain lyrics.
  while (plain.isNotEmpty && plain.first.text.isEmpty) {
    plain.removeAt(0);
  }
  while (plain.isNotEmpty && plain.last.text.isEmpty) {
    plain.removeLast();
  }
  return plain.isEmpty ? null : Lyrics(plain, source: source);
}

/// Finds lyrics for an audio file: a `.lrc` file with the same name next to
/// it, otherwise lyrics embedded in the file's tags.
class LyricsFinder {
  LyricsFinder._();
  static final instance = LyricsFinder._();

  final _cache = <String, Lyrics?>{};

  Future<Lyrics?> find(String audioPath) async {
    if (_cache.containsKey(audioPath)) return _cache[audioPath];
    final lyrics = await Isolate.run(() => _find(audioPath));
    return _cache[audioPath] = lyrics;
  }

  /// Forget cached results (e.g. after adding .lrc files).
  void clear() => _cache.clear();

  static Lyrics? _find(String audioPath) {
    final dir = Directory(p.dirname(audioPath));
    final base = p.basenameWithoutExtension(audioPath).toLowerCase();
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (p.extension(name).toLowerCase() == '.lrc' &&
            p.basenameWithoutExtension(name).toLowerCase() == base) {
          final lyrics = parseLyrics(_readText(entity), source: name);
          if (lyrics != null) return lyrics;
        }
      }
    } catch (_) {}
    try {
      final embedded = readMetadata(File(audioPath)).lyrics;
      if (embedded != null && embedded.trim().isNotEmpty) {
        return parseLyrics(embedded, source: 'embedded');
      }
    } catch (_) {}
    return null;
  }

  /// UTF-8, falling back to Latin-1 for older files.
  static String _readText(File f) {
    final bytes = f.readAsBytesSync();
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }
}
