import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/track.dart';

/// A playlist on Audius.
class AudiusPlaylist {
  const AudiusPlaylist({
    required this.id,
    required this.name,
    required this.owner,
    required this.trackCount,
    this.artUrl,
  });

  final String id;
  final String name;
  final String owner;
  final int trackCount;
  final String? artUrl;
}

class AudiusException implements Exception {
  const AudiusException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Client for Audius (https://audius.co), a free catalogue of full-length
/// songs uploaded by artists. Needs no API key.
abstract final class Audius {
  static const _host = 'api.audius.co';
  static const _appName = 'music_player';

  /// Prefix of [Track.id] for Audius songs.
  static const idPrefix = 'audius:';

  /// Genre filters offered on Discover, as Audius names them.
  static const genres = [
    'Electronic',
    'Hip-Hop/Rap',
    'Pop',
    'Lo-Fi',
    'R&B/Soul',
    'Rock',
    'Alternative',
    'Ambient',
    'House',
    'Jazz',
    'Acoustic',
    'Latin',
  ];

  static final _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  static Future<dynamic> _get(
    String path, [
    Map<String, String> query = const {},
  ]) async {
    final uri = Uri.https(_host, '/v1$path', {...query, 'app_name': _appName});
    try {
      final request = await _http.getUrl(uri);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw AudiusException('Audius returned ${response.statusCode}');
      }
      return (jsonDecode(body) as Map<String, dynamic>)['data'];
    } on AudiusException {
      rethrow;
    } on SocketException {
      throw const AudiusException('No internet connection');
    } on TimeoutException {
      throw const AudiusException('Audius took too long to answer');
    } on HttpException catch (e) {
      throw AudiusException(e.message);
    }
  }

  static List<Track> _tracks(dynamic data) => [
    for (final j in data as List) ?trackFromJson(j as Map<String, dynamic>),
  ];

  static Future<List<Track>> search(String query) async =>
      _tracks(await _get('/tracks/search', {'query': query, 'limit': '40'}));

  /// Most played this [time] ('week', 'month', 'year' or 'allTime').
  static Future<List<Track>> trending({
    String? genre,
    String time = 'week',
  }) async =>
      _tracks(await _get('/tracks/trending', {'time': time, 'genre': ?genre}));

  static Future<List<AudiusPlaylist>> trendingPlaylists() async {
    final data = await _get('/playlists/trending', {'time': 'week'}) as List;
    return [
      for (final j in data.cast<Map<String, dynamic>>())
        AudiusPlaylist(
          id: j['id'] as String,
          name: (j['playlist_name'] as String? ?? '').trim(),
          owner: (j['user'] as Map?)?['name'] as String? ?? '',
          trackCount: j['track_count'] as int? ?? 0,
          artUrl: (j['artwork'] as Map?)?['480x480'] as String?,
        ),
    ];
  }

  static Future<List<Track>> playlistTracks(String playlistId) async =>
      _tracks(await _get('/playlists/$playlistId/tracks'));

  /// Converts an Audius track, or returns null if it can't be streamed
  /// (e.g. pay-gated or removed).
  @visibleForTesting
  static Track? trackFromJson(Map<String, dynamic> j) {
    final id = j['id'] as String?;
    if (id == null || j['is_streamable'] != true) return null;
    if (j['is_delete'] == true || j['is_stream_gated'] == true) return null;
    final user = j['user'] as Map<String, dynamic>?;
    final album = (j['album_backlink'] as Map?)?['playlist_name'] as String?;
    return Track(
      id: '$idPrefix$id',
      // Redirects to a freshly signed audio URL on every request, so the
      // saved queue keeps working after the signature expires.
      path: Uri.https(_host, '/v1/tracks/$id/stream', {
        'app_name': _appName,
      }).toString(),
      title: (j['title'] as String? ?? '').trim(),
      artist: (user?['name'] as String?)?.trim() ?? Track.unknownArtist,
      album: album?.trim() ?? 'Audius',
      durationMs: ((j['duration'] as num?) ?? 0).toInt() * 1000,
      modifiedMs: 0,
      artUrl: (j['artwork'] as Map?)?['480x480'] as String?,
    );
  }
}

/// Online songs the user has played or queued, remembered so history,
/// stats and the saved queue still know them after a restart. Their cover
/// art is downloaded next to the local songs' art, so the rest of the app
/// (theme colours, Android Auto, the notification) treats it the same.
class OnlineTracks {
  /// Remembers at most this many songs, dropping the least recent.
  static const _limit = 500;

  final _byId = <String, Track>{}; // insertion-ordered: oldest first
  final _artLoaded = StreamController<Track>.broadcast();
  final _fetching = <String>{};
  Directory? _artDir;
  File? _file;
  Timer? _saveDebounce;

  /// Emits a song again once its cover art has been downloaded.
  Stream<Track> get artLoaded => _artLoaded.stream;

  Track? byId(String id) => _byId[id];

  Future<void> load(Directory dataDir) async {
    _artDir = Directory(p.join(dataDir.path, 'artwork'));
    _file = File(p.join(dataDir.path, 'online_tracks.json'));
    try {
      if (await _file!.exists()) {
        final list = jsonDecode(await _file!.readAsString()) as List;
        for (final j in list) {
          final t = Track.fromJson(j as Map<String, dynamic>);
          _byId[t.id] = t;
        }
      }
    } catch (e) {
      debugPrint('Could not read online songs: $e');
    }
  }

  /// Remembers the online songs among [tracks] and returns [tracks] with
  /// any cover art already downloaded filled in. Missing art is fetched in
  /// the background (see [artLoaded]). Local songs pass through unchanged.
  List<Track> remember(List<Track> tracks) {
    if (!tracks.any((t) => t.isOnline)) return tracks;
    final out = [
      for (final t in tracks)
        if (!t.isOnline) t else _remember(t),
    ];
    while (_byId.length > _limit) {
      _byId.remove(_byId.keys.first);
    }
    _scheduleSave();
    return out;
  }

  Track _remember(Track t) {
    final known = _byId.remove(t.id);
    var track = t.artPath == null && known?.artPath != null
        ? t.copyWith(artPath: known!.artPath)
        : t;
    if (track.artPath == null) {
      final file = _artFile(track);
      if (file != null && file.existsSync()) {
        track = track.copyWith(artPath: file.path);
      } else {
        _fetchArt(track);
      }
    }
    _byId[track.id] = track; // (re)inserted last = most recent
    return track;
  }

  File? _artFile(Track t) {
    final dir = _artDir;
    if (dir == null || t.artUrl == null) return null;
    final name = t.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File(p.join(dir.path, '$name.jpg'));
  }

  Future<void> _fetchArt(Track t) async {
    final file = _artFile(t);
    if (file == null || !_fetching.add(t.id)) return;
    try {
      final request = await Audius._http.getUrl(Uri.parse(t.artUrl!));
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) return;
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.part');
      await response.pipe(tmp.openWrite());
      await tmp.rename(file.path);
      final updated = (_byId[t.id] ?? t).copyWith(artPath: file.path);
      _byId[t.id] = updated;
      _scheduleSave();
      _artLoaded.add(updated);
    } catch (e) {
      debugPrint('Cover art download failed for ${t.id}: $e');
    } finally {
      _fetching.remove(t.id);
    }
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 1), () async {
      try {
        await _file?.writeAsString(
          jsonEncode([for (final t in _byId.values) t.toJson()]),
        );
      } catch (e) {
        debugPrint('Could not save online songs: $e');
      }
    });
  }
}
