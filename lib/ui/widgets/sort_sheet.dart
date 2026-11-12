import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/settings.dart';

enum SortTarget { songs, albums, artists }

Future<void> showSortSheet(BuildContext context, SortTarget target) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _SortSheet(target: target),
  );
}

class _SortSheet extends StatelessWidget {
  const _SortSheet({required this.target});

  final SortTarget target;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final scheme = Theme.of(context).colorScheme;

    final (
      List<Enum> options,
      Enum selected,
      bool descending,
    ) = switch (target) {
      SortTarget.songs => (
        SongSort.values,
        settings.songSort,
        settings.songDescending,
      ),
      SortTarget.albums => (
        AlbumSort.values,
        settings.albumSort,
        settings.albumDescending,
      ),
      SortTarget.artists => (
        ArtistSort.values,
        settings.artistSort,
        settings.artistDescending,
      ),
    };

    String label(Enum e) => switch (e) {
      SongSort s => s.label,
      AlbumSort s => s.label,
      ArtistSort s => s.label,
      _ => e.name,
    };

    void select(Enum e) => settings.update((s) {
      switch (e) {
        case SongSort v:
          s.songSort = v;
        case AlbumSort v:
          s.albumSort = v;
        case ArtistSort v:
          s.artistSort = v;
      }
    });

    void setDescending(bool value) => settings.update((s) {
      switch (target) {
        case SortTarget.songs:
          s.songDescending = value;
        case SortTarget.albums:
          s.albumDescending = value;
        case SortTarget.artists:
          s.artistDescending = value;
      }
    });

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'SORT BY',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: scheme.primary),
              ),
            ),
            for (final option in options)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                title: Text(
                  label(option),
                  style: option == selected
                      ? TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                        )
                      : null,
                ),
                trailing: option == selected
                    ? Icon(Icons.check_rounded, color: scheme.primary)
                    : null,
                onTap: () => select(option),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.arrow_upward_rounded),
                    label: Text('Ascending'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.arrow_downward_rounded),
                    label: Text('Descending'),
                  ),
                ],
                selected: {descending},
                onSelectionChanged: (v) => setDescending(v.first),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
