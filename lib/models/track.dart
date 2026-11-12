import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:path/path.dart' as p;

/// Authority of `ArtworkProvider` (android/.../ArtworkProvider.kt), which
/// serves cached cover art to other apps such as Android Auto.
const artworkAuthority = 'com.jacksons.local_music_player.artwork';

/// Local file path of a media item's cover art, for the in-app UI.
///
/// On Android, [MediaItem.artUri] is a `content://` URI (so Android Auto and
/// the system media controls can read it), so the file path travels in extras.
String? artPathOf(MediaItem? item) => item?.extras?['artPath'] as String?;

/// URI handed to the media session for [artPath].
Uri? artUriFor(String? artPath) {
  if (artPath == null) return null;
  if (Platform.isAndroid) {
    return Uri(
      scheme: 'content',
      host: artworkAuthority,
      pathSegments: [p.basename(artPath)],
    );
  }
  return Uri.file(artPath);
}

/// Stable 64-bit FNV-1a hash, used to derive ids that survive app restarts
/// (unlike [String.hashCode]).
String stableId(String input) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return hash.toUnsigned(64).toRadixString(16);
}

class Track {
  const Track({
    required this.id,
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.modifiedMs,
    this.trackNumber,
    this.artPath,
    this.replayGainDb,
  });

  static const unknownArtist = 'Unknown artist';
  static const unknownAlbum = 'Unknown album';

  final String id;
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final int modifiedMs;
  final int? trackNumber;
  final String? artPath;

  /// ReplayGain track gain from the file's tags, in dB.
  final double? replayGainDb;

  Duration get duration => Duration(milliseconds: durationMs);

  factory Track.fromJson(Map<String, dynamic> json) => Track(
    id: json['id'] as String,
    path: json['path'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String,
    album: json['album'] as String,
    durationMs: json['durationMs'] as int? ?? 0,
    modifiedMs: json['modifiedMs'] as int? ?? 0,
    trackNumber: json['trackNumber'] as int?,
    artPath: json['artPath'] as String?,
    replayGainDb: (json['replayGainDb'] as num?)?.toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': durationMs,
    'modifiedMs': modifiedMs,
    'trackNumber': trackNumber,
    'artPath': artPath,
    'replayGainDb': replayGainDb,
  };

  /// [mediaId] defaults to the track id; browse trees prefix it with the
  /// parent so playback knows which list to queue.
  MediaItem toMediaItem({String? mediaId}) => MediaItem(
    id: mediaId ?? id,
    title: title,
    artist: artist,
    album: album,
    duration: durationMs > 0 ? duration : null,
    artUri: artUriFor(artPath),
    playable: true,
    extras: {'trackId': id, 'artPath': ?artPath},
  );
}
