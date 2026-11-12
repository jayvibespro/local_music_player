import 'dart:math' as math;

/// Built-in collections a voice request can name.
enum VoiceCollection { everything, favorites, mix, recent, mostPlayed, added }

/// What kind of thing the request named, when it said so ("the album …").
enum VoiceKind { artist, album, playlist, song }

/// A spoken request, e.g. "shuffle the album Parachutes", cleaned up.
class VoiceQuery {
  const VoiceQuery(
    this.text, {
    this.shuffle = false,
    this.kind,
    this.collection,
  });

  /// The name being asked for, normalised.
  final String text;
  final bool shuffle;
  final VoiceKind? kind;
  final VoiceCollection? collection;
}

/// Lowercase, punctuation and accents-insensitive form used for matching.
String normalize(String s) => s
    .toLowerCase()
    .replaceAll(RegExp("['’`]"), '')
    .replaceAll('&', ' and ')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

const _collections = {
  VoiceCollection.everything: {
    '',
    'music',
    'some music',
    'something',
    'anything',
    'songs',
    'my music',
    'all songs',
    'all my songs',
    'everything',
    'all music',
    'my songs',
  },
  VoiceCollection.favorites: {
    'favourites',
    'favorites',
    'favourite songs',
    'favorite songs',
    'liked songs',
    'liked',
    'loved songs',
    'likes',
    'my likes',
  },
  VoiceCollection.mix: {
    'driving mix',
    'drive mix',
    'car mix',
    'mix',
    'my mix',
    'road trip mix',
    'driving music',
    'driving songs',
    'music for driving',
    'road trip music',
  },
  VoiceCollection.recent: {
    'recently played',
    'recent',
    'recent songs',
    'last played',
    'what i was listening to',
    'recently played songs',
  },
  VoiceCollection.mostPlayed: {
    'most played',
    'top songs',
    'top tracks',
    'my top songs',
    'my top tracks',
    'most played songs',
    'my most played',
  },
  VoiceCollection.added: {
    'recently added',
    'new songs',
    'new music',
    'latest songs',
    'newest songs',
    'recently added songs',
  },
};

VoiceQuery parseVoiceQuery(String raw) {
  var q = normalize(raw);
  var shuffle = false;
  VoiceKind? kind;

  bool strip(String prefix) {
    if (!q.startsWith(prefix)) return false;
    q = q.substring(prefix.length).trim();
    return true;
  }

  bool stripEnd(String suffix) {
    if (!q.endsWith(suffix)) return false;
    q = q.substring(0, q.length - suffix.length).trim();
    return true;
  }

  // Leading verbs, in any order ("play shuffle …", "shuffle play …").
  for (var changed = true; changed;) {
    changed = false;
    if (strip('shuffle ') || q == 'shuffle') {
      if (q == 'shuffle') q = '';
      shuffle = changed = true;
    }
    for (final verb in ['play ', 'listen to ', 'put on ', 'start ']) {
      if (strip(verb)) changed = true;
    }
  }
  for (final suffix in [' on shuffle', ' shuffled', ' in shuffle']) {
    if (stripEnd(suffix)) shuffle = true;
  }
  stripEnd(' on music player');
  stripEnd(' on my phone');

  const kinds = {
    VoiceKind.playlist: ['the playlist ', 'playlist ', 'my playlist '],
    VoiceKind.album: ['the album ', 'album '],
    VoiceKind.artist: [
      'songs by ',
      'music by ',
      'something by ',
      'the artist ',
      'artist ',
    ],
    VoiceKind.song: ['the song ', 'song '],
  };
  for (final MapEntry(key: k, value: prefixes) in kinds.entries) {
    if (prefixes.any(strip)) {
      kind = k;
      break;
    }
  }
  if (kind == null) {
    if (stripEnd(' playlist')) {
      kind = VoiceKind.playlist;
    } else if (stripEnd(' album')) {
      kind = VoiceKind.album;
    }
  }
  if (kind == null) strip('some ');
  // "my Road Trip playlist" → "road trip". (A playlist really called
  // "My …" still matches well on its other words.)
  strip('my ');

  for (final MapEntry(key: collection, value: phrases)
      in _collections.entries) {
    if (phrases.contains(q) ||
        phrases.contains('my $q') ||
        (q.startsWith('my ') && phrases.contains(q.substring(3)))) {
      return VoiceQuery(
        q,
        // Asking for "music" or a mix means a shuffled play.
        shuffle:
            shuffle ||
            collection == VoiceCollection.everything ||
            collection == VoiceCollection.mix,
        collection: collection,
      );
    }
  }
  return VoiceQuery(q, shuffle: shuffle, kind: kind);
}

/// How well [name] matches the spoken [query], from 0 to 1. Tolerates
/// "the", word order, partial names and small mis-hearings.
double similarity(String query, String name) {
  final a = _stripThe(normalize(query));
  final b = _stripThe(normalize(name));
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;

  var best = 0.0;
  final shorter = math.min(a.length, b.length);
  if (shorter >= 3 && (b.startsWith(a) || a.startsWith(b))) {
    best = 0.82 + 0.12 * shorter / math.max(a.length, b.length);
  } else if (a.length >= 4 && b.contains(a)) {
    best = 0.78;
  }

  // Every spoken word appears in the name, in any order.
  final qWords = a.split(' ').toSet();
  final nWords = b.split(' ').toSet();
  final common = qWords.intersection(nWords).length;
  if (common > 0) {
    final coverage = common / qWords.length;
    final precision = common / nWords.length;
    best = math.max(best, 0.6 * coverage + 0.3 * precision);
  }

  // Mis-heard spelling ("colplay").
  if (math.max(a.length, b.length) <= 40) {
    final ratio = 1 - _levenshtein(a, b) / math.max(a.length, b.length);
    best = math.max(best, ratio * 0.95);
  }
  return best;
}

/// Minimum [similarity] for a voice match to be trusted.
const matchThreshold = 0.72;

/// The item whose [name] best matches [query], with its score.
({T item, double score})? bestMatch<T>(
  String query,
  Iterable<T> items,
  String Function(T) name,
) {
  ({T item, double score})? best;
  for (final item in items) {
    final score = similarity(query, name(item));
    if (best == null || score > best.score) best = (item: item, score: score);
    if (score == 1) break;
  }
  return best;
}

String _stripThe(String s) => s.startsWith('the ') ? s.substring(4) : s;

int _levenshtein(String a, String b) {
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      current[j] = math.min(
        math.min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
    }
    previous = current;
  }
  return previous[b.length];
}

/// A spoken in-app command.
sealed class VoiceCommand {
  const VoiceCommand();
}

class PlayCommand extends VoiceCommand {
  const PlayCommand(this.query);

  /// Passed to the same search/play logic as Google Assistant and Auto.
  final String query;
}

enum TransportAction {
  play,
  pause,
  next,
  previous,
  shuffleOn,
  shuffleOff,
  repeat,
}

class TransportCommand extends VoiceCommand {
  const TransportCommand(this.action);
  final TransportAction action;
}

class FavoriteCommand extends VoiceCommand {
  const FavoriteCommand();
}

class SleepCommand extends VoiceCommand {
  /// Null turns the timer off.
  const SleepCommand(this.duration, {this.endOfSong = false});
  final Duration? duration;
  final bool endOfSong;
}

class WhatsPlayingCommand extends VoiceCommand {
  const WhatsPlayingCommand();
}

const _numberWords = {
  'a': 1,
  'an': 1,
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'ten': 10,
  'fifteen': 15,
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'forty five': 45,
  'sixty': 60,
  'ninety': 90,
};

/// Turns a transcript into a command. Anything not recognised as a control
/// is treated as a request to play something.
VoiceCommand parseVoiceCommand(String transcript) {
  final t = normalize(transcript);
  bool any(Iterable<String> phrases) => phrases.contains(t);

  if (any([
    'pause',
    'stop',
    'pause music',
    'stop music',
    'pause the music',
    'stop the music',
    'be quiet',
  ])) {
    return const TransportCommand(TransportAction.pause);
  }
  if (any([
    'play',
    'resume',
    'continue',
    'unpause',
    'keep playing',
    'resume music',
    'play music again',
  ])) {
    return const TransportCommand(TransportAction.play);
  }
  if (any([
    'next',
    'skip',
    'next song',
    'skip song',
    'skip this song',
    'skip this',
    'next track',
    'play next song',
    'play the next song',
  ])) {
    return const TransportCommand(TransportAction.next);
  }
  if (any([
    'previous',
    'back',
    'go back',
    'previous song',
    'last song',
    'play previous song',
    'play the previous song',
    'previous track',
  ])) {
    return const TransportCommand(TransportAction.previous);
  }
  if (any(['shuffle on', 'turn on shuffle', 'turn shuffle on', 'shuffle'])) {
    return const TransportCommand(TransportAction.shuffleOn);
  }
  if (any([
    'shuffle off',
    'turn off shuffle',
    'turn shuffle off',
    'stop shuffling',
    'no shuffle',
  ])) {
    return const TransportCommand(TransportAction.shuffleOff);
  }
  if (any([
    'repeat',
    'repeat this',
    'repeat this song',
    'repeat song',
    'loop',
    'loop this song',
  ])) {
    return const TransportCommand(TransportAction.repeat);
  }
  if (any([
    'like',
    'like this',
    'like this song',
    'i like this song',
    'favourite',
    'favorite',
    'favourite this',
    'favorite this',
    'favourite this song',
    'favorite this song',
    'add to favourites',
    'add to favorites',
    'add this to favourites',
    'add this to favorites',
    'love this song',
    'i love this song',
  ])) {
    return const FavoriteCommand();
  }
  if (any([
    'whats playing',
    'what is playing',
    'what song is this',
    'whats this song',
    'what is this song',
    'who sings this',
  ])) {
    return const WhatsPlayingCommand();
  }

  // Sleep timer: "sleep timer 20 minutes", "stop in half an hour",
  // "stop after this song", "cancel sleep timer".
  if (t.contains('sleep timer') ||
      t.startsWith('stop in ') ||
      t.startsWith('stop after ') ||
      t.startsWith('sleep in ') ||
      t.startsWith('stop playing in ') ||
      t.startsWith('stop playing after ')) {
    if (RegExp(r'\b(cancel|off|turn off|stop the|remove)\b').hasMatch(t) &&
        !RegExp(r'\d|minute|hour').hasMatch(t)) {
      return const SleepCommand(null);
    }
    if (t.contains('this song') ||
        t.contains('end of the song') ||
        t.contains('end of song') ||
        t.contains('this track')) {
      return const SleepCommand(null, endOfSong: true);
    }
    if (t.contains('half an hour') || t.contains('half hour')) {
      return const SleepCommand(Duration(minutes: 30));
    }
    final match = RegExp(
      r'(\d+|' + _numberWords.keys.join('|') + r')\s*(minute|min|hour|hr)',
    ).firstMatch(t);
    if (match != null) {
      final n = int.tryParse(match.group(1)!) ?? _numberWords[match.group(1)!]!;
      final hours = match.group(2)!.startsWith('h');
      return SleepCommand(Duration(minutes: hours ? n * 60 : n));
    }
  }

  return PlayCommand(transcript.trim());
}
