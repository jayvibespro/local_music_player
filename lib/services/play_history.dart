import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One counted play.
typedef PlayEvent = ({String trackId, DateTime at});

/// What the user has listened to: play counts, recent plays, a timestamped
/// log of plays and listening time per day. Powers "Recently played",
/// "Most played", the driving mix and listening stats.
class PlayHistory extends ChangeNotifier {
  PlayHistory({File? file}) : _fileOverride = file;

  static const maxRecent = 100;
  static const maxEvents = 20000;

  final File? _fileOverride;
  File? _file;
  final _counts = <String, int>{};
  final _recent = <String>[]; // most recent first, no duplicates
  final _events = <PlayEvent>[]; // oldest first
  final _dailyMs = <String, int>{}; // 'yyyy-mm-dd' -> ms listened
  final _loaded = Completer<void>();
  Timer? _saveDebounce;

  Future<void> get ready => _loaded.future;

  Future<void> load() async {
    try {
      _file =
          _fileOverride ??
          File(
            p.join(
              (await getApplicationSupportDirectory()).path,
              'history.json',
            ),
          );
      if (await _file!.exists()) {
        final json =
            jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        _counts.addAll((json['counts'] as Map).cast<String, int>());
        _recent.addAll((json['recent'] as List).cast<String>());
        for (final e in json['events'] as List? ?? const []) {
          final [id as String, at as int] = e as List;
          _events.add((
            trackId: id,
            at: DateTime.fromMillisecondsSinceEpoch(at),
          ));
        }
        _dailyMs.addAll((json['daily'] as Map? ?? const {}).cast());
      }
    } catch (e) {
      debugPrint('Failed to load play history: $e');
    } finally {
      if (!_loaded.isCompleted) _loaded.complete();
      notifyListeners();
    }
  }

  /// Counts one play of [trackId].
  void record(String trackId, {DateTime? at}) {
    _counts[trackId] = (_counts[trackId] ?? 0) + 1;
    _recent
      ..remove(trackId)
      ..insert(0, trackId);
    if (_recent.length > maxRecent) {
      _recent.removeRange(maxRecent, _recent.length);
    }
    _events.add((trackId: trackId, at: at ?? DateTime.now()));
    if (_events.length > maxEvents) {
      _events.removeRange(0, _events.length - maxEvents);
    }
    _changed();
  }

  /// Adds time spent listening on [at]'s day (today by default).
  void addListening(Duration d, {DateTime? at}) {
    final key = dayKey(at ?? DateTime.now());
    _dailyMs[key] = (_dailyMs[key] ?? 0) + d.inMilliseconds;
    _scheduleSave();
  }

  int playCount(String trackId) => _counts[trackId] ?? 0;

  /// Most recently played first.
  List<String> get recent => List.unmodifiable(_recent);

  /// Most played first (ties: most recently played first).
  List<String> mostPlayed([int limit = 50]) {
    final recency = {for (var i = 0; i < _recent.length; i++) _recent[i]: i};
    final ids = _counts.keys.toList()
      ..sort((a, b) {
        final c = _counts[b]!.compareTo(_counts[a]!);
        if (c != 0) return c;
        return (recency[a] ?? maxRecent).compareTo(recency[b] ?? maxRecent);
      });
    return ids.take(limit).toList();
  }

  /// Plays since [since] (all when null), oldest first.
  Iterable<PlayEvent> playsSince(DateTime? since) =>
      since == null ? _events : _events.where((e) => !e.at.isBefore(since));

  /// Listening time per day from [since] (inclusive) to today.
  Map<DateTime, Duration> dailyListening(DateTime since) {
    final start = DateTime(since.year, since.month, since.day);
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day);
    return {
      for (
        var d = start;
        !d.isAfter(end);
        d = DateTime(d.year, d.month, d.day + 1)
      )
        d: Duration(milliseconds: _dailyMs[dayKey(d)] ?? 0),
    };
  }

  /// Total listening time since [since] (all time when null).
  Duration listeningSince(DateTime? since) {
    final from = since == null ? null : dayKey(since);
    var ms = 0;
    _dailyMs.forEach((day, v) {
      if (from == null || day.compareTo(from) >= 0) ms += v;
    });
    return Duration(milliseconds: ms);
  }

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Drops a deleted song.
  void forget(String trackId) {
    final hadCount = _counts.remove(trackId) != null;
    final wasRecent = _recent.remove(trackId);
    final before = _events.length;
    _events.removeWhere((e) => e.trackId == trackId);
    if (hadCount || wasRecent || before != _events.length) _changed();
  }

  void _changed() {
    notifyListeners();
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), save);
  }

  Future<void> save() async {
    _saveDebounce?.cancel();
    final file = _file;
    if (file == null) return;
    try {
      await file.writeAsString(
        jsonEncode({
          'counts': _counts,
          'recent': _recent,
          'events': [
            for (final e in _events) [e.trackId, e.at.millisecondsSinceEpoch],
          ],
          'daily': _dailyMs,
        }),
      );
    } catch (e) {
      debugPrint('Failed to save play history: $e');
    }
  }
}
