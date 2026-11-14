import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import '../../models/track.dart';
import '../../services/playback_store.dart';
import '../../services/music_library.dart';
import '../screens/folders_screen.dart';
import 'artwork.dart';
import 'delete_track.dart';
import 'playlist_picker.dart';
import 'selection.dart';

String formatDuration(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString();
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0
      ? '${d.inHours}:${minutes.padLeft(2, '0')}:$seconds'
      : '$minutes:$seconds';
}

class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.onRemove,
    this.removeLabel = 'Remove from playlist',
    this.trailing,
    this.leading,
    this.swipeActions = true,
  });

  final Track track;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final String removeLabel;
  final Widget? trailing;

  /// Replaces the artwork (e.g. track numbers on album pages).
  final Widget? leading;

  /// Swipe right = play next, swipe left = add to queue.
  final bool swipeActions;

  @override
  Widget build(BuildContext context) {
    final handler = context.read<MusicHandler>();
    final library = context.read<MusicLibrary>();
    final isFavorite = context.select<MusicLibrary, bool>(
      (l) => l.isFavorite(track.id),
    );
    final selection = TrackSelection.maybeOf(context);
    final selecting = selection?.active ?? false;
    final selected = selection?.contains(track.id) ?? false;

    final tile = StreamBuilder(
      stream: handler.mediaItem,
      builder: (context, snapshot) {
        final isCurrent = snapshot.data?.extras?['trackId'] == track.id;
        final scheme = Theme.of(context).colorScheme;
        final art =
            leading ??
            (isCurrent
                ? ArtworkWithIndicator(path: track.artPath, url: track.artUrl)
                : Artwork(path: track.artPath, url: track.artUrl));
        return ListTile(
          selected: selected,
          selectedTileColor: scheme.primary.withValues(alpha: 0.12),
          leading: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: selecting
                ? _SelectMark(key: ValueKey(selected), selected: selected)
                : KeyedSubtree(key: const ValueKey('art'), child: art),
          ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: isCurrent ? TextStyle(color: scheme.primary) : null,
          ),
          subtitle: Text(
            '${track.artist} • ${track.album}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: selecting ? () => selection!.toggle(track) : onTap,
          onLongPress: selection == null ? null : () => selection.toggle(track),
          trailing: selecting
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isFavorite)
                      Icon(Icons.favorite, size: 18, color: scheme.primary),
                    if (track.isOnline)
                      Tooltip(
                        message: 'Streams from Audius',
                        child: Icon(
                          Icons.cloud_outlined,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ?trailing,
                    _menu(context, handler, library, isFavorite, scheme),
                  ],
                ),
        );
      },
    );

    if (!swipeActions || selecting) return tile;
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('swipe-${track.id}'),
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.25,
        DismissDirection.endToStart: 0.25,
      },
      // Never actually dismiss: perform the action and spring back.
      confirmDismiss: (direction) async {
        HapticFeedback.mediumImpact();
        final next = direction == DismissDirection.startToEnd;
        final at = next
            ? await handler.playNext(track)
            : await handler.addToQueue(track);
        if (context.mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  next
                      ? '"${track.title}" plays next'
                      : 'Added "${track.title}" to the queue',
                ),
                action: SnackBarAction(
                  label: 'Undo',
                  onPressed: () => handler.undoQueueInsert(at, [track.id]),
                ),
              ),
            );
        }
        return false;
      },
      background: _SwipeBackground(
        color: scheme.primaryContainer,
        foreground: scheme.onPrimaryContainer,
        icon: Icons.playlist_play_rounded,
        label: 'Play next',
        alignment: Alignment.centerLeft,
      ),
      secondaryBackground: _SwipeBackground(
        color: scheme.tertiaryContainer,
        foreground: scheme.onTertiaryContainer,
        icon: Icons.queue_music_rounded,
        label: 'Add to queue',
        alignment: Alignment.centerRight,
      ),
      child: tile,
    );
  }

  Widget _menu(
    BuildContext context,
    MusicHandler handler,
    MusicLibrary library,
    bool isFavorite,
    ColorScheme scheme,
  ) {
    return PopupMenuButton<String>(
      onSelected: (value) async {
        switch (value) {
          case 'next':
            await handler.playNext(track);
          case 'queue':
            await handler.addToQueue(track);
          case 'favorite':
            await library.toggleFavorite(track.id);
          case 'playlist':
            if (context.mounted) {
              await showAddToPlaylist(context, [track.id]);
            }
          case 'select':
            TrackSelection.maybeOf(context)?.toggle(track);
          case 'remove':
            onRemove?.call();
          case 'hide':
            await library.hideTrack(track);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Hid "${track.title}"'),
                  action: SnackBarAction(
                    label: 'Undo',
                    onPressed: () => library.unhideTrack(track),
                  ),
                ),
              );
            }
          case 'hideFolder':
            if (context.mounted) {
              await confirmExcludeFolder(context, p.dirname(track.path));
            }
          case 'delete':
            if (context.mounted) {
              await confirmDeleteTrack(context, track);
            }
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'next', child: Text('Play next')),
        const PopupMenuItem(value: 'queue', child: Text('Add to queue')),
        // Favourites and playlists hold songs on this device only.
        if (!track.isOnline) ...[
          PopupMenuItem(
            value: 'favorite',
            child: Text(
              isFavorite ? 'Remove from favourites' : 'Add to favourites',
            ),
          ),
          const PopupMenuItem(
            value: 'playlist',
            child: Text('Add to playlist…'),
          ),
        ],
        if (TrackSelection.maybeOf(context) != null)
          const PopupMenuItem(value: 'select', child: Text('Select')),
        if (onRemove != null)
          PopupMenuItem(value: 'remove', child: Text(removeLabel)),
        if (!track.isOnline) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'hide', child: Text('Hide song')),
          const PopupMenuItem(
            value: 'hideFolder',
            child: Text('Hide this folder…'),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Text(
              'Delete from device…',
              style: TextStyle(color: scheme.error),
            ),
          ),
        ],
      ],
    );
  }
}

class _SelectMark extends StatelessWidget {
  const _SelectMark({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? scheme.primary : Colors.transparent,
        border: Border.all(
          color: selected ? scheme.primary : scheme.outline,
          width: 2,
        ),
      ),
      child: selected
          ? Icon(Icons.check_rounded, color: scheme.onPrimary)
          : null,
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.color,
    required this.foreground,
    required this.icon,
    required this.label,
    required this.alignment,
  });

  final Color color;
  final Color foreground;
  final IconData icon;
  final String label;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final children = [
      Icon(icon, color: foreground),
      const SizedBox(width: 8),
      Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(color: foreground),
      ),
    ];
    return Container(
      color: color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: alignment == Alignment.centerLeft
            ? children
            : children.reversed.toList(),
      ),
    );
  }
}

/// Height of a [TrackTile] (Material 3 two-line list tile).
const trackTileExtent = 72.0;

/// Fixed-height song rows as a sliver; tapping one plays [tracks] from it.
Widget trackSliver(
  BuildContext context,
  List<Track> tracks, {
  PlaybackSource? source,
  Widget Function(int index)? leading,
}) {
  final handler = context.read<MusicHandler>();
  // Every row has the same height, so the list can jump straight to any
  // position. Without this, dragging the scrollbar through thousands of
  // songs has to lay out every row on the way, which stutters.
  return SliverFixedExtentList(
    itemExtent: trackTileExtent,
    delegate: SliverChildBuilderDelegate(
      (context, index) => TrackTile(
        track: tracks[index],
        leading: leading?.call(index),
        onTap: () => handler.playTracks(tracks, index: index, from: source),
      ),
      childCount: tracks.length,
    ),
  );
}

/// A list of tracks where tapping one plays the whole list from there.
/// Long-press a song to select several.
class TrackList extends StatelessWidget {
  const TrackList({
    super.key,
    required this.tracks,
    this.header,
    this.emptyMessage = 'No songs',
    this.source,
  });

  final List<Track> tracks;
  final Widget? header;
  final String emptyMessage;

  /// Saved with the queue so the app can resume (and show) where it is
  /// playing from.
  final PlaybackSource? source;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return Center(child: Text(emptyMessage));
    return SelectableTracks(
      tracks: tracks,
      child: CustomScrollView(
        slivers: [
          if (header != null) SliverToBoxAdapter(child: header),
          SliverToBoxAdapter(
            child: PlayShuffleBar(tracks: tracks, source: source),
          ),
          trackSliver(context, tracks, source: source),
          // Room for the selection bar.
          const SliverToBoxAdapter(child: SizedBox(height: 88)),
        ],
      ),
    );
  }
}

class PlayShuffleBar extends StatelessWidget {
  const PlayShuffleBar({super.key, required this.tracks, this.source});

  final List<Track> tracks;
  final PlaybackSource? source;

  @override
  Widget build(BuildContext context) {
    final handler = context.read<MusicHandler>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () => handler.playTracks(tracks, from: source),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: () =>
                  handler.playTracks(tracks, shuffle: true, from: source),
              icon: const Icon(Icons.shuffle),
              label: const Text('Shuffle'),
            ),
          ),
        ],
      ),
    );
  }
}
