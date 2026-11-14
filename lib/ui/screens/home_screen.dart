import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import '../../models/track.dart';
import '../../services/library_search.dart';
import '../../services/music_library.dart';
import '../../services/playback_store.dart';
import '../../services/settings.dart';
import '../widgets/artwork.dart';
import '../widgets/mini_player.dart';
import '../widgets/playlist_picker.dart';
import '../widgets/sort_sheet.dart';
import '../widgets/track_tile.dart';
import '../widgets/voice_sheet.dart';
import 'discover_tab.dart';
import 'folders_screen.dart';
import 'for_you_tab.dart';
import 'playlist_screen.dart';
import 'settings_screen.dart';
import 'track_list_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _tab = context.read<Settings>().homeTab.clamp(0, _discover);

  static const _titles = [
    'For you',
    'Songs',
    'Albums',
    'Artists',
    'Playlists',
    'Discover',
  ];
  static const _discover = 5;

  /// Discover loads from the internet, so it's only built once opened.
  late bool _discoverOpened = _tab == _discover;
  StreamSubscription<String>? _errors;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _firstRunSetup());
    _errors = context.read<MusicHandler>().playbackErrors.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  void dispose() {
    _errors?.cancel();
    super.dispose();
  }

  Future<void> _firstRunSetup() async {
    final library = context.read<MusicLibrary>();
    if (!await MusicLibrary.requestPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Allow access to audio files to build your library'),
        ),
      );
      return;
    }
    if (library.folders.isEmpty) {
      await library.addDefaultFolderIfEmpty();
    } else {
      // Pick up files added since the last launch.
      await library.rescan();
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<MusicLibrary>();
    context.watch<Settings>(); // re-sort when sort options change
    final handler = context.read<MusicHandler>();
    final sortTarget = switch (_tab) {
      1 => SortTarget.songs,
      2 => SortTarget.albums,
      3 => SortTarget.artists,
      _ => null,
    };

    final Widget body;
    if (_tab == _discover && library.tracks.isEmpty) {
      // Online music works without any songs on the device.
      body = const DiscoverTab();
    } else if (library.tracks.isEmpty) {
      body = _EmptyLibrary(scanning: library.scanning);
    } else {
      // All tabs stay alive to keep their scroll positions. Opting them out
      // of the shared PrimaryScrollController gives each list its own
      // controller, which the always-visible scrollbar requires.
      body = IndexedStack(
        index: _tab,
        children: [
          const ForYouTab(),
          TrackList(
            tracks: handler.sortedSongs,
            source: handler.sourceFor(BrowseIds.songs),
          ),
          _AlbumsTab(albums: handler.sortedAlbums),
          _ArtistsTab(artists: handler.sortedArtists),
          const _PlaylistsTab(),
          _discoverOpened ? const DiscoverTab() : const SizedBox.shrink(),
        ].map((tab) => PrimaryScrollController.none(child: tab)).toList(),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_tab]),
        bottom: library.scanning
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
        actions: [
          IconButton(
            tooltip: 'Voice command',
            icon: const Icon(Icons.mic_none_rounded),
            onPressed: () => showVoiceSheet(context),
          ),
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => showSearch(
              context: context,
              delegate: TrackSearchDelegate(library, context.read<Settings>()),
            ),
          ),
          if (sortTarget != null && library.tracks.isNotEmpty)
            IconButton(
              tooltip: 'Sort',
              icon: const Icon(Icons.sort_rounded),
              onPressed: () => showSortSheet(context, sortTarget),
            ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: body,
      floatingActionButton: _tab == 4
          ? FloatingActionButton(
              tooltip: 'New playlist',
              onPressed: () async {
                final name = await promptPlaylistName(context);
                if (name != null && name.isNotEmpty) {
                  await library.createPlaylist(name);
                }
              },
              child: const Icon(Icons.playlist_add),
            )
          : null,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) {
              setState(() {
                _tab = i;
                if (i == _discover) _discoverOpened = true;
              });
              context.read<Settings>().update((s) => s.homeTab = i);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.auto_awesome_outlined),
                selectedIcon: Icon(Icons.auto_awesome),
                label: 'For you',
              ),
              NavigationDestination(
                icon: Icon(Icons.music_note_outlined),
                selectedIcon: Icon(Icons.music_note),
                label: 'Songs',
              ),
              NavigationDestination(
                icon: Icon(Icons.album_outlined),
                selectedIcon: Icon(Icons.album),
                label: 'Albums',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: 'Artists',
              ),
              NavigationDestination(
                icon: Icon(Icons.queue_music_outlined),
                selectedIcon: Icon(Icons.queue_music),
                label: 'Playlists',
              ),
              NavigationDestination(
                icon: Icon(Icons.explore_outlined),
                selectedIcon: Icon(Icons.explore),
                label: 'Discover',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.scanning});

  final bool scanning;

  @override
  Widget build(BuildContext context) {
    if (scanning) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Scanning for music…'),
          ],
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_music_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            const Text('No music found', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            const Text(
              'Choose the folders that contain your audio files.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => pickAndAddFolder(context),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add music folder'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlbumsTab extends StatelessWidget {
  const _AlbumsTab({required this.albums});

  final List<MapEntry<String, List<Track>>> albums;

  @override
  Widget build(BuildContext context) {
    final entries = albums;
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final MapEntry(key: album, value: tracks) = entries[i];
        final art = tracks
            .firstWhere((t) => t.artPath != null, orElse: () => tracks.first)
            .artPath;
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).push(
            TrackListScreen.route(
              title: album,
              parentId: '${BrowseIds.albumPrefix}$album',
              artPath: art,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, c) => Artwork(
                  path: art,
                  size: c.maxWidth,
                  radius: 12,
                  icon: Icons.album,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                album,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(
                tracks.first.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ArtistsTab extends StatelessWidget {
  const _ArtistsTab({required this.artists});

  final List<MapEntry<String, List<Track>>> artists;

  @override
  Widget build(BuildContext context) {
    final entries = artists;
    return ListView.builder(
      itemExtent: trackTileExtent,
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final MapEntry(key: artist, value: tracks) = entries[i];
        final albumCount = tracks.map((t) => t.album).toSet().length;
        final art = tracks.where((t) => t.artPath != null).firstOrNull?.artPath;
        return ListTile(
          leading: art == null
              ? CircleAvatar(radius: 24, child: Text(artist.characters.first))
              : Artwork(path: art, radius: 24),
          title: Text(artist),
          subtitle: Text(
            '$albumCount album${albumCount == 1 ? '' : 's'} • ${tracks.length} songs',
          ),
          onTap: () => Navigator.of(context).push(
            TrackListScreen.route(
              title: artist,
              parentId: '${BrowseIds.artistPrefix}$artist',
            ),
          ),
        );
      },
    );
  }
}

class _PlaylistsTab extends StatelessWidget {
  const _PlaylistsTab();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<MusicLibrary>();
    final playlists = library.playlists;
    if (playlists.isEmpty) {
      return const Center(child: Text('Tap + to create a playlist'));
    }
    return ListView.builder(
      itemCount: playlists.length,
      itemBuilder: (context, i) {
        final pl = playlists[i];
        final tracks = library.playlistTracks(pl);
        return ListTile(
          leading: Artwork(
            path: tracks.where((t) => t.artPath != null).firstOrNull?.artPath,
            icon: Icons.queue_music,
          ),
          title: Text(pl.name),
          subtitle: Text('${tracks.length} songs'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlaylistScreen(playlistId: pl.id),
            ),
          ),
        );
      },
    );
  }
}

class TrackSearchDelegate extends SearchDelegate<void> {
  TrackSearchDelegate(this.library, this.settings)
    : super(searchFieldLabel: 'Songs, artists, albums, playlists');

  final MusicLibrary library;
  final Settings settings;

  String _lastQuery = '';
  SearchResults _last = SearchResults.empty;

  SearchResults _results() {
    if (query == _lastQuery) return _last;
    _lastQuery = query;
    return _last = searchLibrary(
      query,
      tracks: library.tracks,
      artists: library.artists,
      albums: library.albums,
      playlists: library.playlists,
    );
  }

  void _remember() => settings.addRecentSearch(query);

  @override
  List<Widget> buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(icon: const Icon(Icons.clear), onPressed: () => query = '')
    else
      IconButton(
        tooltip: 'Voice command',
        icon: const Icon(Icons.mic_none_rounded),
        onPressed: () {
          close(context, null);
          showVoiceSheet(context);
        },
      ),
  ];

  @override
  Widget buildLeading(BuildContext context) => const BackButton();

  @override
  Widget buildResults(BuildContext context) {
    _remember();
    return buildSuggestions(context);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.trim().isEmpty) return _recent(context);
    final results = _results();
    if (results.isEmpty) {
      return OnlineSearchResults(
        query: query,
        header: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Not in your library. Results from Audius:',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
      );
    }
    final handler = context.read<MusicHandler>();
    final textTheme = Theme.of(context).textTheme;

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: textTheme.titleSmall),
    );

    return CustomScrollView(
      slivers: [
        if (results.artists.isNotEmpty || results.albums.isNotEmpty)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 150,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                children: [
                  for (final e in results.artists)
                    _ResultCard(
                      title: e.key,
                      subtitle: 'Artist',
                      artPath: _art(e.value),
                      circle: true,
                      onTap: () {
                        _remember();
                        Navigator.of(context).push(
                          TrackListScreen.route(
                            title: e.key,
                            parentId: '${BrowseIds.artistPrefix}${e.key}',
                          ),
                        );
                      },
                    ),
                  for (final e in results.albums)
                    _ResultCard(
                      title: e.key,
                      subtitle: 'Album • ${e.value.first.artist}',
                      artPath: _art(e.value),
                      onTap: () {
                        _remember();
                        Navigator.of(context).push(
                          TrackListScreen.route(
                            title: e.key,
                            parentId: '${BrowseIds.albumPrefix}${e.key}',
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        if (results.playlists.isNotEmpty) ...[
          SliverToBoxAdapter(child: heading('Playlists')),
          SliverList.list(
            children: [
              for (final pl in results.playlists)
                ListTile(
                  leading: Artwork(
                    path: _art(library.playlistTracks(pl)),
                    icon: Icons.queue_music,
                  ),
                  title: Text(pl.name),
                  subtitle: Text('${library.playlistTracks(pl).length} songs'),
                  onTap: () {
                    _remember();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PlaylistScreen(playlistId: pl.id),
                      ),
                    );
                  },
                ),
            ],
          ),
        ],
        if (results.songs.isNotEmpty) ...[
          SliverToBoxAdapter(child: heading('Songs')),
          SliverFixedExtentList(
            itemExtent: trackTileExtent,
            delegate: SliverChildBuilderDelegate(
              (context, i) => TrackTile(
                track: results.songs[i],
                onTap: () {
                  _remember();
                  handler.playTracks(
                    results.songs,
                    index: i,
                    from: PlaybackSource('search', '"$query"'),
                  );
                },
              ),
              childCount: results.songs.length,
            ),
          ),
        ],
        SliverToBoxAdapter(
          child: ListTile(
            leading: const Icon(Icons.travel_explore_rounded),
            title: Text('Search online for "$query"'),
            subtitle: const Text('Stream from Audius'),
            onTap: () {
              _remember();
              Navigator.of(context).push(OnlineSearchScreen.route(query));
            },
          ),
        ),
      ],
    );
  }

  Widget _recent(BuildContext context) {
    final recent = settings.recentSearches;
    if (recent.isEmpty) {
      return Center(
        child: Text(
          'Search your songs, artists, albums and playlists.\n'
          'Typos are fine. Songs you don\'t have are found online.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Recent searches',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton(
                onPressed: () {
                  settings.update((s) => s.recentSearches = []);
                  query = '';
                },
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        for (final q in recent)
          ListTile(
            leading: const Icon(Icons.history_rounded),
            title: Text(q),
            trailing: const Icon(Icons.north_west_rounded),
            onTap: () => query = q,
          ),
      ],
    );
  }

  static String? _art(List<Track> tracks) =>
      tracks.where((t) => t.artPath != null).firstOrNull?.artPath;
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.title,
    required this.subtitle,
    required this.artPath,
    required this.onTap,
    this.circle = false,
  });

  final String title;
  final String subtitle;
  final String? artPath;
  final VoidCallback onTap;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          width: 100,
          child: Column(
            children: [
              Artwork(
                path: artPath,
                size: 92,
                radius: circle ? 46 : 12,
                icon: circle ? Icons.person : Icons.album,
              ),
              const SizedBox(height: 6),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: textTheme.labelLarge,
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
