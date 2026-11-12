import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import '../../models/track.dart';
import '../../services/music_library.dart';

/// Asks for confirmation, then permanently deletes [track] from the device
/// and removes it from the play queue.
Future<void> confirmDeleteTrack(BuildContext context, Track track) =>
    confirmDeleteTracks(context, [track]);

/// Deletes several songs after one confirmation (and, on Android 11+, one
/// system prompt). Returns true if anything was deleted.
Future<bool> confirmDeleteTracks(
  BuildContext context,
  List<Track> tracks,
) async {
  if (tracks.isEmpty) return false;
  final scheme = Theme.of(context).colorScheme;
  final one = tracks.length == 1;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(Icons.delete_forever_rounded, color: scheme.error),
      title: Text(
        one ? 'Delete from device?' : 'Delete ${tracks.length} songs?',
      ),
      content: Text(
        '${one ? '"${tracks.first.title}" will' : 'These songs will'} be '
        'permanently deleted from your device. This can\'t be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;

  final library = context.read<MusicLibrary>();
  final handler = context.read<MusicHandler>();
  final messenger = ScaffoldMessenger.maybeOf(context);

  final deleted = await library.deleteTracks(tracks);
  for (final t in deleted) {
    await handler.removeTrack(t.id);
  }
  final failed = tracks.length - deleted.length;
  messenger?.showSnackBar(
    SnackBar(
      content: Text(switch ((deleted.length, failed)) {
        (0, _) =>
          one
              ? 'Couldn\'t delete "${tracks.first.title}"'
              : 'Couldn\'t delete the songs',
        (1, 0) => 'Deleted "${deleted.first.title}"',
        (final n, 0) => 'Deleted $n songs',
        (final n, final f) => 'Deleted $n songs; $f couldn\'t be deleted',
      }),
    ),
  );
  return deleted.isNotEmpty;
}
