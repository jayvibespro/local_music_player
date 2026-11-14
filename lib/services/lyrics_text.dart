import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Decoding for lyrics text, done here rather than by audio_metadata_reader:
/// its ID3 lyrics (USLT) parser always reads UTF-16 as little-endian and can
/// land one byte off after the description, both of which turn English
/// lyrics into strings of Chinese characters.

/// Lyrics embedded in an MP3's ID3v2.3/2.4 tag, or null if it has none.
String? readId3Lyrics(String path) {
  final file = File(path).openSync();
  try {
    final header = file.readSync(10);
    if (header.length < 10 ||
        header[0] != 0x49 || // I
        header[1] != 0x44 || // D
        header[2] != 0x33) {
      return null;
    }
    final size = _syncsafe(header, 6);
    return id3LyricsFromTag(header, file.readSync(size));
  } finally {
    file.closeSync();
  }
}

/// Finds the first non-empty USLT frame in an ID3v2 tag ([header] is its 10
/// header bytes, [body] what follows).
String? id3LyricsFromTag(Uint8List header, Uint8List body) {
  final major = header[3];
  if (major != 3 && major != 4) return null;
  final tagFlags = header[5];
  final unsyncAll = tagFlags & 0x80 != 0;
  var data = body;
  if (major == 3 && unsyncAll) data = _removeUnsync(data);

  var pos = 0;
  if (tagFlags & 0x40 != 0 && data.length >= 4) {
    // Extended header: v2.4 counts its own size, v2.3 doesn't.
    pos = major == 4 ? _syncsafe(data, 0) : _int32(data, 0) + 4;
  }

  while (pos + 10 <= data.length && data[pos] != 0) {
    final id = String.fromCharCodes(data, pos, pos + 4);
    // Some old taggers wrote plain sizes into v2.4 tags; a byte with the
    // top bit set can't be syncsafe, so read those as plain.
    final sizeBytes = data.sublist(pos + 4, pos + 8);
    final size = major == 4 && sizeBytes.every((b) => b < 0x80)
        ? _syncsafe(data, pos + 4)
        : _int32(data, pos + 4);
    final frameFlags = data[pos + 9];
    final start = pos + 10;
    final end = start + size;
    if (size <= 0 || end > data.length) break;

    if (id == 'USLT') {
      var frame = Uint8List.sublistView(data, start, end);
      var readable = true;
      if (major == 4) {
        if (frameFlags & 0x0c != 0) readable = false; // compressed/encrypted
        if (frameFlags & 0x01 != 0 && frame.length >= 4) {
          frame = Uint8List.sublistView(frame, 4); // data length indicator
        }
        if (unsyncAll || frameFlags & 0x02 != 0) frame = _removeUnsync(frame);
      } else if (frameFlags & 0xc0 != 0) {
        readable = false;
      }
      if (readable) {
        final text = _usltText(frame);
        if (text != null && text.trim().isNotEmpty) return text;
      }
    }
    pos = end;
  }
  return null;
}

/// Text of a USLT frame: encoding, language, description, then lyrics.
String? _usltText(Uint8List frame) {
  if (frame.length < 5) return null;
  final encoding = frame[0];
  final wide = encoding == 1 || encoding == 2;
  var i = 4; // after the encoding byte and 3-letter language
  if (wide) {
    // A UTF-16 description ends with a 00 00 pair on a 2-byte boundary.
    while (i + 1 < frame.length && (frame[i] != 0 || frame[i + 1] != 0)) {
      i += 2;
    }
    i += 2;
  } else {
    while (i < frame.length && frame[i] != 0) {
      i++;
    }
    i += 1;
  }
  if (i >= frame.length) return null;
  final text = Uint8List.sublistView(frame, i);
  return switch (encoding) {
    0 => _utf8OrLatin1(text),
    1 => _utf16(text),
    2 => _utf16(text, bigEndian: true),
    _ => _stripBom(utf8.decode(text, allowMalformed: true)),
  }.split('\u0000').first;
}

/// Decodes a lyrics (.lrc/.txt) file: honours UTF-8 and UTF-16 byte-order
/// marks, recognises UTF-16 without one, then tries UTF-8 and falls back to
/// Latin-1 for older files.
String decodeTextFile(Uint8List bytes) {
  if (bytes.length >= 2) {
    if (bytes[0] == 0xff && bytes[1] == 0xfe) return _utf16(bytes);
    if (bytes[0] == 0xfe && bytes[1] == 0xff) {
      return _utf16(bytes, bigEndian: true);
    }
    if (_looksUtf16(bytes)) return _utf16(bytes);
  }
  return _utf8OrLatin1(bytes);
}

/// Last line of defence for lyrics decoded elsewhere: undoes UTF-16 that
/// was read with the wrong byte order, which shows up as mostly CJK text
/// that becomes mostly Latin when each character's bytes are swapped.
/// Genuinely Chinese, Japanese or Korean lyrics are left alone, since
/// swapping those produces gibberish rather than Latin text.
String repairSwappedText(String text) {
  if (_share(text, _isCjk) < 0.3) return text;
  final swapped = String.fromCharCodes(
    text.codeUnits.map((c) => ((c & 0xff) << 8) | (c >> 8)),
  ).replaceAll('\u0000', '');
  return _share(swapped, _isLatinish) > 0.9 ? swapped : text;
}

String _utf16(Uint8List bytes, {bool bigEndian = false}) {
  var start = 0;
  if (bytes.length >= 2) {
    if (bytes[0] == 0xff && bytes[1] == 0xfe) {
      bigEndian = false;
      start = 2;
    } else if (bytes[0] == 0xfe && bytes[1] == 0xff) {
      bigEndian = true;
      start = 2;
    } else if (!bigEndian) {
      // No byte-order mark: ASCII has its zero byte first in big-endian.
      bigEndian = _zeroShare(bytes, 0) > _zeroShare(bytes, 1);
    }
  }
  final units = <int>[
    for (var i = start; i + 1 < bytes.length; i += 2)
      bigEndian
          ? (bytes[i] << 8) | bytes[i + 1]
          : bytes[i] | (bytes[i + 1] << 8),
  ];
  return String.fromCharCodes(units);
}

String _utf8OrLatin1(Uint8List bytes) {
  try {
    return _stripBom(utf8.decode(bytes));
  } on FormatException {
    return latin1.decode(bytes);
  }
}

String _stripBom(String s) => s.startsWith('﻿') ? s.substring(1) : s;

/// Mostly-ASCII UTF-16 has a zero in nearly every other byte.
bool _looksUtf16(Uint8List bytes) {
  final sample = bytes.length.clamp(0, 400);
  if (sample < 4) return false;
  final view = Uint8List.sublistView(bytes, 0, sample);
  return _zeroShare(view, 0) > 0.4 || _zeroShare(view, 1) > 0.4;
}

/// Share of bytes at even ([parity] 0) or odd positions that are zero.
double _zeroShare(Uint8List bytes, int parity) {
  var zeros = 0, total = 0;
  for (var i = parity; i < bytes.length && total < 400; i += 2) {
    total++;
    if (bytes[i] == 0) zeros++;
  }
  return total == 0 ? 0 : zeros / total;
}

double _share(String s, bool Function(int) test) {
  var hits = 0, total = 0;
  for (final r in s.runes) {
    if (r <= 0x20) continue; // whitespace and control characters
    total++;
    if (test(r)) hits++;
  }
  return total == 0 ? 0 : hits / total;
}

bool _isCjk(int r) =>
    (r >= 0x3000 && r <= 0x9fff) || // CJK symbols, kana, ideographs
    (r >= 0xac00 && r <= 0xd7af) || // Hangul
    (r >= 0xf900 && r <= 0xfaff); // compatibility ideographs

bool _isLatinish(int r) =>
    r < 0x0250 || (r >= 0x2000 && r <= 0x206f) || r == 0x2019;

Uint8List _removeUnsync(Uint8List data) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < data.length; i++) {
    out.addByte(data[i]);
    if (data[i] == 0xff && i + 1 < data.length && data[i + 1] == 0) i++;
  }
  return out.takeBytes();
}

int _syncsafe(List<int> b, int at) =>
    (b[at] & 0x7f) << 21 |
    (b[at + 1] & 0x7f) << 14 |
    (b[at + 2] & 0x7f) << 7 |
    (b[at + 3] & 0x7f);

int _int32(List<int> b, int at) =>
    b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3];
