import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../audio/music_handler.dart';
import '../../services/music_library.dart';
import '../../services/voice_match.dart';

/// Opens the voice command sheet: listens, shows what it heard, does it.
Future<void> showVoiceSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (_) => const _VoiceSheet(),
);

/// Carries out a spoken command. Returns what to tell the user.
Future<String> runVoiceCommand(
  MusicHandler handler,
  MusicLibrary library,
  String transcript,
) async {
  final command = parseVoiceCommand(transcript);
  final item = handler.mediaItem.value;
  switch (command) {
    case PlayCommand(:final query):
      final playing = await handler.playRequest(query);
      return playing == null
          ? 'Couldn\'t find "$query" in your library'
          : 'Playing $playing';
    case TransportCommand(:final action):
      switch (action) {
        case TransportAction.play:
          await handler.play();
          return 'Playing';
        case TransportAction.pause:
          await handler.pause();
          return 'Paused';
        case TransportAction.next:
          await handler.skipToNext();
          return 'Next song';
        case TransportAction.previous:
          await handler.skipToPrevious();
          return 'Previous song';
        case TransportAction.shuffleOn:
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          return 'Shuffle on';
        case TransportAction.shuffleOff:
          await handler.setShuffleMode(AudioServiceShuffleMode.none);
          return 'Shuffle off';
        case TransportAction.repeat:
          await handler.setRepeatMode(AudioServiceRepeatMode.one);
          return 'Repeating this song';
      }
    case FavoriteCommand():
      final id = handler.currentTrackId;
      if (id == null || item == null) return 'Nothing is playing';
      if (!library.isFavorite(id)) await library.toggleFavorite(id);
      return '"${item.title}" is in your favourites';
    case SleepCommand(:final duration, :final endOfSong):
      if (endOfSong) {
        handler.sleepAtEndOfTrack();
        return 'Stopping after this song';
      }
      if (duration == null) {
        handler.cancelSleepTimer();
        return 'Sleep timer off';
      }
      handler.setSleepTimer(duration);
      return 'Stopping in ${duration.inMinutes} minutes';
    case WhatsPlayingCommand():
      return item == null
          ? 'Nothing is playing'
          : '"${item.title}" by ${item.artist ?? 'unknown artist'}';
  }
}

enum _Stage { starting, listening, working, done, failed }

class _VoiceSheet extends StatefulWidget {
  const _VoiceSheet();

  @override
  State<_VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<_VoiceSheet> {
  final _speech = SpeechToText();
  _Stage _stage = _Stage.starting;
  String _heard = '';
  String? _message;
  double _level = 0;
  Timer? _close;

  /// Runs the command if the words stop changing, in case the recogniser
  /// never sends a "final" result (common on Android).
  Timer? _settle;

  /// The command for this listening session has been started.
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void dispose() {
    _close?.cancel();
    _settle?.cancel();
    _speech.cancel();
    super.dispose();
  }

  Future<void> _listen() async {
    _close?.cancel();
    _settle?.cancel();
    _handled = false;
    setState(() {
      _stage = _Stage.starting;
      _heard = '';
      _message = null;
    });
    final available = await _speech.initialize(
      onStatus: (status) {
        debugPrint('Voice: status $status');
        // Listening ended (silence, timeout or tapping the mic): act on
        // whatever was heard.
        if (status == SpeechToText.doneStatus ||
            status == SpeechToText.notListeningStatus) {
          _finish();
        }
      },
      onError: (e) {
        debugPrint('Voice: error ${e.errorMsg} (permanent: ${e.permanent})');
        // Android often reports "no match" right after showing the words;
        // if we heard something, use it rather than failing.
        if (_finish()) return;
        if (!mounted || _stage != _Stage.listening) return;
        setState(() {
          _stage = _Stage.failed;
          _message =
              e.errorMsg == 'error_no_match' ||
                  e.errorMsg == 'error_speech_timeout'
              ? 'Didn\'t catch that. Tap the mic to try again.'
              : 'Voice input stopped (${e.errorMsg}). Tap the mic to retry.';
        });
      },
    );
    if (!mounted) return;
    if (!available) {
      setState(() {
        _stage = _Stage.failed;
        _message =
            'Speech recognition isn\'t available. Check the microphone '
            'permission and that Google speech services are installed.';
      });
      return;
    }
    final library = context.read<MusicLibrary>();
    setState(() => _stage = _Stage.listening);
    HapticFeedback.lightImpact();
    await _speech.listen(
      onResult: (result) {
        if (!mounted || _handled) return;
        final words = result.recognizedWords.trim();
        debugPrint('Voice: heard "$words" (final: ${result.finalResult})');
        setState(() => _heard = words);
        if (words.isEmpty) return;
        if (result.finalResult) {
          _run(words);
        } else {
          _settle?.cancel();
          _settle = Timer(const Duration(milliseconds: 1500), () {
            _speech.stop();
            _finish();
          });
        }
      },
      onSoundLevelChange: (level) {
        if (mounted) setState(() => _level = level);
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        // Errors are handled above; cancelling would throw away the words.
        cancelOnError: false,
        listenMode: ListenMode.search,
        listenFor: const Duration(seconds: 12),
        pauseFor: const Duration(seconds: 3),
        // Helps the recogniser with band and playlist names.
        contextualPhrases: [
          ...library.artists.keys.take(150),
          for (final p in library.playlists) p.name,
        ],
      ),
    );
  }

  /// Runs the command with what was heard so far. Returns false if nothing
  /// was heard.
  bool _finish() {
    if (_handled) return true;
    if (!mounted || _heard.isEmpty) return false;
    _run(_heard);
    return true;
  }

  Future<void> _run(String transcript) async {
    if (_handled || !mounted) return;
    _handled = true;
    _settle?.cancel();
    if (_speech.isListening) _speech.stop();
    setState(() {
      _heard = transcript;
      _stage = _Stage.working;
      _message = null;
    });
    String message;
    var ok = true;
    try {
      message = await runVoiceCommand(
        context.read<MusicHandler>(),
        context.read<MusicLibrary>(),
        transcript,
      );
    } catch (e, st) {
      debugPrint('Voice: command failed: $e\n$st');
      message = 'Something went wrong: $e';
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _stage = ok ? _Stage.done : _Stage.failed;
      _message = message;
    });
    if (ok) {
      _close = Timer(const Duration(milliseconds: 1800), () {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final listening = _stage == _Stage.listening;
    // Sound level is roughly -2..10 dB on Android.
    final pulse = listening ? ((_level + 2) / 12).clamp(0.0, 1.0) : 0.0;

    // Full width: a bottom sheet otherwise shrinks to its content, so a
    // short transcript made the sheet narrow.
    return SafeArea(
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(switch (_stage) {
                _Stage.starting => 'Starting…',
                _Stage.listening => 'Listening…',
                _Stage.working => 'On it…',
                _Stage.done => 'Done',
                _Stage.failed => 'Hmm',
              }, style: textTheme.titleMedium?.copyWith(color: scheme.primary)),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: listening ? _speech.stop : _listen,
                child: SizedBox.square(
                  dimension: 120,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: 72 + 48 * pulse,
                        height: 72 + 48 * pulse,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: scheme.primary.withValues(alpha: 0.18),
                        ),
                      ),
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [scheme.primary, scheme.tertiary],
                          ),
                        ),
                        child: Icon(
                          _stage == _Stage.done
                              ? Icons.check_rounded
                              : listening
                              ? Icons.mic_rounded
                              : Icons.mic_none_rounded,
                          size: 36,
                          color: scheme.onPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  _message ??
                      (_heard.isEmpty
                          ? 'Try "play Coldplay", "shuffle my favourites", '
                                '"next song" or "stop in 20 minutes"'
                          : '"$_heard"'),
                  key: ValueKey(_message ?? _heard),
                  textAlign: TextAlign.center,
                  style: _message != null || _heard.isNotEmpty
                      ? textTheme.titleLarge
                      : textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
