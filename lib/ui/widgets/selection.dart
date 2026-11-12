import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import '../../models/track.dart';
import '../../services/music_library.dart';
import 'delete_track.dart';
import 'playlist_picker.dart';

/// Songs picked in multi-select mode (long-press a song to start).
class TrackSelection extends ChangeNotifier {
  final _ids = <String>{};
  final _order = <Track>[];

  bool get active => _ids.isNotEmpty;
  int get count => _ids.length;
  bool contains(String id) => _ids.contains(id);

  /// Selected songs, in the order they were picked.
  List<Track> get tracks => List.unmodifiable(_order);

  void toggle(Track track) {
    if (_ids.remove(track.id)) {
      _order.removeWhere((t) => t.id == track.id);
    } else {
      _ids.add(track.id);
      _order.add(track);
    }
    HapticFeedback.selectionClick();
    notifyListeners();
  }

  void selectAll(List<Track> tracks) {
    for (final t in tracks) {
      if (_ids.add(t.id)) _order.add(t);
    }
    notifyListeners();
  }

  void clear() {
    if (_ids.isEmpty) return;
    _ids.clear();
    _order.clear();
    notifyListeners();
  }

  static TrackSelection? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SelectionScope>()?.notifier;
}

class _SelectionScope extends InheritedNotifier<TrackSelection> {
  const _SelectionScope({required super.notifier, required super.child});
}

/// Enables multi-select for the song lists inside [child], with an action
/// bar that slides up while songs are selected. Back clears the selection.
class SelectableTracks extends StatefulWidget {
  const SelectableTracks({
    super.key,
    required this.tracks,
    required this.child,
  });

  /// All songs on screen, for "Select all".
  final List<Track> tracks;
  final Widget child;

  @override
  State<SelectableTracks> createState() => _SelectableTracksState();
}

class _SelectableTracksState extends State<SelectableTracks> {
  final _selection = TrackSelection();

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _SelectionScope(
      notifier: _selection,
      child: ListenableBuilder(
        listenable: _selection,
        builder: (context, child) => PopScope(
          canPop: !_selection.active,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _selection.clear();
          },
          child: Stack(
            children: [
              child!,
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: AnimatedSlide(
                  offset: _selection.active
                      ? Offset.zero
                      : const Offset(0, 1.6),
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: _selection.active ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: _ActionBar(
                      selection: _selection,
                      all: widget.tracks,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        child: widget.child,
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.selection, required this.all});

  final TrackSelection selection;
  final List<Track> all;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final handler = context.read<MusicHandler>();
    final library = context.read<MusicLibrary>();
    final messenger = ScaffoldMessenger.of(context);

    void done(String message) {
      final n = selection.count;
      selection.clear();
      messenger.showSnackBar(
        SnackBar(content: Text('$n song${n == 1 ? '' : 's'} $message')),
      );
    }

    return Material(
      elevation: 6,
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close_rounded),
              onPressed: selection.clear,
            ),
            Expanded(
              child: Text(
                '${selection.count} selected',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            IconButton(
              tooltip: 'Play next',
              icon: const Icon(Icons.playlist_play_rounded),
              onPressed: () async {
                await handler.playNextAll(selection.tracks);
                done('will play next');
              },
            ),
            IconButton(
              tooltip: 'Add to playlist',
              icon: const Icon(Icons.playlist_add_rounded),
              onPressed: () async {
                final ids = [for (final t in selection.tracks) t.id];
                await showAddToPlaylist(context, ids);
                selection.clear();
              },
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (value) async {
                final tracks = selection.tracks;
                switch (value) {
                  case 'all':
                    selection.selectAll(all);
                  case 'queue':
                    await handler.addAllToQueue(tracks);
                    done('added to the queue');
                  case 'play':
                    await handler.playTracks(tracks);
                    selection.clear();
                  case 'favorite':
                    for (final t in tracks) {
                      if (!library.isFavorite(t.id)) {
                        await library.toggleFavorite(t.id);
                      }
                    }
                    done('added to favourites');
                  case 'hide':
                    for (final t in tracks) {
                      await library.hideTrack(t);
                    }
                    done('hidden');
                  case 'delete':
                    if (await confirmDeleteTracks(context, tracks)) {
                      selection.clear();
                    }
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'all', child: Text('Select all')),
                const PopupMenuItem(value: 'play', child: Text('Play these')),
                const PopupMenuItem(
                  value: 'queue',
                  child: Text('Add to queue'),
                ),
                const PopupMenuItem(
                  value: 'favorite',
                  child: Text('Add to favourites'),
                ),
                const PopupMenuItem(value: 'hide', child: Text('Hide')),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    'Delete from device…',
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
