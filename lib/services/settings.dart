import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';

enum SongSort {
  title('Title'),
  artist('Artist'),
  album('Album'),
  dateAdded('Date added'),
  duration('Duration');

  const SongSort(this.label);
  final String label;
}

enum AlbumSort {
  name('Name'),
  artist('Artist'),
  songCount('Number of songs');

  const AlbumSort(this.label);
  final String label;
}

enum ArtistSort {
  name('Name'),
  songCount('Number of songs');

  const ArtistSort(this.label);
  final String label;
}

/// Accent presets for the theme.
enum Accent {
  violet('Neon violet', Color(0xFF8B5CF6)),
  pink('Hot pink', Color(0xFFEC4899)),
  cyan('Cyber cyan', Color(0xFF06B6D4)),
  lime('Acid lime', Color(0xFF84CC16)),
  orange('Sunset', Color(0xFFF97316)),
  red('Crimson', Color(0xFFEF4444));

  const Accent(this.label, this.color);
  final String label;
  final Color color;
}

/// User preferences, persisted to settings.json.
class Settings extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.dark;

  /// Last selected home tab, restored on launch.
  int homeTab = 0;
  bool pureBlack = false;
  bool adaptiveColor = true;
  Accent accent = Accent.violet;

  SongSort songSort = SongSort.title;
  bool songDescending = false;
  AlbumSort albumSort = AlbumSort.name;
  bool albumDescending = false;
  ArtistSort artistSort = ArtistSort.name;
  bool artistDescending = false;

  // Playback
  /// Fade the end of each song out and the next one in.
  bool fadeTransitions = false;
  int fadeSeconds = 5;

  /// Equalizer (Android). [eqGains] holds dB per device band index.
  bool eqEnabled = false;
  String eqPreset = 'flat';
  List<double> eqGains = [];
  double eqPreamp = 0;

  /// Even out loudness between songs (ReplayGain tags, else an estimate).
  bool normalizeVolume = false;

  /// Spectrum visualizer on Now Playing (needs microphone permission).
  bool showVisualizer = false;

  /// Most recent first.
  List<String> recentSearches = [];

  // Car & Bluetooth
  /// Continue the last queue when Android Auto connects.
  bool autoPlayInCar = true;

  /// Continue playing when a Bluetooth audio device connects.
  bool resumeOnBluetooth = false;

  File? _file;

  Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File(p.join(dir.path, 'settings.json'));
      if (!await _file!.exists()) return;
      final json =
          jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
      T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
          values.where((v) => v.name == name).firstOrNull ?? fallback;

      themeMode = pick(ThemeMode.values, json['themeMode'], themeMode);
      pureBlack = json['pureBlack'] as bool? ?? pureBlack;
      adaptiveColor = json['adaptiveColor'] as bool? ?? adaptiveColor;
      accent = pick(Accent.values, json['accent'], accent);
      songSort = pick(SongSort.values, json['songSort'], songSort);
      songDescending = json['songDescending'] as bool? ?? false;
      albumSort = pick(AlbumSort.values, json['albumSort'], albumSort);
      albumDescending = json['albumDescending'] as bool? ?? false;
      artistSort = pick(ArtistSort.values, json['artistSort'], artistSort);
      artistDescending = json['artistDescending'] as bool? ?? false;
      homeTab = json['homeTab'] as int? ?? 0;
      if (json['tabsVersion'] != 2) {
        // Old order: Songs, Albums, Artists, Favourites, Playlists.
        // New order: For you, Songs, Albums, Artists, Playlists.
        homeTab = const [1, 2, 3, 0, 4][homeTab.clamp(0, 4)];
      }
      fadeTransitions = json['fadeTransitions'] as bool? ?? fadeTransitions;
      fadeSeconds = json['fadeSeconds'] as int? ?? fadeSeconds;
      eqEnabled = json['eqEnabled'] as bool? ?? eqEnabled;
      eqPreset = json['eqPreset'] as String? ?? eqPreset;
      eqGains = [
        for (final g in json['eqGains'] as List? ?? const [])
          (g as num).toDouble(),
      ];
      eqPreamp = (json['eqPreamp'] as num?)?.toDouble() ?? eqPreamp;
      normalizeVolume = json['normalizeVolume'] as bool? ?? normalizeVolume;
      showVisualizer = json['showVisualizer'] as bool? ?? showVisualizer;
      recentSearches = (json['recentSearches'] as List? ?? const [])
          .cast<String>()
          .toList();
      autoPlayInCar = json['autoPlayInCar'] as bool? ?? autoPlayInCar;
      resumeOnBluetooth =
          json['resumeOnBluetooth'] as bool? ?? resumeOnBluetooth;
    } catch (e) {
      debugPrint('Failed to load settings: $e');
    } finally {
      // The audio handler may already be listening (e.g. EQ, fades).
      notifyListeners();
    }
  }

  /// Applies [change] then notifies and saves.
  Future<void> update(void Function(Settings s) change) async {
    change(this);
    notifyListeners();
    await _file?.writeAsString(
      jsonEncode({
        'themeMode': themeMode.name,
        'pureBlack': pureBlack,
        'adaptiveColor': adaptiveColor,
        'accent': accent.name,
        'songSort': songSort.name,
        'songDescending': songDescending,
        'albumSort': albumSort.name,
        'albumDescending': albumDescending,
        'artistSort': artistSort.name,
        'artistDescending': artistDescending,
        'homeTab': homeTab,
        'tabsVersion': 2,
        'fadeTransitions': fadeTransitions,
        'fadeSeconds': fadeSeconds,
        'eqEnabled': eqEnabled,
        'eqPreset': eqPreset,
        'eqGains': eqGains,
        'eqPreamp': eqPreamp,
        'normalizeVolume': normalizeVolume,
        'showVisualizer': showVisualizer,
        'recentSearches': recentSearches,
        'autoPlayInCar': autoPlayInCar,
        'resumeOnBluetooth': resumeOnBluetooth,
      }),
    );
  }

  /// Remembers a search (max 8, no duplicates).
  Future<void> addRecentSearch(String query) {
    final q = query.trim();
    if (q.isEmpty) return Future.value();
    return update((s) {
      s.recentSearches = [
        q,
        ...s.recentSearches.where((r) => r.toLowerCase() != q.toLowerCase()),
      ].take(8).toList();
    });
  }

  // ---------------------------------------------------------------------------
  // Sorting

  List<Track> sortSongs(List<Track> tracks) {
    final Comparator<Track> by = switch (songSort) {
      SongSort.title => (a, b) => _cmp(a.title, b.title),
      SongSort.artist => (a, b) => _then(
        _cmp(a.artist, b.artist),
        () => _then(_cmp(a.album, b.album), () => _cmpTrackNo(a, b)),
      ),
      SongSort.album => (a, b) => _then(
        _cmp(a.album, b.album),
        () => _cmpTrackNo(a, b),
      ),
      // Newest first is the natural ascending order for "date added".
      SongSort.dateAdded => (a, b) => b.modifiedMs.compareTo(a.modifiedMs),
      SongSort.duration => (a, b) => a.durationMs.compareTo(b.durationMs),
    };
    return _sorted(
      tracks,
      by,
      songDescending,
      tieBreak: (a, b) => _cmp(a.title, b.title),
    );
  }

  List<MapEntry<String, List<Track>>> sortAlbums(
    Map<String, List<Track>> albums,
  ) {
    final Comparator<MapEntry<String, List<Track>>> by = switch (albumSort) {
      AlbumSort.name => (a, b) => _cmp(a.key, b.key),
      AlbumSort.artist => (a, b) => _cmp(
        a.value.first.artist,
        b.value.first.artist,
      ),
      AlbumSort.songCount => (a, b) => b.value.length.compareTo(a.value.length),
    };
    return _sorted(
      albums.entries.toList(),
      by,
      albumDescending,
      tieBreak: (a, b) => _cmp(a.key, b.key),
    );
  }

  List<MapEntry<String, List<Track>>> sortArtists(
    Map<String, List<Track>> artists,
  ) {
    final Comparator<MapEntry<String, List<Track>>> by = switch (artistSort) {
      ArtistSort.name => (a, b) => _cmp(a.key, b.key),
      ArtistSort.songCount => (a, b) => b.value.length.compareTo(
        a.value.length,
      ),
    };
    return _sorted(
      artists.entries.toList(),
      by,
      artistDescending,
      tieBreak: (a, b) => _cmp(a.key, b.key),
    );
  }

  static List<T> _sorted<T>(
    List<T> items,
    Comparator<T> by,
    bool descending, {
    required Comparator<T> tieBreak,
  }) => [...items]
    ..sort((a, b) {
      final c = descending ? by(b, a) : by(a, b);
      return c != 0 ? c : tieBreak(a, b);
    });

  static int _then(int first, int Function() next) =>
      first != 0 ? first : next();

  static int _cmpTrackNo(Track a, Track b) =>
      (a.trackNumber ?? 0).compareTo(b.trackNumber ?? 0);

  /// Case-insensitive, ignoring a leading "The " ("The Beatles" sorts as B).
  static int _cmp(String a, String b) => _key(a).compareTo(_key(b));

  static String _key(String s) {
    final lower = s.toLowerCase();
    return lower.startsWith('the ') ? lower.substring(4) : lower;
  }
}
