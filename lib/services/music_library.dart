import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/playlist.dart';
import '../models/track.dart';
import 'file_deleter.dart';
import 'library_scanner.dart';

/// Owns the scanned library plus user data (folders, favourites, playlists)
/// and persists both to JSON in the app support directory.
class MusicLibrary extends ChangeNotifier {
  late final Directory _dataDir;
  final _ready = Completer<void>();

  List<String> _folders = [];

  /// Everything the scanner found, before the user's filters.
  List<Track> _allTracks = [];

  /// What the app shows: [_allTracks] minus hidden songs, excluded folders
  /// and audio shorter than [minDurationSec].
  List<Track> _tracks = [];
  Map<String, Track> _byId = {};
  final Set<String> _hiddenPaths = {};
  List<String> _excludedFolders = [];
  int _minDurationSec = 30;
  final Set<String> _favorites = {};
  final List<Playlist> _playlists = [];
  bool _scanning = false;
  bool _forceFullScan = false;

  /// Bumped whenever browsable content changes, so listeners such as the
  /// Android Auto browse tree can ignore purely cosmetic notifications.
  int revision = 0;

  Map<String, List<Track>>? _albums;
  Map<String, List<Track>>? _artists;

  Future<void> get ready => _ready.future;
  List<String> get folders => List.unmodifiable(_folders);
  List<String> get excludedFolders => List.unmodifiable(_excludedFolders);
  int get minDurationSec => _minDurationSec;
  List<Track> get hiddenTracks =>
      _allTracks.where((t) => _hiddenPaths.contains(t.path)).toList();

  /// Songs filtered out only for being too short (shown in settings).
  int get shortTrackCount => _allTracks
      .where((t) => t.durationMs > 0 && t.durationMs < _minDurationSec * 1000)
      .length;
  List<Track> get tracks => _tracks;
  bool get scanning => _scanning;
  List<Playlist> get playlists => List.unmodifiable(_playlists);

  Track? trackById(String id) => _byId[id];
  bool isFavorite(String trackId) => _favorites.contains(trackId);

  List<Track> get favorites =>
      _tracks.where((t) => _favorites.contains(t.id)).toList();

  Map<String, List<Track>> get albums {
    if (_albums != null) return _albums!;
    final grouped = _group((t) => t.album);
    for (final list in grouped.values) {
      list.sort((a, b) => (a.trackNumber ?? 0).compareTo(b.trackNumber ?? 0));
    }
    return _albums = grouped;
  }

  Map<String, List<Track>> get artists => _artists ??= _group((t) => t.artist);

  Playlist? playlistById(String id) {
    for (final pl in _playlists) {
      if (pl.id == id) return pl;
    }
    return null;
  }

  List<Track> playlistTracks(Playlist playlist) => [
    for (final id in playlist.trackIds) ?_byId[id],
  ];

  List<Track> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return _tracks
        .where(
          (t) =>
              t.title.toLowerCase().contains(q) ||
              t.artist.toLowerCase().contains(q) ||
              t.album.toLowerCase().contains(q),
        )
        .toList();
  }

  Map<String, List<Track>> _group(String Function(Track) key) {
    final map = <String, List<Track>>{};
    for (final t in _tracks) {
      (map[key(t)] ??= []).add(t);
    }
    final keys = map.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return {for (final k in keys) k: map[k]!};
  }

  // ---------------------------------------------------------------------------
  // Loading & persistence

  File get _tracksFile => File(p.join(_dataDir.path, 'tracks.json'));
  File get _userFile => File(p.join(_dataDir.path, 'user.json'));

  Future<void> load() async {
    try {
      _dataDir = await getApplicationSupportDirectory();
      if (await _tracksFile.exists()) {
        final json = jsonDecode(await _tracksFile.readAsString());
        // Older caches were a bare list; anything not matching the current
        // scanner version is shown for now but fully re-read on next scan.
        final list = json is Map ? json['tracks'] as List : json as List;
        _forceFullScan = json is! Map || json['version'] != scannerVersion;
        _allTracks = [for (final j in list) Track.fromJson(j)];
      }
      if (await _userFile.exists()) {
        final json =
            jsonDecode(await _userFile.readAsString()) as Map<String, dynamic>;
        _folders = (json['folders'] as List).cast<String>().toList();
        _hiddenPaths.addAll((json['hiddenPaths'] as List? ?? []).cast());
        _excludedFolders =
            (json['excludedFolders'] as List?)?.cast<String>().toList() ??
            await _defaultExcludedFolders();
        _minDurationSec = json['minDurationSec'] as int? ?? 30;
        if (json['foldersVersion'] != _foldersVersion) {
          await _migrateToWholeDevice();
        }
        _favorites.addAll((json['favorites'] as List).cast<String>());
        _playlists.addAll([
          for (final j in json['playlists'] as List) Playlist.fromJson(j),
        ]);
      }
      _applyFilters();
    } catch (e) {
      debugPrint('Failed to load library: $e');
    } finally {
      _ready.complete();
      _changed();
    }
  }

  Future<void> _saveUser() => _userFile.writeAsString(
    jsonEncode({
      'foldersVersion': _foldersVersion,
      'folders': _folders,
      'hiddenPaths': _hiddenPaths.toList(),
      'excludedFolders': _excludedFolders,
      'minDurationSec': _minDurationSec,
      'favorites': _favorites.toList(),
      'playlists': [for (final pl in _playlists) pl.toJson()],
    }),
  );

  Future<void> _saveTracks() => _tracksFile.writeAsString(
    jsonEncode({'version': scannerVersion, 'tracks': _allTracks}),
  );

  void _applyFilters() {
    final minMs = _minDurationSec * 1000;
    final excluded = [
      for (final f in _excludedFolders) f.endsWith('/') ? f : '$f/',
    ];
    _tracks = _allTracks
        .where(
          (t) =>
              !_hiddenPaths.contains(t.path) &&
              !(t.durationMs > 0 && t.durationMs < minMs) &&
              !excluded.any(t.path.startsWith),
        )
        .toList();
    _byId = {for (final t in _tracks) t.id: t};
    _albums = null;
    _artists = null;
  }

  void _changed() {
    revision++;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Folders & scanning

  /// Requests audio/storage read access. Returns true if granted.
  static Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    final statuses = await [Permission.audio, Permission.storage].request();
    return statuses.values.any((s) => s.isGranted || s.isLimited);
  }

  /// Bump to re-run [_migrateToWholeDevice] for existing installs.
  static const _foldersVersion = 2;

  /// Every storage volume: internal storage plus SD cards / USB drives.
  static Future<List<String>> storageRoots() async {
    if (!Platform.isAndroid) {
      return [(await getApplicationDocumentsDirectory()).path];
    }
    final roots = <String>[];
    if (await Directory('/storage/emulated/0').exists()) {
      roots.add('/storage/emulated/0');
    }
    try {
      await for (final e in Directory('/storage').list()) {
        final name = p.basename(e.path);
        if (e is Directory && name != 'emulated' && name != 'self') {
          roots.add(e.path);
        }
      }
    } catch (_) {
      // /storage isn't listable on some devices; internal storage is enough.
    }
    return roots;
  }

  /// Folders that are almost never music. Users can restore any of them.
  static Future<List<String>> _defaultExcludedFolders() async {
    if (!Platform.isAndroid) return [];
    const root = '/storage/emulated/0';
    return [
      '$root/Ringtones',
      '$root/Notifications',
      '$root/Alarms',
      '$root/Recordings',
      '$root/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Voice Notes',
    ];
  }

  /// Older versions defaulted to just Music + Download; scan the whole device
  /// instead, keeping any folders the user added themselves.
  Future<void> _migrateToWholeDevice() async {
    const oldDefaults = {
      '/storage/emulated/0/Music',
      '/storage/emulated/0/Download',
    };
    final custom = _folders.where((f) => !oldDefaults.contains(f));
    final roots = await storageRoots();
    _folders = [
      ...roots,
      ...custom.where((f) => !roots.any((r) => p.isWithin(r, f) || r == f)),
    ];
    await _saveUser();
  }

  /// On first launch, scan every storage volume on the device.
  Future<void> addDefaultFolderIfEmpty() async {
    if (_folders.isNotEmpty) return;
    _folders = await storageRoots();
    _excludedFolders = await _defaultExcludedFolders();
    if (_folders.isEmpty) return;
    await _saveUser();
    await rescan();
  }

  Future<void> addFolder(String path) async {
    if (_folders.contains(path)) return;
    _folders.add(path);
    await _saveUser();
    await rescan();
  }

  Future<void> removeFolder(String path) async {
    _folders.remove(path);
    await _saveUser();
    await rescan();
  }

  Future<void> rescan() async {
    if (_scanning) return;
    _scanning = true;
    notifyListeners();
    try {
      final tracks = await scanFolders(
        folders: _folders,
        previous: _forceFullScan ? const [] : _tracks,
        artDir: p.join(_dataDir.path, 'artwork'),
      );
      _allTracks = tracks;
      _applyFilters();
      _forceFullScan = false;
      await _saveTracks();
    } catch (e) {
      debugPrint('Scan failed: $e');
    } finally {
      _scanning = false;
      _changed();
    }
  }

  // ---------------------------------------------------------------------------
  // Hiding songs & folders (reversible; nothing is deleted from the device)

  Future<void> hideTrack(Track track) => _updateFilters(() {
    _hiddenPaths.add(track.path);
  });

  Future<void> unhideTrack(Track track) => _updateFilters(() {
    _hiddenPaths.remove(track.path);
  });

  Future<void> excludeFolder(String folder) => _updateFilters(() {
    if (!_excludedFolders.contains(folder)) _excludedFolders.add(folder);
  });

  Future<void> includeFolder(String folder) => _updateFilters(() {
    _excludedFolders.remove(folder);
  });

  Future<void> setMinDuration(int seconds) => _updateFilters(() {
    _minDurationSec = seconds;
  });

  /// Number of visible songs inside [folder] (for confirmation prompts).
  int countInFolder(String folder) {
    final prefix = folder.endsWith('/') ? folder : '$folder/';
    return _tracks.where((t) => t.path.startsWith(prefix)).length;
  }

  Future<void> _updateFilters(void Function() change) async {
    change();
    _applyFilters();
    _changed();
    await _saveUser();
  }

  // ---------------------------------------------------------------------------
  // Deleting songs from the device (permanent)

  /// Deletes [track]'s file and forgets it everywhere (favourites,
  /// playlists, hidden list). Returns false if nothing was deleted.
  Future<bool> deleteTrack(Track track) async =>
      (await deleteTracks([track])).isNotEmpty;

  /// Deletes the files of [tracks] and forgets them everywhere (favourites,
  /// playlists, hidden list). Returns the ones actually deleted.
  Future<List<Track>> deleteTracks(List<Track> tracks) async {
    final gone = (await FileDeleter.deleteAll([
      for (final t in tracks) t.path,
    ])).toSet();
    final deleted = [
      for (final t in tracks)
        if (gone.contains(t.path)) t,
    ];
    if (deleted.isEmpty) return deleted;

    final paths = {for (final t in deleted) t.path};
    final ids = {for (final t in deleted) t.id};
    _allTracks = _allTracks.where((t) => !paths.contains(t.path)).toList();
    _hiddenPaths.removeAll(paths);
    _favorites.removeAll(ids);
    for (final pl in _playlists) {
      pl.trackIds.removeWhere(ids.contains);
    }
    _applyFilters();
    _changed();

    // Album art is shared per album; drop it once nothing uses it.
    final used = {for (final t in _allTracks) t.artPath};
    for (final art in {for (final t in deleted) t.artPath}.nonNulls) {
      if (used.contains(art)) continue;
      try {
        await File(art).delete();
      } catch (_) {}
    }
    await Future.wait([_saveTracks(), _saveUser()]);
    return deleted;
  }

  // ---------------------------------------------------------------------------
  // Favourites

  Future<void> toggleFavorite(String trackId) async {
    if (!_favorites.remove(trackId)) _favorites.add(trackId);
    _changed();
    await _saveUser();
  }

  // ---------------------------------------------------------------------------
  // Playlists

  Future<Playlist> createPlaylist(String name) async {
    final playlist = Playlist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
    );
    _playlists.add(playlist);
    _changed();
    await _saveUser();
    return playlist;
  }

  Future<void> renamePlaylist(Playlist playlist, String name) async {
    playlist.name = name;
    _changed();
    await _saveUser();
  }

  Future<void> deletePlaylist(Playlist playlist) async {
    _playlists.remove(playlist);
    _changed();
    await _saveUser();
  }

  Future<void> addToPlaylist(Playlist playlist, List<String> trackIds) async {
    playlist.trackIds.addAll(trackIds);
    _changed();
    await _saveUser();
  }

  /// [index] is a position in [playlistTracks], which skips ids whose files
  /// have disappeared; dropping those first makes the indices line up.
  Future<void> removeFromPlaylist(Playlist playlist, int index) async {
    playlist.trackIds.retainWhere(_byId.containsKey);
    if (index < 0 || index >= playlist.trackIds.length) return;
    playlist.trackIds.removeAt(index);
    _changed();
    await _saveUser();
  }

  Future<void> reorderPlaylist(Playlist playlist, int from, int to) async {
    // Drop dangling ids first so visible indices match stored ones.
    playlist.trackIds.retainWhere(_byId.containsKey);
    if (to > from) to--;
    final id = playlist.trackIds.removeAt(from);
    playlist.trackIds.insert(to, id);
    _changed();
    await _saveUser();
  }
}
