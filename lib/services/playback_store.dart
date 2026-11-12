import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where the current queue came from, e.g. All songs or a playlist.
@immutable
class PlaybackSource {
  const PlaybackSource(this.id, this.title);

  /// A browse id (see `BrowseIds`), or another stable key such as 'search'.
  final String id;
  final String title;
}

/// Everything needed to resume playback after the app is closed.
class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.trackIds,
    required this.index,
    required this.position,
    required this.shuffle,
    required this.shuffleIndices,
    required this.loopMode,
    this.source,
  });

  /// Queue in play order (before shuffling).
  final List<String> trackIds;
  final int index;
  final Duration position;
  final bool shuffle;

  /// The exact shuffled order, so resuming doesn't reshuffle.
  final List<int> shuffleIndices;
  final LoopMode loopMode;
  final PlaybackSource? source;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'trackIds': trackIds,
    'index': index,
    'positionMs': position.inMilliseconds,
    'shuffle': shuffle,
    'shuffleIndices': shuffleIndices,
    'loopMode': loopMode.name,
    if (source != null) 'sourceId': source!.id,
    if (source != null) 'sourceTitle': source!.title,
  };

  factory PlaybackSnapshot.fromJson(Map<String, dynamic> json) {
    final sourceId = json['sourceId'] as String?;
    return PlaybackSnapshot(
      trackIds: (json['trackIds'] as List).cast<String>(),
      index: json['index'] as int? ?? 0,
      position: Duration(milliseconds: json['positionMs'] as int? ?? 0),
      shuffle: json['shuffle'] as bool? ?? false,
      shuffleIndices: (json['shuffleIndices'] as List? ?? []).cast<int>(),
      loopMode:
          LoopMode.values
              .where((m) => m.name == json['loopMode'])
              .firstOrNull ??
          LoopMode.off,
      source: sourceId == null
          ? null
          : PlaybackSource(sourceId, json['sourceTitle'] as String? ?? ''),
    );
  }
}

/// Reads and writes the [PlaybackSnapshot] to playback.json.
class PlaybackStore {
  File? _file;

  Future<File> _getFile() async => _file ??= File(
    p.join((await getApplicationSupportDirectory()).path, 'playback.json'),
  );

  Future<PlaybackSnapshot?> load() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) return null;
      return PlaybackSnapshot.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } catch (e) {
      debugPrint('Could not read saved playback: $e');
      return null;
    }
  }

  Future<void> save(PlaybackSnapshot snapshot) async {
    try {
      final file = await _getFile();
      // Write then rename, so a crash mid-write never leaves a broken file.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(snapshot.toJson()));
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('Could not save playback: $e');
    }
  }
}

/// A shuffle order that, the first time the player fills it, uses a saved
/// order instead of a random one. Later inserts behave normally.
class RestoredShuffleOrder extends DefaultShuffleOrder {
  RestoredShuffleOrder(this._saved);

  List<int>? _saved;

  @override
  void insert(int index, int count) {
    final saved = _saved;
    _saved = null;
    final valid =
        saved != null &&
        indices.isEmpty &&
        index == 0 &&
        saved.length == count &&
        saved.toSet().length == count &&
        saved.every((i) => i >= 0 && i < count);
    if (valid) {
      indices.addAll(saved);
    } else {
      super.insert(index, count);
    }
  }
}
