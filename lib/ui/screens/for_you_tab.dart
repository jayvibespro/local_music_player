import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import '../../models/track.dart';
import '../../services/music_library.dart';
import '../widgets/artwork.dart';
import 'stats_screen.dart';
import 'track_list_screen.dart';

/// Home tab: quick starts plus shelves of recently played, most played,
/// recently added and favourite songs.
class ForYouTab extends StatelessWidget {
  const ForYouTab({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = context.read<MusicHandler>();
    final library = context.watch<MusicLibrary>();
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: handler.history,
      builder: (context, _) {
        final recent = handler.tracksFor(BrowseIds.recent);
        final most = handler.tracksFor(BrowseIds.mostPlayed);
        final added = handler.tracksFor(BrowseIds.recentlyAdded);
        final favourites = handler.sortedFavorites;
        final topArtists = _topArtists(most);

        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                _greeting(),
                style: textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Text(
                '${library.tracks.length} songs in your library',
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _QuickStart(
                    icon: Icons.auto_awesome_rounded,
                    label: 'Your mix',
                    onTap: () => handler.playFromMediaId(BrowseIds.drivingMix),
                  ),
                  _QuickStart(
                    icon: Icons.shuffle_rounded,
                    label: 'Shuffle all',
                    onTap: () => handler.playTracks(
                      library.tracks,
                      shuffle: true,
                      from: handler.sourceFor(BrowseIds.songs),
                    ),
                  ),
                  _QuickStart(
                    icon: Icons.insights_rounded,
                    label: 'Your stats',
                    onTap: () =>
                        Navigator.of(context).push(StatsScreen.route()),
                  ),
                ],
              ),
            ),
            if (recent.isEmpty && most.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                child: Card.filled(
                  child: ListTile(
                    leading: Icon(Icons.history_rounded, color: scheme.primary),
                    title: const Text('Your listening shows up here'),
                    subtitle: const Text(
                      'Play some music and your recent and most played songs '
                      'will appear on this page.',
                    ),
                  ),
                ),
              ),
            _Shelf(
              title: 'Recently played',
              id: BrowseIds.recent,
              tracks: recent,
            ),
            if (topArtists.isNotEmpty) _ArtistShelf(artists: topArtists),
            _Shelf(
              title: 'Most played',
              id: BrowseIds.mostPlayed,
              tracks: most,
            ),
            _Shelf(
              title: 'Recently added',
              id: BrowseIds.recentlyAdded,
              tracks: added,
            ),
            _Shelf(
              title: 'Favourites',
              id: BrowseIds.favorites,
              tracks: favourites,
              emptyHint: 'Tap ♥ on a song to add it here',
            ),
          ],
        );
      },
    );
  }

  static String _greeting() {
    final h = DateTime.now().hour;
    if (h < 5) return 'Good night';
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  /// Artists in order of their most played songs.
  static List<(String, String?)> _topArtists(List<Track> mostPlayed) {
    final seen = <String>{};
    final out = <(String, String?)>[];
    for (final t in mostPlayed) {
      if (t.artist == Track.unknownArtist || !seen.add(t.artist)) continue;
      out.add((t.artist, t.artPath));
      if (out.length == 10) break;
    }
    return out;
  }
}

class _QuickStart extends StatelessWidget {
  const _QuickStart({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: FilledButton.tonalIcon(
      onPressed: onTap,
      icon: Icon(icon),
      label: Text(label),
    ),
  );
}

class _Shelf extends StatelessWidget {
  const _Shelf({
    required this.title,
    required this.id,
    required this.tracks,
    this.emptyHint,
  });

  final String title;
  final String id;
  final List<Track> tracks;
  final String? emptyHint;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty && emptyHint == null) return const SizedBox.shrink();
    final handler = context.read<MusicHandler>();
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    const cover = 136.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 8, 8),
          child: Row(
            children: [
              Expanded(child: Text(title, style: textTheme.titleLarge)),
              if (tracks.isNotEmpty)
                TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(TrackListScreen.route(title: title, parentId: id)),
                  child: const Text('See all'),
                ),
            ],
          ),
        ),
        if (tracks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              emptyHint!,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          )
        else
          SizedBox(
            height: cover + 52,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: tracks.length.clamp(0, 20),
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final t = tracks[i];
                return SizedBox(
                  width: cover,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => handler.playTracks(
                      tracks,
                      index: i,
                      from: handler.sourceFor(id),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Artwork(path: t.artPath, size: cover, radius: 14),
                        const SizedBox(height: 6),
                        Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleSmall,
                        ),
                        Text(
                          t.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _ArtistShelf extends StatelessWidget {
  const _ArtistShelf({required this.artists});

  final List<(String, String?)> artists;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
          child: Text('Your top artists', style: textTheme.titleLarge),
        ),
        SizedBox(
          height: 128,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: artists.length,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (context, i) {
              final (name, art) = artists[i];
              return InkWell(
                borderRadius: BorderRadius.circular(48),
                onTap: () => Navigator.of(context).push(
                  TrackListScreen.route(
                    title: name,
                    parentId: '${BrowseIds.artistPrefix}$name',
                  ),
                ),
                child: SizedBox(
                  width: 96,
                  child: Column(
                    children: [
                      Artwork(
                        path: art,
                        size: 96,
                        radius: 48,
                        icon: Icons.person,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: textTheme.labelLarge,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
