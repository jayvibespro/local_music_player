import 'dart:convert';

import 'package:path/path.dart' as p;

/// Cleans a tag value and repairs common decoding errors. Returns null when
/// the text is empty or still isn't Latin script after repair, so callers can
/// fall back to something readable (the file name, "Unknown artist", …).
String? repairTagText(String? raw) {
  if (raw == null) return null;
  var text = _stripInvisible(raw);
  if (text.isEmpty) return null;

  // UTF-16 big-endian text decoded as little-endian has every code unit
  // byte-swapped, which turns "Hi" (00 48 00 69) into "䠀椀". This is the
  // usual source of "Chinese" titles on English songs.
  if (!_isLatin(text)) {
    final swapped = _stripInvisible(
      String.fromCharCodes(
        text.codeUnits.map((c) => ((c & 0xff) << 8) | (c >> 8)),
      ),
    );
    if (swapped.isNotEmpty && _isLatin(swapped)) text = swapped;
  }

  // UTF-8 bytes decoded as Latin-1 ("BeyoncÃ©" instead of "Beyoncé").
  if (text.codeUnits.every((c) => c <= 0xff) &&
      text.codeUnits.any((c) => c >= 0xc2)) {
    try {
      text = utf8.decode(latin1.encode(text));
    } on FormatException {
      // Genuine Latin-1; keep as is.
    }
  }

  text = _fullWidthToAscii(text).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty || !_isLatin(text)) return null;
  return text;
}

/// Readable title/artist guessed from a file name such as
/// `03 - Artist Name - Song Title.mp3` or `song_title.flac`.
({String? artist, String? title}) parseFileName(String path) {
  var name = p.basenameWithoutExtension(path).replaceAll('_', ' ');
  name = name.replaceFirst(RegExp(r'^\s*\d{1,3}\s*[-.)]?\s+'), '');
  final parts = name.split(RegExp(r'\s+-\s+'));
  if (parts.length >= 2) {
    return (
      artist: repairTagText(parts.first),
      title: repairTagText(parts.sublist(1).join(' - ')),
    );
  }
  return (artist: null, title: repairTagText(name));
}

String _stripInvisible(String s) =>
    s.replaceAll(RegExp('[\u0000-\u001f\u007f﻿￾�​]'), '').trim();

String _fullWidthToAscii(String s) => String.fromCharCodes(
  s.runes.map(
    (r) => r >= 0xff01 && r <= 0xff5e ? r - 0xfee0 : (r == 0x3000 ? 0x20 : r),
  ),
);

/// True when every character is Latin script, digits, punctuation, common
/// symbols or emoji, i.e. no CJK, Cyrillic, Arabic, etc.
bool _isLatin(String s) {
  for (final r in s.runes) {
    final ok =
        r < 0x0370 || // Basic Latin through IPA & combining marks
        (r >= 0x1e00 && r <= 0x1eff) || // Latin Extended Additional
        (r >= 0x2000 && r <= 0x2bff) || // Punctuation, symbols, arrows
        (r >= 0xff01 && r <= 0xff5e) || // Full-width ASCII
        r == 0x3000 ||
        (r >= 0x1f000 && r <= 0x1faff); // Emoji
    if (!ok) return false;
  }
  return true;
}
