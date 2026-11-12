import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_music_player/models/track.dart';
import 'package:local_music_player/services/library_scanner.dart';
import 'package:local_music_player/services/settings.dart';
import 'package:local_music_player/services/text_repair.dart';

/// Minimal MP3: an ID3v2.3 tag with the given text frames followed by a few
/// silent MPEG frames.
Uint8List buildMp3(Map<String, List<int>> frames) {
  final body = BytesBuilder();
  frames.forEach((id, data) {
    body
      ..add(id.codeUnits)
      ..add([
        data.length >> 24 & 0xff,
        data.length >> 16 & 0xff,
        data.length >> 8 & 0xff,
        data.length & 0xff,
      ])
      ..add([0, 0])
      ..add(data);
  });
  final tag = body.toBytes();
  final size = tag.length;
  final out = BytesBuilder()
    ..add('ID3'.codeUnits)
    ..add([3, 0, 0])
    ..add([size >> 21 & 0x7f, size >> 14 & 0x7f, size >> 7 & 0x7f, size & 0x7f])
    ..add(tag);
  for (var i = 0; i < 20; i++) {
    out
      ..add([0xff, 0xfb, 0x90, 0x64])
      ..add(Uint8List(413));
  }
  return out.toBytes();
}

/// ID3 encoding 2: UTF-16BE without BOM.
List<int> utf16BeFrame(String s) => [
  2,
  for (final c in s.codeUnits) ...[c >> 8, c & 0xff],
  0,
  0,
];

/// ID3 encoding 1 with a big-endian BOM.
List<int> utf16BomBeFrame(String s) => [
  1,
  0xfe,
  0xff,
  for (final c in s.codeUnits) ...[c >> 8, c & 0xff],
  0,
  0,
];

void main() {
  group('repairTagText', () {
    test('fixes byte-swapped UTF-16 ("Chinese" gibberish)', () {
      expect(repairTagText('䠀椀'), 'Hi');
      final swapped = String.fromCharCodes(
        'Hello World'.codeUnits.map((c) => c << 8),
      );
      expect(repairTagText(swapped), 'Hello World');
    });

    test('fixes UTF-8 read as Latin-1', () {
      expect(repairTagText('BeyoncÃ©'), 'Beyoncé');
    });

    test('keeps normal English text and accents', () {
      expect(repairTagText('  AC/DC  '), 'AC/DC');
      expect(repairTagText('Sigur Rós'), 'Sigur Rós');
      expect(repairTagText('Don’t Stop'), 'Don’t Stop');
    });

    test('rejects non-Latin text so callers fall back', () {
      expect(repairTagText('周杰伦'), isNull);
      expect(repairTagText(''), isNull);
      expect(repairTagText('﻿'), isNull);
    });

    test('file name fallback', () {
      final r = parseFileName('/m/03 - Daft Punk - One More Time.mp3');
      expect(r.artist, 'Daft Punk');
      expect(r.title, 'One More Time');
      expect(parseFileName('/m/some_song.flac').title, 'some song');
    });
  });

  test('scanner turns UTF-16BE ID3 tags into readable English', () async {
    final dir = await Directory.systemTemp.createTemp('scan_test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/track.mp3')
      ..writeAsBytesSync(
        buildMp3({
          'TIT2': utf16BeFrame('Midnight City'),
          'TPE1': utf16BomBeFrame('M83'),
          'TALB': utf16BeFrame('Hurry Up'),
        }),
      );

    // Show the bug being worked around: the raw parser output is garbled.
    final raw = readMetadata(file);
    expect(raw.title, isNot('Midnight City'));

    final tracks = await scanFolders(
      folders: [dir.path],
      previous: const [],
      artDir: '${dir.path}/art',
    );
    expect(tracks, hasLength(1));
    expect(tracks.single.title, 'Midnight City');
    expect(tracks.single.artist, 'M83');
    expect(tracks.single.album, 'Hurry Up');
  });

  group('extractImage', () {
    final png = Uint8List.fromList([
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
      1,
      2,
      3,
    ]);

    test('passes clean images through', () {
      final r = extractImage(png)!;
      expect(r.ext, '.png');
      expect(r.bytes, png);
    });

    test('strips a UTF-16 description stuck in front of the image', () {
      // Same shape as the broken file found on the device: "attach…" in
      // UTF-16LE, then the PNG.
      final junk = [
        for (final c in 'attached picture'.codeUnits) ...[c, 0],
      ];
      final r = extractImage(Uint8List.fromList([...junk, 0, 0, ...png]))!;
      expect(r.ext, '.png');
      expect(r.bytes, png);
    });

    test('rejects data that is not an image', () {
      expect(extractImage(Uint8List.fromList('-->http://x'.codeUnits)), isNull);
    });
  });

  group('sorting', () {
    Track t(String title, String artist, {int ms = 0, int dur = 0}) => Track(
      id: title,
      path: '/$title',
      title: title,
      artist: artist,
      album: 'A',
      durationMs: dur,
      modifiedMs: ms,
    );
    final tracks = [
      t('beta', 'The Zombies', ms: 1, dur: 300),
      t('Alpha', 'Abba', ms: 3, dur: 100),
      t('gamma', 'Moby', ms: 2, dur: 200),
    ];
    List<String> titles(List<Track> l) => [for (final x in l) x.title];

    test('by title, case-insensitive, both directions', () {
      final s = Settings();
      expect(titles(s.sortSongs(tracks)), ['Alpha', 'beta', 'gamma']);
      s.songDescending = true;
      expect(titles(s.sortSongs(tracks)), ['gamma', 'beta', 'Alpha']);
    });

    test('by artist ignores leading "The"', () {
      final s = Settings()..songSort = SongSort.artist;
      expect(titles(s.sortSongs(tracks)), ['Alpha', 'gamma', 'beta']);
    });

    test('by date added is newest first; by duration shortest first', () {
      final s = Settings()..songSort = SongSort.dateAdded;
      expect(titles(s.sortSongs(tracks)), ['Alpha', 'gamma', 'beta']);
      s.songSort = SongSort.duration;
      expect(titles(s.sortSongs(tracks)), ['Alpha', 'gamma', 'beta']);
    });

    test('albums by song count', () {
      final s = Settings()..albumSort = AlbumSort.songCount;
      final sorted = s.sortAlbums({
        'Small': [tracks[0]],
        'Big': tracks,
      });
      expect(sorted.map((e) => e.key), ['Big', 'Small']);
    });
  });
}
