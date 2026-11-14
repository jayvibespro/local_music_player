import 'dart:io';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import '../../services/music_library.dart';
import '../../models/track.dart';
import '../../services/lyrics.dart';
import '../widgets/artwork.dart';
import '../widgets/lyrics_sheet.dart';
import 'equalizer_screen.dart';
import '../widgets/cover_carousel.dart';
import '../widgets/delete_track.dart';
import '../widgets/playlist_picker.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/waveform_seek_bar.dart';

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  static Route<void> route() => MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => const NowPlayingScreen(),
  );

  @override
  Widget build(BuildContext context) {
    final handler = context.read<MusicHandler>();
    final library = context.watch<MusicLibrary>();

    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, snapshot) {
        final item = snapshot.data;
        final trackId = item?.extras?['trackId'] as String?;
        final isFavorite = trackId != null && library.isFavorite(trackId);
        final track = trackId == null ? null : library.trackById(trackId);
        // Online songs have no local file for lyrics, waveform, favourites
        // or playlists.
        final online = track?.isOnline ?? false;
        final localPath = online ? null : track?.path;
        final textTheme = Theme.of(context).textTheme;

        final scheme = Theme.of(context).colorScheme;
        final artPath = artPathOf(item);

        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            centerTitle: true,
            leading: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
              onPressed: () => Navigator.pop(context),
            ),
            title: StreamBuilder(
              stream: handler.source,
              builder: (context, snap) {
                final from = snap.data;
                if (from == null) {
                  return Text('NOW PLAYING', style: textTheme.labelSmall);
                }
                return Column(
                  children: [
                    Text('PLAYING FROM', style: textTheme.labelSmall),
                    const SizedBox(height: 2),
                    Text(
                      from.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall,
                    ),
                  ],
                );
              },
            ),
            actions: [
              const SleepTimerButton(),
              IconButton(
                tooltip: 'Queue',
                icon: const Icon(Icons.queue_music_rounded),
                onPressed: () => _showQueue(context),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (value) async {
                  if (value == 'eq') {
                    Navigator.of(context).push(EqualizerScreen.route());
                    return;
                  }
                  if (value == 'lyrics') {
                    if (context.mounted && item != null) {
                      _openLyrics(context, item);
                    }
                    return;
                  }
                  final track = trackId == null
                      ? null
                      : library.trackById(trackId);
                  if (track == null) return;
                  if (value == 'delete') confirmDeleteTrack(context, track);
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'lyrics',
                    child: ListTile(
                      leading: Icon(Icons.lyrics_outlined),
                      title: Text('Lyrics'),
                    ),
                  ),
                  if (Platform.isAndroid)
                    const PopupMenuItem(
                      value: 'eq',
                      child: ListTile(
                        leading: Icon(Icons.equalizer_rounded),
                        title: Text('Equalizer'),
                      ),
                    ),
                  if (!online)
                    PopupMenuItem(
                      enabled: trackId != null,
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(
                          Icons.delete_forever_rounded,
                          color: scheme.error,
                        ),
                        title: Text(
                          'Delete from device…',
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          body: Stack(
            fit: StackFit.expand,
            children: [
              _Backdrop(artPath: artPath),
              if (item == null)
                const Center(child: Text('Nothing playing'))
              else
                SafeArea(
                  // Swipe up for lyrics.
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onVerticalDragEnd: (d) {
                      if ((d.primaryVelocity ?? 0) < -400) {
                        _openLyrics(context, item);
                      }
                    },
                    child: Column(
                      children: [
                        const Spacer(),
                        // Full width so the neighbouring covers can peek in
                        // from the screen edges.
                        const CoverCarousel(),
                        const Spacer(),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: textTheme.headlineSmall,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          item.artist ?? '',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: textTheme.titleMedium
                                              ?.copyWith(color: scheme.primary),
                                        ),
                                        Text(
                                          item.album ?? '',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  _LyricsButton(
                                    path: localPath,
                                    onPressed: () => _openLyrics(context, item),
                                  ),
                                  if (online)
                                    const Tooltip(
                                      message: 'Streaming from Audius',
                                      child: Padding(
                                        padding: EdgeInsets.all(12),
                                        child: Icon(Icons.cloud_outlined),
                                      ),
                                    )
                                  else ...[
                                    IconButton(
                                      tooltip: 'Add to playlist',
                                      icon: const Icon(
                                        Icons.playlist_add_rounded,
                                      ),
                                      onPressed: trackId == null
                                          ? null
                                          : () => showAddToPlaylist(context, [
                                              trackId,
                                            ]),
                                    ),
                                    IconButton(
                                      tooltip: isFavorite
                                          ? 'Remove from favourites'
                                          : 'Add to favourites',
                                      icon: AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 250,
                                        ),
                                        transitionBuilder: (child, anim) =>
                                            ScaleTransition(
                                              scale: anim,
                                              child: child,
                                            ),
                                        child: Icon(
                                          isFavorite
                                              ? Icons.favorite_rounded
                                              : Icons.favorite_border_rounded,
                                          key: ValueKey(isFavorite),
                                          color: isFavorite
                                              ? scheme.primary
                                              : null,
                                        ),
                                      ),
                                      onPressed: trackId == null
                                          ? null
                                          : () =>
                                                library.toggleFavorite(trackId),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (trackId != null)
                                WaveformSeekBar(
                                  trackId: trackId,
                                  path: localPath,
                                  duration: item.duration ?? Duration.zero,
                                ),
                              const SizedBox(height: 8),
                              const _Controls(),
                            ],
                          ),
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openLyrics(BuildContext context, MediaItem item) async {
    final library = context.read<MusicLibrary>();
    final trackId = item.extras?['trackId'] as String?;
    final track = trackId == null ? null : library.trackById(trackId);
    if (track == null) return;
    if (track.isOnline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Lyrics aren\'t available for online songs'),
        ),
      );
      return;
    }
    final lyrics = await LyricsFinder.instance.find(track.path);
    if (!context.mounted) return;
    if (lyrics == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No lyrics for this song. Put a .lrc file with the same name '
            'next to the song file.',
          ),
        ),
      );
      return;
    }
    await showLyricsSheet(context, lyrics, '${track.title} • ${track.artist}');
  }

  void _showQueue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) =>
          const FractionallySizedBox(heightFactor: 0.75, child: _QueueSheet()),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) {
    final handler = context.read<MusicHandler>();
    final scheme = Theme.of(context).colorScheme;

    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final playing = state?.playing ?? false;
        final shuffle = handler.shuffleEnabled;
        final loop = handler.loopMode;

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              tooltip: 'Shuffle',
              icon: const Icon(Icons.shuffle),
              color: shuffle ? scheme.primary : null,
              onPressed: handler.toggleShuffle,
            ),
            IconButton(
              iconSize: 40,
              icon: const Icon(Icons.skip_previous_rounded),
              onPressed: handler.skipToPrevious,
            ),
            _PlayButton(
              playing: playing,
              onPressed: playing ? handler.pause : handler.play,
            ),
            IconButton(
              iconSize: 40,
              icon: const Icon(Icons.skip_next_rounded),
              onPressed: handler.skipToNext,
            ),
            IconButton(
              tooltip: 'Repeat',
              icon: Icon(
                loop == LoopMode.one ? Icons.repeat_one : Icons.repeat,
              ),
              color: loop == LoopMode.off ? null : scheme.primary,
              onPressed: handler.cycleRepeat,
            ),
          ],
        );
      },
    );
  }
}

class _QueueSheet extends StatelessWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context) {
    final handler = context.read<MusicHandler>();
    return StreamBuilder<List<MediaItem>>(
      stream: handler.queue,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const [];
        return StreamBuilder<PlaybackState>(
          stream: handler.playbackState,
          builder: (context, stateSnap) {
            final current = stateSnap.data?.queueIndex;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Up next (${items.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    itemCount: items.length,
                    onReorder: (from, to) =>
                        handler.moveQueueItem(from, to > from ? to - 1 : to),
                    itemBuilder: (context, i) {
                      final item = items[i];
                      final isCurrent = i == current;
                      return Dismissible(
                        key: ValueKey('$i-${item.id}'),
                        direction: isCurrent
                            ? DismissDirection.none
                            : DismissDirection.endToStart,
                        onDismissed: (_) => handler.removeQueueItemAt(i),
                        background: Container(
                          color: Theme.of(context).colorScheme.errorContainer,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 24),
                          child: const Icon(Icons.delete_outline),
                        ),
                        child: ListTile(
                          leading: Artwork(path: artPathOf(item), size: 40),
                          title: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: isCurrent
                                ? TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    fontWeight: FontWeight.bold,
                                  )
                                : null,
                          ),
                          subtitle: Text(
                            item.artist ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => handler.skipToQueueItem(i),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Full-screen blurred artwork that cross-fades between songs.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.artPath});

  final String? artPath;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 800),
      child: Stack(
        key: ValueKey(artPath),
        fit: StackFit.expand,
        children: [
          if (artPath != null)
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
              child: Image.file(
                File(artPath!),
                fit: BoxFit.cover,
                cacheWidth: 160,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          // Accent glow plus a fade into the background colour.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.5),
                radius: 1.1,
                colors: [
                  scheme.primary.withValues(alpha: 0.30),
                  scheme.surface.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.55, 1],
                colors: [
                  scheme.surface.withValues(alpha: 0.35),
                  scheme.surface.withValues(alpha: 0.80),
                  scheme.surface,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: playing ? 'Pause' : 'Play',
      child: Container(
        width: 78,
        height: 78,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.primary, scheme.tertiary],
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withValues(alpha: 0.5),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, anim) =>
                  ScaleTransition(scale: anim, child: child),
              child: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                key: ValueKey(playing),
                size: 42,
                color: scheme.onPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown only when the song has lyrics.
class _LyricsButton extends StatelessWidget {
  const _LyricsButton({required this.path, required this.onPressed});

  final String? path;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final path = this.path;
    if (path == null) return const SizedBox.shrink();
    return FutureBuilder<Lyrics?>(
      future: LyricsFinder.instance.find(path),
      builder: (context, snapshot) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: snapshot.data == null
            ? const SizedBox.shrink()
            : IconButton(
                tooltip: 'Lyrics',
                icon: const Icon(Icons.lyrics_outlined),
                onPressed: onPressed,
              ),
      ),
    );
  }
}
