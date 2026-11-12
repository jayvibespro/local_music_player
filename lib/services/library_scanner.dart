import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path/path.dart' as p;

import '../audio/loudness.dart';
import '../models/track.dart';
import 'text_repair.dart';

const audioExtensions = {
  '.mp3',
  '.m4a',
  '.aac',
  '.flac',
  '.wav',
  '.ogg',
  '.opus',
};

/// Bump when tag parsing changes so cached tracks are re-read on next scan.
const scannerVersion = 4; // 4: ReplayGain

/// Scans [folders] recursively off the UI isolate. Files whose modification
/// time matches an entry in [previous] are reused without re-reading tags.
Future<List<Track>> scanFolders({
  required List<String> folders,
  required List<Track> previous,
  required String artDir,
}) {
  final previousJson = [for (final t in previous) t.toJson()];
  return Isolate.run(() async {
    final known = {
      for (final json in previousJson)
        json['path'] as String: Track.fromJson(json),
    };
    final found = <String, Track>{};
    await Directory(artDir).create(recursive: true);

    for (final folder in folders) {
      final dir = Directory(folder);
      if (!await dir.exists()) continue;
      final entities = dir
          .list(recursive: true, followLinks: false)
          .handleError((Object _) {}); // skip unreadable sub-folders
      await for (final entity in entities) {
        if (entity is! File) continue;
        final path = entity.path;
        if (found.containsKey(path)) continue;
        // App-private data, never user music (and mostly unreadable anyway).
        if (path.contains('/Android/data/') || path.contains('/Android/obb/')) {
          continue;
        }
        if (!audioExtensions.contains(p.extension(path).toLowerCase())) {
          continue;
        }
        if (p.split(path).any((part) => part.startsWith('.'))) continue;

        try {
          final modifiedMs =
              (await entity.lastModified()).millisecondsSinceEpoch;
          final cached = known[path];
          if (cached != null && cached.modifiedMs == modifiedMs) {
            found[path] = cached;
          } else {
            found[path] = _readTrack(entity, modifiedMs, artDir);
          }
        } catch (_) {
          // Unreadable file; leave it out.
        }
      }
    }

    final tracks = found.values.toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return tracks;
  });
}

Track _readTrack(File file, int modifiedMs, String artDir) {
  AudioMetadata? meta;
  try {
    meta = readMetadata(file, getImage: true);
  } catch (_) {
    meta = null;
  }

  // Tags are repaired (mis-decoded text) and must be Latin script; anything
  // else falls back to what the file name says.
  final fromName = parseFileName(file.path);
  final albumArtist = repairTagText(meta?.albumArtist);
  final title = repairTagText(meta?.title) ?? fromName.title ?? 'Unknown title';
  final artist =
      repairTagText(meta?.artist) ??
      albumArtist ??
      fromName.artist ??
      Track.unknownArtist;
  final album = repairTagText(meta?.album) ?? Track.unknownAlbum;

  String? artPath;
  final image = (meta?.pictures ?? const [])
      .map((pic) => extractImage(pic.bytes))
      .nonNulls
      .firstOrNull;
  if (image != null) {
    // Share one image per album; tracks without an album get their own.
    final key = album == Track.unknownAlbum
        ? stableId(file.path)
        : stableId('${albumArtist ?? artist}|$album');
    final artFile = File(p.join(artDir, '$key${image.ext}'));
    if (!artFile.existsSync() || !_isValidImageFile(artFile)) {
      artFile.writeAsBytesSync(image.bytes);
    }
    artPath = artFile.path;
  }

  return Track(
    replayGainDb: _readReplayGain(file),
    id: stableId(file.path),
    path: file.path,
    title: title,
    artist: artist,
    album: album,
    durationMs: meta?.duration?.inMilliseconds ?? 0,
    modifiedMs: modifiedMs,
    trackNumber: meta?.trackNumber,
    artPath: artPath,
  );
}

/// Returns the image inside [bytes], or null if there is none.
///
/// Some tags carry junk before the image itself (e.g. a UTF-16 picture
/// description the tag reader failed to strip), which Android's decoder
/// rejects, so look for a known signature near the start and slice from there.
({Uint8List bytes, String ext})? extractImage(Uint8List bytes) {
  final limit = bytes.length < 4096 ? bytes.length : 4096;
  for (var i = 0; i < limit; i++) {
    final ext = _imageExtAt(bytes, i);
    if (ext != null) {
      return (
        bytes: i == 0 ? bytes : Uint8List.sublistView(bytes, i),
        ext: ext,
      );
    }
  }
  return null;
}

String? _imageExtAt(Uint8List b, int i) {
  bool match(List<int> sig) {
    if (i + sig.length > b.length) return false;
    for (var j = 0; j < sig.length; j++) {
      if (b[i + j] != sig[j]) return false;
    }
    return true;
  }

  if (match(const [0xff, 0xd8, 0xff])) return '.jpg';
  if (match(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return '.png';
  }
  if (match(const [0x52, 0x49, 0x46, 0x46]) &&
      i + 12 <= b.length &&
      String.fromCharCodes(b.sublist(i + 8, i + 12)) == 'WEBP') {
    return '.webp';
  }
  if (match(const [0x47, 0x49, 0x46, 0x38])) return '.gif';
  return null;
}

bool _isValidImageFile(File file) {
  try {
    final raf = file.openSync();
    try {
      final head = raf.readSync(12);
      return _imageExtAt(head, 0) != null;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return false;
  }
}

/// ReplayGain track gain (dB) from ID3 TXXX frames or Vorbis comments.
double? _readReplayGain(File file) {
  try {
    final tags = readAllMetadata(file, getImage: false);
    switch (tags) {
      case Mp3Metadata(:final customMetadata):
        for (final MapEntry(:key, :value) in customMetadata.entries) {
          if (key.toUpperCase() == 'REPLAYGAIN_TRACK_GAIN') {
            return parseReplayGain(value);
          }
        }
      case VorbisMetadata(:final replayGainTrackGain):
        return parseReplayGain(replayGainTrackGain.firstOrNull);
      default:
    }
  } catch (_) {}
  return null;
}
