import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/music_library.dart';

Future<String?> promptPlaylistName(
  BuildContext context, {
  String title = 'New playlist',
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PlaylistNameDialog(title: title, initial: initial),
  );
}

/// Owns its [TextEditingController] so it is disposed only after the dialog's
/// closing animation has finished, not as soon as the future completes.
class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => FilledButton(
            onPressed: _controller.text.trim().isEmpty ? null : _submit,
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }
}

/// Bottom sheet to add [trackIds] to an existing or new playlist.
Future<void> showAddToPlaylist(BuildContext context, List<String> trackIds) {
  final library = context.read<MusicLibrary>();
  final messenger = ScaffoldMessenger.of(context);

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New playlist'),
            onTap: () async {
              final name = await promptPlaylistName(sheetContext);
              if (name == null || name.isEmpty) return;
              final pl = await library.createPlaylist(name);
              await library.addToPlaylist(pl, trackIds);
              if (sheetContext.mounted) Navigator.pop(sheetContext);
              messenger.showSnackBar(SnackBar(content: Text('Added to $name')));
            },
          ),
          for (final pl in library.playlists)
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(pl.name),
              subtitle: Text('${library.playlistTracks(pl).length} songs'),
              onTap: () async {
                await library.addToPlaylist(pl, trackIds);
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                messenger.showSnackBar(
                  SnackBar(content: Text('Added to ${pl.name}')),
                );
              },
            ),
        ],
      ),
    ),
  );
}
