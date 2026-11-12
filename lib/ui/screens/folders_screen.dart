import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/music_library.dart';
import '../widgets/artwork.dart';

Future<void> pickAndAddFolder(BuildContext context) async {
  final library = context.read<MusicLibrary>();
  final messenger = ScaffoldMessenger.of(context);
  if (!await MusicLibrary.requestPermission()) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Permission to read audio files was denied'),
      ),
    );
    return;
  }
  final path = await FilePicker.getDirectoryPath(
    dialogTitle: 'Choose a music folder',
  );
  if (path == null || path == '/') return;
  await library.addFolder(path);
  messenger.showSnackBar(
    SnackBar(content: Text('Library updated: ${library.tracks.length} songs')),
  );
}

/// Asks before hiding every song under [folder].
Future<void> confirmExcludeFolder(BuildContext context, String folder) async {
  final library = context.read<MusicLibrary>();
  final count = library.countInFolder(folder);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Hide this folder?'),
      content: Text(
        '$count song${count == 1 ? '' : 's'} in\n$folder\nwill be hidden. '
        'Nothing is deleted, and you can show the folder again from '
        'Settings → Library sources.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Hide'),
        ),
      ],
    ),
  );
  if (confirmed == true) await library.excludeFolder(folder);
}

String _displayPath(String path) =>
    path.replaceFirst('/storage/emulated/0', 'Internal storage');

class FoldersScreen extends StatelessWidget {
  const FoldersScreen({super.key});

  static const _durationOptions = [0, 15, 30, 60, 90];

  @override
  Widget build(BuildContext context) {
    final library = context.watch<MusicLibrary>();
    final scheme = Theme.of(context).colorScheme;
    final hiddenCount = library.hiddenTracks.length;

    Widget section(String title, [String? hint]) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: scheme.primary),
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Library sources'),
        actions: [
          IconButton(
            tooltip: 'Rescan',
            icon: const Icon(Icons.refresh),
            onPressed: library.scanning ? null : library.rescan,
          ),
        ],
        bottom: library.scanning
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              library.scanning
                  ? 'Scanning your phone…'
                  : '${library.tracks.length} songs in your library',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          section(
            'Scanned locations',
            'Every folder inside these is searched for audio.',
          ),
          for (final folder in library.folders)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: Icon(switch (folder) {
                '/storage/emulated/0' => Icons.phone_android,
                _ when folder.startsWith('/storage/emulated/0/') =>
                  Icons.folder_outlined,
                _ => Icons.sd_storage_outlined,
              }),
              title: Text(_displayPath(folder)),
              trailing: IconButton(
                tooltip: 'Stop scanning',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: library.scanning
                    ? null
                    : () => library.removeFolder(folder),
              ),
            ),
          if (library.folders.isEmpty)
            const ListTile(title: Text('No locations — tap "Add folder"')),
          section(
            'Hidden folders',
            'Songs in these folders are left out of your library.',
          ),
          for (final folder in library.excludedFolders)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: const Icon(Icons.folder_off_outlined),
              title: Text(_displayPath(folder)),
              trailing: TextButton(
                onPressed: () => library.includeFolder(folder),
                child: const Text('Show'),
              ),
            ),
          if (library.excludedFolders.isEmpty)
            const ListTile(
              contentPadding: EdgeInsets.symmetric(horizontal: 20),
              title: Text('None. Use "Hide this folder…" on any song.'),
            ),
          section('Hidden songs'),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(Icons.visibility_off_outlined),
            title: Text(
              hiddenCount == 0
                  ? 'No hidden songs'
                  : '$hiddenCount hidden song${hiddenCount == 1 ? '' : 's'}',
            ),
            trailing: hiddenCount == 0 ? null : const Icon(Icons.chevron_right),
            enabled: hiddenCount > 0,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HiddenSongsScreen()),
            ),
          ),
          section(
            'Skip short audio',
            'Ignores notification sounds, voice notes and other clips.',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                for (final s in _durationOptions)
                  ButtonSegment(
                    value: s,
                    label: Text(s == 0 ? 'Off' : '<${s}s'),
                  ),
              ],
              selected: {library.minDurationSec},
              onSelectionChanged: (v) => library.setMinDuration(v.first),
            ),
          ),
          if (library.minDurationSec > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                '${library.shortTrackCount} short clips skipped',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: library.scanning ? null : () => pickAndAddFolder(context),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('Add folder'),
      ),
    );
  }
}

class HiddenSongsScreen extends StatelessWidget {
  const HiddenSongsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final library = context.watch<MusicLibrary>();
    final hidden = library.hiddenTracks;

    return Scaffold(
      appBar: AppBar(title: const Text('Hidden songs')),
      body: hidden.isEmpty
          ? const Center(child: Text('No hidden songs'))
          : ListView.builder(
              itemCount: hidden.length,
              itemBuilder: (context, i) {
                final track = hidden[i];
                return ListTile(
                  leading: Artwork(path: track.artPath),
                  title: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _displayPath(track.path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: TextButton(
                    onPressed: () => library.unhideTrack(track),
                    child: const Text('Show'),
                  ),
                );
              },
            ),
    );
  }
}
