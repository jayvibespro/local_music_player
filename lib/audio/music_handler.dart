import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show debugPrint, immutable, listEquals;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../models/track.dart';
import '../services/music_library.dart';
import '../services/play_history.dart';
import '../services/playback_store.dart';
import '../services/settings.dart';
import '../services/voice_match.dart';
import '../services/waveforms.dart';
import 'eq_presets.dart';
import 'equalizer.dart';
import 'loudness.dart';

/// Browse-tree ids shared by the in-app UI and Android Auto.
abstract final class BrowseIds {
  static const home = 'cat/home';
  static const songs = 'cat/songs';
  static const favorites = 'cat/favorites';
  static const playlists = 'cat/playlists';
  static const albums = 'cat/albums';
  static const artists = 'cat/artists';
  static const recent = 'cat/recent';
  static const mostPlayed = 'cat/most';
  static const recentlyAdded = 'cat/added';

  /// Playable: favourites + most played, shuffled.
  static const drivingMix = 'mix/drive';
  static const albumPrefix = 'album/';
  static const artistPrefix = 'artist/';
  static const playlistPrefix = 'playlist/';
  static const shufflePrefix = 'shuffle|';
  static const separator = '|';

  /// A playable item's id is `<parentId>|<trackId>`; track ids are hex so the
  /// last separator always splits correctly.
  static String trackItem(String parentId, String trackId) =>
      '$parentId$separator$trackId';
}

const _favoriteAction = 'toggleFavorite';
const _shuffleAction = 'toggleShuffle';
const _repeatAction = 'cycleRepeat';

// Android Auto content-style hints (androidx.media.utils.MediaConstants).
const _browsableHint = 'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT';
const _playableHint = 'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT';
const _groupTitle = 'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT';
const _list = 1;
const _grid = 2;

/// The queue in the order it will actually play (follows shuffle).
@immutable
class PlayOrder {
  const PlayOrder({
    required this.indices,
    required this.trackIds,
    required this.position,
  });

  static const empty = PlayOrder(indices: [], trackIds: [], position: 0);

  /// Queue indices in play order.
  final List<int> indices;

  /// Track id at each play-order position.
  final List<String> trackIds;

  /// Play-order position of the current song.
  final int position;

  @override
  bool operator ==(Object other) =>
      other is PlayOrder &&
      other.position == position &&
      listEquals(other.indices, indices) &&
      listEquals(other.trackIds, trackIds);

  @override
  int get hashCode => Object.hash(position, Object.hashAll(trackIds));
}

/// An active sleep timer: either at a time, or when the current song ends.
@immutable
class SleepTimer {
  const SleepTimer.at(DateTime this.endsAt) : endOfTrack = false;
  const SleepTimer.endOfTrack() : endsAt = null, endOfTrack = true;

  final DateTime? endsAt;
  final bool endOfTrack;

  Duration? get remaining {
    final end = endsAt;
    if (end == null) return null;
    final left = end.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }
}

class MusicHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  MusicHandler(this.library, this.settings) {
    _player.playbackEventStream.listen((_) => _broadcastState());
    _player.shuffleModeEnabledStream.listen((_) => _broadcastState());
    _player.loopModeStream.listen((_) => _broadcastState());
    _player.currentIndexStream.listen(_onIndexChanged);
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero, index: _player.effectiveIndices.first);
      }
    });
    library.addListener(_onLibraryChanged);
    settings.addListener(_onSettingsChanged);

    // Persist playback so the next launch resumes where the user left off.
    _player.currentIndexStream.listen((_) => _scheduleSave());
    _player.shuffleModeEnabledStream.listen((_) => _scheduleSave());
    _player.loopModeStream.listen((_) => _scheduleSave());
    queue.listen((_) => _scheduleSave());
    _player.playingStream.listen((playing) {
      // Any real resume (user, Auto, headset) supersedes a pending one.
      if (playing) _interrupted = false;
      _updateTransitionTicker();
      _positionSaver?.cancel();
      if (playing) {
        _positionSaver = Timer.periodic(const Duration(seconds: 5), (_) {
          _scheduleSave();
          _maybeCountPlay();
          history.addListening(const Duration(seconds: 5));
        });
      } else {
        saveNow(); // paused: capture the exact position
      }
    });
    // Registered with the binding, which keeps it alive for the app's life.
    AppLifecycleListener(onHide: saveNow, onPause: saveNow, onDetach: saveNow);
    _player.positionDiscontinuityStream.listen((d) {
      if (d.reason != PositionDiscontinuityReason.autoAdvance) return;
      _countedTrackId = null; // a repeat counts as another play
      if (sleepTimer.value?.endOfTrack == true) {
        _player.pause();
        cancelSleepTimer();
      }
    });
    // Android Auto shows this above the queue.
    source.listen(
      (s) => queueTitle.add(s == null ? 'Up next' : 'Playing from ${s.title}'),
    );
    history.load();
    _listenToAudioSession();
    _player.androidAudioSessionIdStream.listen(eq.attachSession);
    eq.init();
    _applyEqualizer();
    _restore();
  }

  final MusicLibrary library;
  final Settings settings;
  final history = PlayHistory();

  /// 10-band equalizer (Android 9+) or the device's built-in one.
  final eq = EqualizerEngine();

  // Interruptions (calls, other apps, unplugged headphones) are handled in
  // [_listenToAudioSession] so playback can resume after a call even while
  // the app is in the background.
  late final _player = AudioPlayer(
    handleInterruptions: false,
    audioPipeline: AudioPipeline(androidAudioEffects: [?eq.legacy]),
  );
  final _childrenChanged = BehaviorSubject<Map<String, dynamic>>.seeded({});
  int _lastRevision = -1;

  final _store = PlaybackStore();
  Timer? _saveDebounce;
  Timer? _positionSaver;
  bool _restoring = true;

  /// Where the current queue came from ("All songs", a playlist, …).
  final source = BehaviorSubject<PlaybackSource?>.seeded(null);

  Stream<Duration> get positionStream => _player.positionStream;

  /// Android audio session of the player (for the visualizer).
  Stream<int?> get audioSessionIdStream => _player.androidAudioSessionIdStream;
  Duration get position => _player.position;
  bool get shuffleEnabled => _player.shuffleModeEnabled;
  LoopMode get loopMode => _player.loopMode;

  String? get currentTrackId => mediaItem.value?.extras?['trackId'] as String?;

  /// The queue in play order, for the swipeable cover carousel.
  PlayOrder get playOrder {
    final sequence = _player.sequence;
    final indices = [
      for (final i in _player.effectiveIndices)
        if (i < sequence.length) i,
    ];
    final current = _player.currentIndex;
    final position = current == null ? 0 : indices.indexOf(current);
    return PlayOrder(
      indices: indices,
      trackIds: [for (final i in indices) sequence[i].tag as String],
      position: position < 0 ? 0 : position,
    );
  }

  Stream<PlayOrder> get playOrderStream =>
      _player.sequenceStateStream.map((_) => playOrder).distinct();

  // ---------------------------------------------------------------------------
  // Audio focus: phone calls, other apps, headphones

  /// Paused by a transient interruption (e.g. a phone call); resume when it
  /// ends.
  bool _interrupted = false;
  bool _ducked = false;

  /// Sleep-timer fade-out multiplier.
  double _fade = 1.0;

  /// Song-transition fade multiplier.
  double _transition = 1.0;
  double _lastVolume = 1.0;

  Future<void> _applyVolume() async {
    final volume = (_ducked ? 0.3 : 1.0) * _fade * _transition * _normalize;
    if ((volume - _lastVolume).abs() < 0.002) return;
    _lastVolume = volume;
    await _player.setVolume(volume);
  }

  Future<void> _listenToAudioSession() async {
    final session = await AudioSession.instance;

    // Optional: carry on when the car's (or any) Bluetooth audio connects.
    session.devicesChangedEventStream.listen((event) {
      if (settings.resumeOnBluetooth &&
          event.devicesAdded.any(
            // ignore: experimental_member_use
            (d) => d.type == AudioDeviceType.bluetoothA2dp,
          )) {
        // Let Android finish routing audio to the new device first.
        Future<void>.delayed(const Duration(seconds: 2), _autoResume);
      }
    });

    // Headphones unplugged / Bluetooth disconnected: pause, don't blast the
    // speaker.
    session.becomingNoisyEventStream.listen((_) {
      _interrupted = false;
      _player.pause();
    });

    session.interruptionEventStream.listen((event) async {
      if (event.begin) {
        switch (event.type) {
          case AudioInterruptionType.duck:
            // Navigation prompts, notification sounds: lower, keep playing.
            _ducked = true;
            await _applyVolume();
          case AudioInterruptionType.pause:
            // Phone/VoIP call, voice assistant: pause and resume afterwards.
            if (_player.playing) {
              // Set before pausing so _broadcastState keeps the service in
              // the foreground. Otherwise Android may kill the app during a
              // long call, or refuse to restart the foreground service from
              // the background when the call ends (Android 12+).
              _interrupted = true;
              await _player.pause();
            }
          case AudioInterruptionType.unknown:
            // Another app took audio focus for good: pause, don't resume.
            _interrupted = false;
            await _player.pause();
        }
      } else {
        if (_ducked) {
          _ducked = false;
          await _applyVolume();
        }
        if (event.type == AudioInterruptionType.pause && _interrupted) {
          // Give the call's audio route a moment to be released.
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (_interrupted) _startPlaying();
        }
        _interrupted = false;
        _broadcastState();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Sleep timer

  final sleepTimer = BehaviorSubject<SleepTimer?>.seeded(null);
  Timer? _sleepTicker;
  static const _fadeOut = Duration(seconds: 15);

  /// Pauses after [duration], fading out over the last few seconds.
  void setSleepTimer(Duration duration) {
    cancelSleepTimer();
    sleepTimer.add(SleepTimer.at(DateTime.now().add(duration)));
    _sleepTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final left = sleepTimer.value?.remaining;
      if (left == null) return;
      if (left == Duration.zero) {
        _player.pause();
        cancelSleepTimer();
      } else if (left < _fadeOut) {
        _fade = left.inMilliseconds / _fadeOut.inMilliseconds;
        _applyVolume();
      }
    });
  }

  /// Pauses when the current song finishes.
  void sleepAtEndOfTrack() {
    cancelSleepTimer();
    sleepTimer.add(const SleepTimer.endOfTrack());
  }

  void cancelSleepTimer() {
    _sleepTicker?.cancel();
    _sleepTicker = null;
    if (sleepTimer.value != null) sleepTimer.add(null);
    if (_fade != 1.0) {
      _fade = 1.0;
      _applyVolume();
    }
  }

  // ---------------------------------------------------------------------------
  // Fading between songs

  Timer? _transitionTicker;

  void _updateTransitionTicker() {
    final active = settings.fadeTransitions && _player.playing;
    if (active) {
      _transitionTicker ??= Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => _tickTransition(),
      );
    } else {
      _transitionTicker?.cancel();
      _transitionTicker = null;
      if (_transition != 1.0) {
        _transition = 1.0;
        _applyVolume();
      }
    }
  }

  /// Fades the last [Settings.fadeSeconds] of a song out and the start of
  /// the next one in. (just_audio plays one song at a time, so this is a
  /// fade through silence rather than an overlapping crossfade.)
  void _tickTransition() {
    final fade = Duration(seconds: settings.fadeSeconds);
    final fadeIn = fade ~/ 2;
    final duration = _player.duration;
    final position = _player.position;
    var gain = 1.0;
    // Skip very short clips, where fading would swallow the whole thing.
    if (duration != null && duration > fade * 3) {
      final left = duration - position;
      if (left < fade) gain = left.inMilliseconds / fade.inMilliseconds;
      if (position < fadeIn) {
        gain = math.min(gain, position.inMilliseconds / fadeIn.inMilliseconds);
      }
    }
    gain = gain.clamp(0.0, 1.0);
    // Squared, so the fade sounds even to the ear rather than dropping off
    // at the very end.
    _transition = gain * gain;
    _applyVolume();
  }

  // ---------------------------------------------------------------------------
  // Equalizer & volume normalisation

  String? _appliedEq;

  /// Saved gains for the device's bands; re-derived from the preset when the
  /// band layout changed (e.g. the 10-band EQ replacing an older 5-band one).
  Future<List<double>> savedEqGains() async {
    final layout = await eq.layout;
    final saved = settings.eqGains;
    if (saved.length == layout.frequencies.length) return [...saved];
    final preset = EqPreset.byId(settings.eqPreset) ?? EqPreset.all.first;
    return gainsForPreset(preset, layout);
  }

  static List<double> gainsForPreset(EqPreset preset, EqLayout layout) => [
    for (final hz in layout.frequencies)
      preset.gainAt(hz).clamp(layout.minDb, layout.maxDb).toDouble(),
  ];

  /// Applies the saved equalizer settings (also called on settings changes).
  Future<void> _applyEqualizer() async {
    if (!eq.available) return;
    final signature =
        '${settings.eqEnabled}${settings.eqGains}${settings.eqPreamp}';
    if (signature == _appliedEq) return;
    _appliedEq = signature;
    await eq.apply(
      enabled: settings.eqEnabled,
      gains: await savedEqGains(),
      preamp: settings.eqPreamp,
    );
  }

  /// Live slider changes; saved to settings separately.
  Future<void> previewEqualizer(List<double> gains, double preamp) {
    _appliedEq = null;
    return eq.apply(enabled: settings.eqEnabled, gains: gains, preamp: preamp);
  }

  /// Normalisation multiplier on the player volume, for devices where the
  /// native gain stage isn't available (can only turn loud songs down).
  double _normalize = 1.0;

  /// Sets the current song's normalisation gain. Songs without ReplayGain
  /// tags use a loudness estimate from their waveform, which is measured in
  /// the background; until it's known the song plays unadjusted (rather
  /// than jumping in volume mid-song).
  Future<void> _applyNormalization() async {
    var gain = 0.0;
    final id = currentTrackId;
    final track = id == null ? null : library.trackById(id);
    if (settings.normalizeVolume && track != null) {
      final rg = track.replayGainDb;
      final lufs = rg == null
          ? await Waveforms.instance.loudness(track.id)
          : null;
      if (currentTrackId != id) return; // moved on meanwhile
      if (rg != null) {
        gain = clampGain(gainFromReplayGain(rg));
      } else if (lufs != null) {
        gain = clampGain(gainFromLufs(lufs));
      }
    }
    if (await eq.setLoudness(gain)) {
      _normalize = 1.0;
    } else {
      _normalize = math.min(1.0, math.pow(10, gain / 20).toDouble());
    }
    await _applyVolume();
    _prefetchLoudness();
  }

  /// Measures the next couple of songs ahead of time.
  void _prefetchLoudness() {
    if (!settings.normalizeVolume) return;
    final order = playOrder;
    for (var i = 1; i <= 2; i++) {
      final at = order.position + i;
      if (at >= order.trackIds.length) break;
      final track = library.trackById(order.trackIds[at]);
      if (track != null && track.replayGainDb == null) {
        Waveforms.instance.load(track.id, track.path);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Play history

  String? _countedTrackId;

  /// Counts a play once a song has played for 30 s (or half of a short one).
  void _maybeCountPlay() {
    final id = currentTrackId;
    if (id == null || id == _countedTrackId) return;
    final duration = _player.duration ?? Duration.zero;
    final needed =
        duration > Duration.zero && duration < const Duration(minutes: 1)
        ? duration ~/ 2
        : const Duration(seconds: 30);
    if (_player.position >= needed) {
      _countedTrackId = id;
      history.record(id);
      _childrenChanged.add({});
    }
  }

  // ---------------------------------------------------------------------------
  // Carrying on in the car

  final _restored = Completer<void>();
  DateTime? _lastRootBrowse;
  DateTime? _lastUserPause;
  DateTime? _lastAutoResume;
  static const _resumeCooldown = Duration(minutes: 10);

  /// Resumes the saved queue, unless the user paused it recently (so it
  /// never fights a deliberate pause).
  Future<void> _autoResume() async {
    await _restored.future;
    if (_player.playing || queue.value.isEmpty) return;
    final now = DateTime.now();
    bool recent(DateTime? t) =>
        t != null && now.difference(t) < _resumeCooldown;
    if (recent(_lastUserPause) || recent(_lastAutoResume)) return;
    _lastAutoResume = now;
    _startPlaying();
  }

  void _onIndexChanged(int? index) {
    final items = queue.value;
    if (index != null && index < items.length) {
      if (items[index].extras?['trackId'] != currentTrackId) {
        _countedTrackId = null;
      }
      final changed = items[index].extras?['trackId'] != currentTrackId;
      mediaItem.add(items[index]);
      if (changed) _applyNormalization();
    }
    _broadcastState();
  }

  void _onLibraryChanged() {
    // The favourite button depends on library state.
    _broadcastState();
    if (library.revision != _lastRevision) {
      _lastRevision = library.revision;
      _childrenChanged.add({});
    }
  }

  bool? _appliedNormalize;

  void _onSettingsChanged() {
    _updateTransitionTicker();
    _applyEqualizer();
    if (settings.normalizeVolume != _appliedNormalize) {
      _appliedNormalize = settings.normalizeVolume;
      _applyNormalization();
    }
    final sort =
        '${settings.songSort}${settings.songDescending}'
        '${settings.albumSort}${settings.albumDescending}'
        '${settings.artistSort}${settings.artistDescending}';
    if (sort == _appliedSort) return;
    _appliedSort = sort;
    _sortCache.clear();
    _childrenChanged.add({});
  }

  String? _appliedSort;

  // Sorted views are cached until the library or sort settings change.
  final _sortCache = <String, Object>{};
  int _sortCacheRevision = -1;

  T _cached<T extends Object>(String key, T Function() build) {
    if (_sortCacheRevision != library.revision) {
      _sortCache.clear();
      _sortCacheRevision = library.revision;
    }
    return _sortCache.putIfAbsent(key, build) as T;
  }

  List<Track> get sortedSongs =>
      _cached('songs', () => settings.sortSongs(library.tracks));

  List<Track> get sortedFavorites =>
      _cached('favorites', () => settings.sortSongs(library.favorites));

  List<MapEntry<String, List<Track>>> get sortedAlbums =>
      _cached('albums', () => settings.sortAlbums(library.albums));

  List<MapEntry<String, List<Track>>> get sortedArtists =>
      _cached('artists', () => settings.sortArtists(library.artists));

  void _broadcastState() {
    // While a call has paused us, still report "playing" so audio_service
    // keeps the foreground service (and our process) alive and the resume
    // after the call is allowed from the background. Pressing pause in the
    // meantime cancels the resume.
    final playing = _player.playing || _interrupted;
    final trackId = currentTrackId;
    final favorite = trackId != null && library.isFavorite(trackId);
    final loop = _player.loopMode;

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.custom(
            androidIcon: favorite
                ? 'drawable/ic_favorite'
                : 'drawable/ic_favorite_border',
            label: favorite ? 'Remove from favourites' : 'Add to favourites',
            name: _favoriteAction,
          ),
          MediaControl.custom(
            androidIcon: _player.shuffleModeEnabled
                ? 'drawable/ic_shuffle'
                : 'drawable/ic_shuffle_off',
            label: _player.shuffleModeEnabled ? 'Shuffle on' : 'Shuffle off',
            name: _shuffleAction,
          ),
          MediaControl.custom(
            androidIcon: switch (loop) {
              LoopMode.off => 'drawable/ic_repeat_off',
              LoopMode.all => 'drawable/ic_repeat',
              LoopMode.one => 'drawable/ic_repeat_one',
            },
            label: switch (loop) {
              LoopMode.off => 'Repeat off',
              LoopMode.all => 'Repeat all',
              LoopMode.one => 'Repeat one',
            },
            name: _repeatAction,
          ),
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.playFromMediaId,
          MediaAction.playFromSearch,
          MediaAction.skipToQueueItem,
          MediaAction.setShuffleMode,
          MediaAction.setRepeatMode,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: const {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[_player.processingState]!,
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _player.currentIndex,
        shuffleMode: _player.shuffleModeEnabled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        repeatMode: switch (loop) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.all => AudioServiceRepeatMode.all,
          LoopMode.one => AudioServiceRepeatMode.one,
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Queue management (used by the app UI)

  Future<void> playTracks(
    List<Track> tracks, {
    int index = 0,
    bool shuffle = false,
    PlaybackSource? from,
  }) async {
    if (tracks.isEmpty) return;
    _restoring = false; // a user choice always wins over a pending restore
    source.add(from);
    queue.add([for (final t in tracks) t.toMediaItem()]);
    await _player.setShuffleModeEnabled(shuffle);
    await _player.setAudioSources([
      for (final t in tracks) AudioSource.file(t.path, tag: t.id),
    ], initialIndex: index);
    if (shuffle) {
      await _player.shuffle();
      await _player.seek(Duration.zero, index: _player.effectiveIndices.first);
    }
    _startPlaying();
  }

  // The queue is updated before the player in the methods below: the player
  // reports the new current index straight away, and [_onIndexChanged] must
  // look it up in the updated queue.

  /// Inserts [tracks] right after the current song. Returns the queue index
  /// of the first one (for undo).
  Future<int> playNextAll(List<Track> tracks) async {
    if (tracks.isEmpty) return -1;
    if (queue.value.isEmpty) {
      await playTracks(tracks);
      return 0;
    }
    final at = (_player.currentIndex ?? -1) + 1;
    queue.add(
      [...queue.value]
        ..insertAll(at, [for (final t in tracks) t.toMediaItem()]),
    );
    await _player.insertAudioSources(at, [
      for (final t in tracks) AudioSource.file(t.path, tag: t.id),
    ]);
    return at;
  }

  Future<int> playNext(Track track) => playNextAll([track]);

  /// Appends [tracks] to the queue. Returns the queue index of the first.
  Future<int> addAllToQueue(List<Track> tracks) async {
    if (tracks.isEmpty) return -1;
    if (queue.value.isEmpty) {
      await playTracks(tracks);
      return 0;
    }
    final at = queue.value.length;
    queue.add([...queue.value, for (final t in tracks) t.toMediaItem()]);
    await _player.addAudioSources([
      for (final t in tracks) AudioSource.file(t.path, tag: t.id),
    ]);
    return at;
  }

  Future<int> addToQueue(Track track) => addAllToQueue([track]);

  /// Undo for [playNextAll]/[addAllToQueue]: removes [count] entries at
  /// [index] if they are still [trackIds] (the queue may have changed).
  Future<void> undoQueueInsert(int index, List<String> trackIds) async {
    final seq = _player.sequence;
    if (index < 0 || index + trackIds.length > seq.length) return;
    for (var i = 0; i < trackIds.length; i++) {
      if (seq[index + i].tag != trackIds[i]) return;
    }
    if (trackIds.length == seq.length) return; // never empty the queue
    for (var i = trackIds.length - 1; i >= 0; i--) {
      if (index + i == _player.currentIndex) continue;
      await removeQueueItemAt(index + i);
    }
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    queue.add([...queue.value]..removeAt(index));
    await _player.removeAudioSourceAt(index);
  }

  Future<void> moveQueueItem(int from, int to) async {
    final items = [...queue.value];
    items.insert(to, items.removeAt(from));
    queue.add(items);
    await _player.moveAudioSource(from, to);
  }

  /// Removes every queue entry for [trackId] (e.g. after the file was
  /// deleted). If it is the current song, playback moves on to the next one.
  Future<void> removeTrack(String trackId) async {
    final sequence = _player.sequence;
    final matches = {
      for (var i = 0; i < sequence.length; i++)
        if (sequence[i].tag == trackId) i,
    };
    history.forget(trackId);
    if (matches.isEmpty) return;

    if (matches.length == sequence.length) {
      _restoring = false;
      await _player.stop();
      queue.add(const []);
      await _player.clearAudioSources();
      mediaItem.add(null);
      source.add(null);
      _broadcastState();
      return;
    }

    final current = _player.currentIndex;
    if (current != null && matches.contains(current)) {
      // Next song in play order that isn't being removed, wrapping around.
      final order = _player.effectiveIndices;
      final at = order.indexOf(current);
      final next = [
        ...order.skip(at + 1),
        ...order.take(at),
      ].firstWhere((i) => !matches.contains(i));
      await _player.seek(Duration.zero, index: next);
    }
    for (final i in matches.toList()..sort((a, b) => b.compareTo(a))) {
      await removeQueueItemAt(i);
    }
  }

  /// Jumps to a queue index without changing play/pause (cover swipes).
  Future<void> skipToIndex(int index) async {
    if (index < 0 || index >= _player.sequence.length) return;
    await _player.seek(Duration.zero, index: index);
  }

  // ---------------------------------------------------------------------------
  // Transport controls (UI, notification, headset, Android Auto)

  @override
  Future<void> play() async => _startPlaying();

  /// Starts playback without waiting for it. just_audio's `play()` future
  /// only completes when playback *stops*, so awaiting it would hang the
  /// caller (e.g. the voice sheet) for the whole song.
  void _startPlaying() {
    _player.play().catchError((Object e) {
      debugPrint('Playback failed: $e');
    });
  }

  @override
  Future<void> pause() async {
    // A user pause during a call means "stay paused afterwards".
    final wasInterrupted = _interrupted;
    _interrupted = false;
    _lastUserPause = DateTime.now();
    await _player.pause();
    if (wasInterrupted) _broadcastState();
  }

  @override
  Future<void> stop() async {
    _interrupted = false;
    cancelSleepTimer();
    await saveNow();
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() async {
    if (_player.position > const Duration(seconds: 3) || !_player.hasPrevious) {
      await _player.seek(Duration.zero);
    } else {
      await _player.seekToPrevious();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= queue.value.length) return;
    await _player.seek(Duration.zero, index: index);
    if (!_player.playing) _startPlaying();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode != AudioServiceShuffleMode.none;
    if (enabled) await _player.shuffle();
    await _player.setShuffleModeEnabled(enabled);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      _player.setLoopMode(switch (repeatMode) {
        AudioServiceRepeatMode.none => LoopMode.off,
        AudioServiceRepeatMode.one => LoopMode.one,
        AudioServiceRepeatMode.all ||
        AudioServiceRepeatMode.group => LoopMode.all,
      });

  Future<void> toggleShuffle() => setShuffleMode(
    _player.shuffleModeEnabled
        ? AudioServiceShuffleMode.none
        : AudioServiceShuffleMode.all,
  );

  Future<void> cycleRepeat() => _player.setLoopMode(switch (_player.loopMode) {
    LoopMode.off => LoopMode.all,
    LoopMode.all => LoopMode.one,
    LoopMode.one => LoopMode.off,
  });

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    switch (name) {
      case _favoriteAction:
        final id = currentTrackId;
        if (id != null) await library.toggleFavorite(id);
      case _shuffleAction:
        await toggleShuffle();
      case _repeatAction:
        await cycleRepeat();
    }
  }

  @override
  Future<void> onTaskRemoved() => stop();

  // ---------------------------------------------------------------------------
  // Saving & restoring playback

  void _scheduleSave() {
    if (_restoring) return;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), saveNow);
  }

  Future<void> saveNow() async {
    if (_restoring) return;
    _saveDebounce?.cancel();
    final ids = [
      for (final item in queue.value) item.extras?['trackId'] as String? ?? '',
    ];
    // Never replace a resumable session with an empty one.
    if (ids.isEmpty) return;
    await _store.save(
      PlaybackSnapshot(
        trackIds: ids,
        index: _player.currentIndex ?? 0,
        position: _player.position,
        shuffle: _player.shuffleModeEnabled,
        shuffleIndices: _player.shuffleIndices,
        loopMode: _player.loopMode,
        source: source.value,
      ),
    );
  }

  /// Reloads the last queue, song, position, shuffle order and repeat mode,
  /// paused, so pressing play continues exactly where the user left off.
  Future<void> _restore() async {
    try {
      final snapshot = await _store.load();
      await library.ready;
      if (!_restoring || snapshot == null || snapshot.trackIds.isEmpty) return;

      final tracks = [
        for (final id in snapshot.trackIds) library.trackById(id),
      ];
      final available = tracks.nonNulls.toList();
      if (available.isEmpty) return;

      // If songs were deleted or hidden since, indices shift: keep the
      // current song if possible and let the shuffle order be regenerated.
      final complete = available.length == tracks.length;
      final savedCurrent = snapshot.index < tracks.length
          ? tracks[snapshot.index]
          : null;
      final index = complete
          ? snapshot.index.clamp(0, available.length - 1)
          : savedCurrent == null
          ? 0
          : available.indexOf(savedCurrent);
      final position = complete || savedCurrent != null
          ? snapshot.position
          : Duration.zero;

      source.add(snapshot.source);
      queue.add([for (final t in available) t.toMediaItem()]);
      await _player.setLoopMode(snapshot.loopMode);
      await _player.setShuffleModeEnabled(snapshot.shuffle);
      await _player.setAudioSources(
        [for (final t in available) AudioSource.file(t.path, tag: t.id)],
        initialIndex: index,
        initialPosition: position,
        shuffleOrder: RestoredShuffleOrder(
          complete ? snapshot.shuffleIndices : const [],
        ),
      );
    } catch (e) {
      // A missing or unreadable file shouldn't stop the app starting.
    } finally {
      _restoring = false;
      _restored.complete();
    }
  }

  // ---------------------------------------------------------------------------
  // Android Auto / media browser
  //
  // Auto shows the root's children as (at most four) tabs:
  //   Home      – driving mix, shuffle all, recently played, most played,
  //               recently added, favourites, all songs
  //   Albums    – grid of covers
  //   Artists   – grid of covers
  //   Playlists – list

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) =>
      _childrenChanged;

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    await Future.wait([library.ready, history.ready]);
    switch (parentMediaId) {
      case AudioService.browsableRootId:
        _onCarConnected();
        return [
          _category(BrowseIds.home, 'Home', 'ic_home', children: _list),
          _category(BrowseIds.albums, 'Albums', 'ic_album', children: _grid),
          _category(BrowseIds.artists, 'Artists', 'ic_person', children: _grid),
          _category(
            BrowseIds.playlists,
            'Playlists',
            'ic_queue_music',
            children: _list,
          ),
        ];
      case AudioService.recentRootId:
        final current = mediaItem.value;
        return current == null ? [] : [current];
      case BrowseIds.home:
        return _home();
      case BrowseIds.albums:
        return [
          for (final MapEntry(key: album, value: tracks) in sortedAlbums)
            _album(album, tracks),
        ];
      case BrowseIds.artists:
        return [
          for (final MapEntry(key: artist, value: tracks) in sortedArtists)
            _artist(artist, tracks),
        ];
      case BrowseIds.playlists:
        return [for (final pl in library.playlists) _playlist(pl.id, pl.name)];
    }

    final tracks = tracksFor(parentMediaId);
    return [
      if (tracks.length > 1)
        MediaItem(
          id: '${BrowseIds.shufflePrefix}$parentMediaId',
          title: 'Shuffle all',
          artUri: _iconUri('ic_shuffle'),
          playable: true,
        ),
      for (final t in tracks)
        t.toMediaItem(mediaId: BrowseIds.trackItem(parentMediaId, t.id)),
    ];
  }

  List<MediaItem> _home() {
    const drive = {_groupTitle: 'Start driving'};
    const yours = {_groupTitle: 'Your music'};
    MediaItem list(String id, String title, String icon, int count) =>
        MediaItem(
          id: id,
          title: title,
          displaySubtitle: '$count songs',
          artUri: _iconUri(icon),
          playable: false,
          extras: {...yours, _playableHint: _list},
        );

    final recent = tracksFor(BrowseIds.recent).length;
    final most = tracksFor(BrowseIds.mostPlayed).length;
    final favourites = sortedFavorites.length;
    return [
      MediaItem(
        id: BrowseIds.drivingMix,
        title: 'Driving mix',
        displaySubtitle: 'Favourites and most played, shuffled',
        artUri: _iconUri('ic_car'),
        playable: true,
        extras: drive,
      ),
      MediaItem(
        id: '${BrowseIds.shufflePrefix}${BrowseIds.songs}',
        title: 'Shuffle all songs',
        displaySubtitle: '${library.tracks.length} songs',
        artUri: _iconUri('ic_shuffle'),
        playable: true,
        extras: drive,
      ),
      if (recent > 0)
        list(BrowseIds.recent, 'Recently played', 'ic_history', recent),
      if (most > 0)
        list(BrowseIds.mostPlayed, 'Most played', 'ic_trending_up', most),
      list(
        BrowseIds.recentlyAdded,
        'Recently added',
        'ic_library_add',
        tracksFor(BrowseIds.recentlyAdded).length,
      ),
      if (favourites > 0)
        list(BrowseIds.favorites, 'Favourites', 'ic_favorite', favourites),
      list(
        BrowseIds.songs,
        'All songs',
        'ic_music_note',
        library.tracks.length,
      ),
    ];
  }

  MediaItem _album(String album, List<Track> tracks, {String? group}) =>
      MediaItem(
        id: '${BrowseIds.albumPrefix}$album',
        title: album,
        artist: tracks.first.artist,
        displaySubtitle: tracks.first.artist,
        artUri: _artFor(tracks),
        playable: false,
        extras: {_playableHint: _list, _groupTitle: ?group},
      );

  MediaItem _artist(String artist, List<Track> tracks, {String? group}) =>
      MediaItem(
        id: '${BrowseIds.artistPrefix}$artist',
        title: artist,
        displaySubtitle: '${tracks.length} songs',
        artUri: _artFor(tracks),
        playable: false,
        extras: {_playableHint: _list, _groupTitle: ?group},
      );

  MediaItem _playlist(String id, String name, {String? group}) {
    final tracks = tracksFor('${BrowseIds.playlistPrefix}$id');
    return MediaItem(
      id: '${BrowseIds.playlistPrefix}$id',
      title: name,
      displaySubtitle: '${tracks.length} songs',
      artUri: _artFor(tracks) ?? _iconUri('ic_queue_music'),
      playable: false,
      extras: {_playableHint: _list, _groupTitle: ?group},
    );
  }

  /// The first cover among [tracks].
  Uri? _artFor(List<Track> tracks) {
    for (final t in tracks) {
      if (t.artPath != null) return artUriFor(t.artPath);
    }
    return null;
  }

  /// Auto asks for the root once per connection: carry on where the user
  /// left off (if enabled). Repeated root requests during a drive are
  /// ignored.
  void _onCarConnected() {
    final now = DateTime.now();
    final last = _lastRootBrowse;
    _lastRootBrowse = now;
    if (settings.autoPlayInCar &&
        (last == null || now.difference(last) > _resumeCooldown)) {
      _autoResume();
    }
  }

  /// Tracks belonging to a browsable list id, in play order.
  List<Track> tracksFor(String parentId) {
    switch (parentId) {
      case BrowseIds.songs:
        return sortedSongs;
      case BrowseIds.favorites:
        return sortedFavorites;
      case BrowseIds.recent:
        return [for (final id in history.recent) ?library.trackById(id)];
      case BrowseIds.mostPlayed:
        return [for (final id in history.mostPlayed()) ?library.trackById(id)];
      case BrowseIds.recentlyAdded:
        return _cached(
          'added',
          () =>
              ([...library.tracks]
                    ..sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs)))
                  .take(50)
                  .toList(),
        );
      case BrowseIds.drivingMix:
        return _drivingMix();
    }
    if (parentId.startsWith(BrowseIds.albumPrefix)) {
      return library.albums[parentId.substring(BrowseIds.albumPrefix.length)] ??
          [];
    }
    if (parentId.startsWith(BrowseIds.artistPrefix)) {
      return library.artists[parentId.substring(
            BrowseIds.artistPrefix.length,
          )] ??
          [];
    }
    if (parentId.startsWith(BrowseIds.playlistPrefix)) {
      final pl = library.playlistById(
        parentId.substring(BrowseIds.playlistPrefix.length),
      );
      return pl == null ? [] : library.playlistTracks(pl);
    }
    return [];
  }

  /// Favourites and most played; topped up with recent plays and then the
  /// rest of the library so there's always enough for a drive.
  List<Track> _drivingMix() {
    const target = 100;
    final seen = <String>{};
    final mix = <Track>[];
    void add(Iterable<Track> tracks) {
      for (final t in tracks) {
        if (mix.length >= target) return;
        if (seen.add(t.id)) mix.add(t);
      }
    }

    add(library.favorites);
    add(tracksFor(BrowseIds.mostPlayed));
    add(tracksFor(BrowseIds.recent));
    if (mix.length < 30) add([...library.tracks]..shuffle());
    return mix;
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    await library.ready;
    final sep = mediaId.lastIndexOf(BrowseIds.separator);
    final track = library.trackById(
      sep < 0 ? mediaId : mediaId.substring(sep + 1),
    );
    return track?.toMediaItem(mediaId: mediaId);
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    await Future.wait([library.ready, history.ready]);
    if (mediaId == BrowseIds.drivingMix) {
      return playTracks(
        tracksFor(mediaId),
        shuffle: true,
        from: sourceFor(mediaId),
      );
    }
    if (mediaId.startsWith(BrowseIds.shufflePrefix)) {
      final parent = mediaId.substring(BrowseIds.shufflePrefix.length);
      return playTracks(
        tracksFor(parent),
        shuffle: true,
        from: sourceFor(parent),
      );
    }
    final sep = mediaId.lastIndexOf(BrowseIds.separator);
    if (sep < 0) {
      // A browsable item played directly (e.g. an album from search).
      final tracks = tracksFor(mediaId);
      if (tracks.isNotEmpty) {
        return playTracks(tracks, from: sourceFor(mediaId));
      }
      final track = library.trackById(mediaId);
      if (track != null) await playTracks([track]);
      return;
    }
    final parent = mediaId.substring(0, sep);
    final tracks = tracksFor(parent);
    final trackId = mediaId.substring(sep + 1);
    final index = tracks.indexWhere((t) => t.id == trackId);
    if (index >= 0) {
      await playTracks(tracks, index: index, from: sourceFor(parent));
    }
  }

  /// Display name for a browse list id.
  PlaybackSource? sourceFor(String parentId) {
    final title = switch (parentId) {
      BrowseIds.songs => 'All songs',
      BrowseIds.favorites => 'Favourites',
      BrowseIds.recent => 'Recently played',
      BrowseIds.mostPlayed => 'Most played',
      BrowseIds.recentlyAdded => 'Recently added',
      BrowseIds.drivingMix => 'Driving mix',
      _ when parentId.startsWith(BrowseIds.albumPrefix) => parentId.substring(
        BrowseIds.albumPrefix.length,
      ),
      _ when parentId.startsWith(BrowseIds.artistPrefix) => parentId.substring(
        BrowseIds.artistPrefix.length,
      ),
      _ when parentId.startsWith(BrowseIds.playlistPrefix) =>
        library
            .playlistById(parentId.substring(BrowseIds.playlistPrefix.length))
            ?.name,
      _ => null,
    };
    return title == null ? null : PlaybackSource(parentId, title);
  }

  /// Search in Auto: results grouped into Artists, Albums, Playlists and
  /// Songs.
  @override
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    await library.ready;
    List<T> matching<T>(Iterable<T> items, String Function(T) name) {
      final scored = [
        for (final item in items)
          if (similarity(query, name(item)) case final s
              when s >= matchThreshold)
            (item, s),
      ]..sort((a, b) => b.$2.compareTo(a.$2));
      return [for (final (item, _) in scored.take(5)) item];
    }

    final artists = matching(library.artists.entries, (e) => e.key);
    final albums = matching(library.albums.entries, (e) => e.key);
    final playlists = matching(library.playlists, (p) => p.name);
    var songs = library.search(query);
    if (songs.isEmpty) {
      songs = matching(library.tracks, (t) => t.title);
    }
    return [
      for (final e in artists) _artist(e.key, e.value, group: 'Artists'),
      for (final e in albums) _album(e.key, e.value, group: 'Albums'),
      for (final pl in playlists) _playlist(pl.id, pl.name, group: 'Playlists'),
      for (final t in songs.take(40))
        _inGroup(
          t.toMediaItem(mediaId: BrowseIds.trackItem(BrowseIds.songs, t.id)),
          'Songs',
        ),
    ];
  }

  /// Voice requests: "play Coldplay", "shuffle my favourites", "play the
  /// album Parachutes", "play my driving mix", "play Yelow" (mis-heard).
  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) =>
      playRequest(query, extras);

  /// Plays what [query] asks for and describes it ("Coldplay", "Favourites
  /// (shuffled)"), or returns null when nothing matched.
  Future<String?> playRequest(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    await Future.wait([library.ready, history.ready]);
    final request = parseVoiceQuery(query);
    final shuffle = request.shuffle;

    if (request.collection case final collection?) {
      final id = switch (collection) {
        VoiceCollection.everything => BrowseIds.songs,
        VoiceCollection.favorites => BrowseIds.favorites,
        VoiceCollection.mix => BrowseIds.drivingMix,
        VoiceCollection.recent => BrowseIds.recent,
        VoiceCollection.mostPlayed => BrowseIds.mostPlayed,
        VoiceCollection.added => BrowseIds.recentlyAdded,
      };
      final tracks = tracksFor(id);
      final from = sourceFor(tracks.isEmpty ? BrowseIds.songs : id);
      await playTracks(
        tracks.isEmpty ? library.tracks : tracks,
        shuffle: shuffle,
        from: from,
      );
      return '${from?.title ?? 'Your music'}${shuffle ? ' (shuffled)' : ''}';
    }

    // The Assistant often says what was asked for and fills in the parts.
    String? extra(String key) {
      final v = extras?['android.intent.extra.$key'];
      return v is String && v.trim().isNotEmpty ? v : null;
    }

    final focus = extras?['android.intent.extra.focus'] as String? ?? '';
    final kind = switch (focus) {
      'vnd.android.cursor.item/artist' => VoiceKind.artist,
      'vnd.android.cursor.item/album' => VoiceKind.album,
      'vnd.android.cursor.item/playlist' => VoiceKind.playlist,
      'vnd.android.cursor.item/audio' => VoiceKind.song,
      _ => request.kind,
    };
    final text = request.text;
    final artistName = extra('artist');

    // Best candidate of each kind. A stated kind gets a strong bonus; when
    // nothing is stated prefer playlist > artist > album > song on ties.
    double bonus(VoiceKind k, double tieBreak) =>
        kind == null ? tieBreak : (kind == k ? 0.2 : -0.1);

    String label(String name) => shuffle ? '$name (shuffled)' : name;
    final hits = <(double, Future<String> Function())>[];

    final pl = bestMatch(
      extra('playlist') ?? text,
      library.playlists,
      (p) => p.name,
    );
    if (pl != null) {
      hits.add((
        pl.score + bonus(VoiceKind.playlist, 0.03),
        () async {
          await playTracks(
            library.playlistTracks(pl.item),
            shuffle: shuffle,
            from: sourceFor('${BrowseIds.playlistPrefix}${pl.item.id}'),
          );
          return label('Playlist "${pl.item.name}"');
        },
      ));
    }
    final artist = bestMatch(
      artistName ?? text,
      library.artists.entries,
      (e) => e.key,
    );
    if (artist != null) {
      hits.add((
        artist.score + bonus(VoiceKind.artist, 0.02),
        () async {
          await playTracks(
            artist.item.value,
            shuffle: shuffle,
            from: sourceFor('${BrowseIds.artistPrefix}${artist.item.key}'),
          );
          return label(artist.item.key);
        },
      ));
    }
    final album = bestMatch(
      extra('album') ?? text,
      library.albums.entries,
      (e) =>
          // "Parachutes by Coldplay"
          artistName != null ? '${e.key} ${e.value.first.artist}' : e.key,
    );
    if (album != null) {
      hits.add((
        album.score + bonus(VoiceKind.album, 0.01),
        () async {
          await playTracks(
            album.item.value,
            shuffle: shuffle,
            from: sourceFor('${BrowseIds.albumPrefix}${album.item.key}'),
          );
          return label('${album.item.key} by ${album.item.value.first.artist}');
        },
      ));
    }
    final song = bestMatch(
      extra('title') ?? text,
      library.tracks,
      (t) => artistName != null ? '${t.title} ${t.artist}' : t.title,
    );
    if (song != null) {
      hits.add((
        song.score + bonus(VoiceKind.song, 0),
        () async {
          // The song, then more by the same artist.
          final artistTracks = library.artists[song.item.artist] ?? [song.item];
          await playTracks(
            artistTracks,
            index: math.max(0, artistTracks.indexOf(song.item)),
            from: sourceFor('${BrowseIds.artistPrefix}${song.item.artist}'),
          );
          return '"${song.item.title}" by ${song.item.artist}';
        },
      ));
    }

    hits.sort((a, b) => b.$1.compareTo(a.$1));
    if (hits.isNotEmpty && hits.first.$1 >= matchThreshold) {
      return hits.first.$2();
    }
    // Nothing confident: fall back to a plain text search.
    final results = library.search(text);
    if (results.isEmpty) return null;
    await playTracks(
      results,
      shuffle: shuffle,
      from: PlaybackSource('search', '"$query"'),
    );
    return label('Songs matching "$text"');
  }

  MediaItem _category(
    String id,
    String title,
    String icon, {
    required int children,
  }) => MediaItem(
    id: id,
    title: title,
    playable: false,
    artUri: _iconUri(icon),
    extras: {_browsableHint: children, _playableHint: _list},
  );

  static MediaItem _inGroup(MediaItem item, String group) =>
      item.copyWith(extras: {...?item.extras, _groupTitle: group});

  Uri _iconUri(String drawable) => Uri.parse(
    'android.resource://com.jacksons.local_music_player/drawable/$drawable',
  );
}
