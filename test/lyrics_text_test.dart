import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_music_player/services/lyrics.dart';
import 'package:local_music_player/services/lyrics_text.dart';

const _lyrics =
    '[00:01.00]Hello darkness my old friend\n'
    '[00:05.50]I\'ve come to talk with you again';

List<int> _utf16(String s, {required bool bigEndian, bool bom = true}) => [
  if (bom) ...(bigEndian ? [0xfe, 0xff] : [0xff, 0xfe]),
  for (final u in s.codeUnits)
    ...(bigEndian ? [u >> 8, u & 0xff] : [u & 0xff, u >> 8]),
];

/// USLT frame body: encoding, language, description, text.
List<int> _uslt(int encoding, String description, String text) {
  final wide = encoding == 1 || encoding == 2;
  final be = encoding == 2;
  List<int> enc(String s) => switch (encoding) {
    0 => latin1.encode(s),
    3 => utf8.encode(s),
    _ => _utf16(s, bigEndian: be, bom: encoding == 1),
  };
  return [
    encoding,
    ...ascii.encode('eng'),
    ...enc(description),
    ...(wide ? [0, 0] : [0]),
    ...enc(text),
  ];
}

List<int> _syncsafe(int n) => [
  (n >> 21) & 0x7f,
  (n >> 14) & 0x7f,
  (n >> 7) & 0x7f,
  n & 0x7f,
];

/// A minimal file: an ID3v2 tag holding [frameBody] as USLT, then fake
/// MPEG audio bytes.
Uint8List _mp3(List<int> frameBody, {int major = 3}) {
  final n = frameBody.length;
  final frameSize = major == 4
      ? _syncsafe(n)
      : [(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
  final frame = [...ascii.encode('USLT'), ...frameSize, 0, 0, ...frameBody];
  final padding = List.filled(32, 0);
  return Uint8List.fromList([
    ...ascii.encode('ID3'),
    major,
    0,
    0,
    ..._syncsafe(frame.length + padding.length),
    ...frame,
    ...padding,
    ...List.filled(64, 0xff),
  ]);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('lyrics_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, List<int> bytes) =>
      File('${dir.path}/$name')..writeAsBytesSync(bytes);

  group('embedded ID3 lyrics', () {
    final cases = {
      'UTF-16 big-endian with BOM': _uslt(1, '', _lyrics),
      'UTF-16 little-endian with BOM': _uslt(1, '', _lyrics),
      'UTF-16BE (encoding 2)': _uslt(2, '', _lyrics),
      'UTF-16 with a description': _uslt(1, 'Lyrics', _lyrics),
      'UTF-8': _uslt(3, 'desc', _lyrics),
      'Latin-1': _uslt(0, '', _lyrics),
    };
    // The first case really is big-endian.
    cases['UTF-16 big-endian with BOM'] = [
      1,
      ...ascii.encode('eng'),
      ..._utf16('', bigEndian: true),
      0,
      0,
      ..._utf16(_lyrics, bigEndian: true),
    ];

    for (final MapEntry(key: name, value: frame) in cases.entries) {
      for (final major in [3, 4]) {
        test('$name, ID3v2.$major', () {
          final f = write('song.mp3', _mp3(frame, major: major));
          expect(readId3Lyrics(f.path), _lyrics);
        });
      }
    }

    test('the metadata package shows big-endian lyrics as Chinese', () {
      // Documents the bug being worked around.
      final f = write('song.mp3', _mp3(cases['UTF-16 big-endian with BOM']!));
      final fromPackage = readMetadata(f).lyrics ?? '';
      expect(fromPackage.contains('Hello'), isFalse);
      expect(fromPackage.runes.any((r) => r >= 0x3400 && r <= 0x9fff), isTrue);
    });

    test('LyricsFinder reads them as English', () async {
      final f = write('bug.mp3', _mp3(cases['UTF-16 big-endian with BOM']!));
      final lyrics = (await LyricsFinder.instance.find(f.path))!;
      expect(lyrics.synced, isTrue);
      expect(lyrics.lines.first.text, 'Hello darkness my old friend');
    });

    test('no tag means no lyrics', () {
      final f = write('plain.mp3', List.filled(100, 0xff));
      expect(readId3Lyrics(f.path), isNull);
    });
  });

  group('.lrc files', () {
    for (final (name, bytes) in [
      ('UTF-16LE with BOM', _utf16(_lyrics, bigEndian: false)),
      ('UTF-16BE with BOM', _utf16(_lyrics, bigEndian: true)),
      ('UTF-16LE without BOM', _utf16(_lyrics, bigEndian: false, bom: false)),
      ('UTF-8 with BOM', [0xef, 0xbb, 0xbf, ...utf8.encode(_lyrics)]),
      ('UTF-8', utf8.encode(_lyrics)),
    ]) {
      test(name, () {
        expect(decodeTextFile(Uint8List.fromList(bytes)), _lyrics);
      });
    }

    test('BOM before a header line is not shown as a lyric', () {
      final text = decodeTextFile(
        Uint8List.fromList([
          0xef,
          0xbb,
          0xbf,
          ...utf8.encode('[ti:Song]\n$_lyrics'),
        ]),
      );
      final lyrics = parseLyrics(text, source: 'x.lrc')!;
      expect(lyrics.lines.length, 2);
    });

    test('Latin-1 files still work', () {
      final text = decodeTextFile(Uint8List.fromList(latin1.encode('Café')));
      expect(text, 'Café');
    });
  });

  group('repairSwappedText', () {
    test('fixes byte-swapped English', () {
      final swapped = String.fromCharCodes(
        _lyrics.codeUnits.map((c) => ((c & 0xff) << 8) | (c >> 8)),
      );
      expect(repairSwappedText(swapped), _lyrics);
    });

    test('leaves real Chinese, Japanese and Korean lyrics alone', () {
      for (final real in [
        '[00:01.00]月亮代表我的心',
        '[00:01.00]夜に駆ける',
        '[00:01.00]사랑해요',
      ]) {
        expect(repairSwappedText(real), real);
      }
    });

    test('leaves English alone', () {
      expect(repairSwappedText(_lyrics), _lyrics);
    });
  });
}
