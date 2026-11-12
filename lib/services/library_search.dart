import 'dart:math' as math;

import '../models/playlist.dart';
import '../models/track.dart';
import 'voice_match.dart';

/// Ranked matches for a search box query.
class SearchResults {
  const SearchResults({
    required this.songs,
    required this.artists,
    required this.albums,
    required this.playlists,
  });

  static const empty = SearchResults(
    songs: [],
    artists: [],
    albums: [],
    playlists: [],
  );

  final List<Track> songs;
  final List<MapEntry<String, List<Track>>> artists;
  final List<MapEntry<String, List<Track>>> albums;
  final List<Playlist> playlists;

  bool get isEmpty =>
      songs.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty;
}

/// Minimum score for typed search; lower than voice since partial words
/// are normal while typing.
const _typedThreshold = 0.62;

/// How well a typed [query] matches [text]: exact words and prefixes score
/// highest, then substrings, then typo-tolerant similarity.
double typedScore(String query, String text) {
  final q = normalize(query);
  final t = normalize(text);
  if (q.isEmpty || t.isEmpty) return 0;
  if (t == q) return 1;
  if (t.startsWith(q)) return 0.95;
  // Any word starting with the query ("yell" -> "Hello Yellow").
  if (t.split(' ').any((w) => w.startsWith(q))) return 0.9;
  if (t.contains(q)) return 0.85;
  // Typos only make sense once there's enough to go on.
  if (q.length < 3) return 0;
  var best = similarity(q, t);
  // Compare against the same number of words, so "colplay" vs
  // "Coldplay Live 2012" isn't drowned out by the extra words.
  final words = t.split(' ');
  final n = q.split(' ').length;
  for (var i = 0; i + n <= words.length; i++) {
    best = math.max(best, similarity(q, words.sublist(i, i + n).join(' ')));
  }
  return best;
}

SearchResults searchLibrary(
  String query, {
  required List<Track> tracks,
  required Map<String, List<Track>> artists,
  required Map<String, List<Track>> albums,
  required List<Playlist> playlists,
  int maxSongs = 100,
}) {
  if (normalize(query).isEmpty) return SearchResults.empty;

  List<T> ranked<T>(Iterable<T> items, double Function(T) score, int limit) {
    final scored = [
      for (final item in items)
        if (score(item) case final s when s >= _typedThreshold) (item, s),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (item, _) in scored.take(limit)) item];
  }

  return SearchResults(
    songs: ranked(
      tracks,
      (t) => math.max(
        typedScore(query, t.title),
        math.max(
          typedScore(query, t.artist) * 0.92,
          typedScore(query, t.album) * 0.88,
        ),
      ),
      maxSongs,
    ),
    artists: ranked(artists.entries, (e) => typedScore(query, e.key), 6),
    albums: ranked(albums.entries, (e) => typedScore(query, e.key), 6),
    playlists: ranked(playlists, (p) => typedScore(query, p.name), 6),
  );
}
