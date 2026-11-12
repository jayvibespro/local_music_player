import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import '../../services/music_library.dart';
import '../widgets/mini_player.dart';
import '../widgets/playlist_picker.dart';
import '../widgets/selection.dart';
import '../widgets/track_tile.dart';

class PlaylistScreen extends StatelessWidget {
  const PlaylistScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<MusicLibrary>();
    final handler = context.read<MusicHandler>();
    final playlist = library.playlistById(playlistId);
    if (playlist == null) return const Scaffold();
    final tracks = library.playlistTracks(playlist);
    final source = handler.sourceFor(
      '${BrowseIds.playlistPrefix}${playlist.id}',
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(playlist.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'rename') {
                final name = await promptPlaylistName(
                  context,
                  title: 'Rename playlist',
                  initial: playlist.name,
                );
                if (name != null && name.isNotEmpty) {
                  await library.renamePlaylist(playlist, name);
                }
              } else if (value == 'delete') {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('Delete "${playlist.name}"?'),
                    content: const Text('The songs stay in your library.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true && context.mounted) {
                  Navigator.pop(context);
                  await library.deletePlaylist(playlist);
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
            ],
          ),
        ],
      ),
      body: SelectableTracks(
        tracks: tracks,
        child: tracks.isEmpty
            ? const Center(
                child: Text('Add songs from their ⋮ menu → Add to playlist'),
              )
            : Column(
                children: [
                  PlayShuffleBar(tracks: tracks, source: source),
                  Expanded(
                    child: ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      itemCount: tracks.length,
                      onReorder: (from, to) =>
                          library.reorderPlaylist(playlist, from, to),
                      itemBuilder: (context, i) => TrackTile(
                        key: ValueKey('$i-${tracks[i].id}'),
                        track: tracks[i],
                        onTap: () =>
                            handler.playTracks(tracks, index: i, from: source),
                        onRemove: () => library.removeFromPlaylist(playlist, i),
                        trailing: ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
      bottomNavigationBar: const SafeArea(child: MiniPlayer()),
    );
  }
}
