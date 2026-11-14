import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../../services/audius.dart';
import '../../services/playback_store.dart';
import '../widgets/artwork.dart';
import '../widgets/mini_player.dart';
import '../widgets/shimmer.dart';
import '../widgets/track_tile.dart';

/// Online music from Audius: search, trending songs by genre and trending
/// playlists. Everything here streams; nothing is added to the library.
class DiscoverTab extends StatefulWidget {
  const DiscoverTab({super.key});

  @override
  State<DiscoverTab> createState() => _DiscoverTabState();
}

class _DiscoverTabState extends State<DiscoverTab> {
  final _search = TextEditingController();
  String _query = '';
  String? _genre;
  late Future<List<Track>> _trending;
  late Future<List<AudiusPlaylist>> _playlists;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _trending = Audius.trending(genre: _genre);
    _playlists = Audius.trendingPlaylists();
  }

  Future<void> _refresh() async {
    setState(_load);
    try {
      await Future.wait([_trending, _playlists]);
    } catch (_) {
      // Shown in the list itself.
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SearchBar(
              controller: _search,
              hintText: 'Search songs and artists online',
              elevation: const WidgetStatePropertyAll(0),
              leading: const Icon(Icons.search),
              trailing: [
                if (_query.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                  ),
              ],
              textInputAction: TextInputAction.search,
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Expanded(
            child: _query.isNotEmpty
                ? OnlineSearchResults(query: _query)
                : RefreshIndicator(onRefresh: _refresh, child: _browse()),
          ),
        ],
      ),
    );
  }

  Widget _browse() {
    final textTheme = Theme.of(context).textTheme;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: textTheme.titleMedium),
    );
    final source = PlaybackSource(
      'discover',
      _genre == null ? 'Trending on Audius' : '$_genre on Audius',
    );

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final genre in [null, ...Audius.genres])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(genre ?? 'All'),
                      selected: _genre == genre,
                      onSelected: (_) => setState(() {
                        _genre = genre;
                        _trending = Audius.trending(genre: genre);
                      }),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_genre == null) ...[
          SliverToBoxAdapter(child: heading('Trending playlists')),
          SliverToBoxAdapter(
            child: FutureBuilder<List<AudiusPlaylist>>(
              future: _playlists,
              builder: (context, snapshot) {
                final playlists = snapshot.data;
                final loading =
                    snapshot.connectionState != ConnectionState.done;
                return SizedBox(
                  height: 170,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 380),
                    child: loading
                        ? const CardRowSkeleton()
                        : playlists == null
                        ? const SizedBox.shrink()
                        : ListView(
                            key: ObjectKey(playlists),
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            children: [
                              for (final pl in playlists)
                                _PlaylistCard(playlist: pl),
                            ],
                          ),
                  ),
                );
              },
            ),
          ),
        ],
        SliverToBoxAdapter(
          child: heading(
            _genre == null ? 'Trending this week' : '$_genre this week',
          ),
        ),
        FutureBuilder<List<Track>>(
          future: _trending,
          builder: (context, snapshot) {
            // Changing genre keeps the old data in the snapshot while the
            // new list loads; show the skeleton rather than stale songs.
            if (snapshot.connectionState != ConnectionState.done) {
              return const SliverToBoxAdapter(child: TrackListSkeleton());
            }
            if (snapshot.hasError) {
              return SliverToBoxAdapter(
                child: _LoadError(error: snapshot.error!, onRetry: _refresh),
              );
            }
            final tracks = snapshot.data ?? const <Track>[];
            return SliverFadeIn(
              key: ObjectKey(tracks),
              sliver: trackSliver(context, tracks, source: source),
            );
          },
        ),
        const SliverToBoxAdapter(child: _Attribution()),
      ],
    );
  }
}

/// Audius search results for [query], fetched after typing pauses.
class OnlineSearchResults extends StatefulWidget {
  const OnlineSearchResults({super.key, required this.query, this.header});

  final String query;

  /// Shown above the results (e.g. why online results appear).
  final Widget? header;

  @override
  State<OnlineSearchResults> createState() => _OnlineSearchResultsState();
}

class _OnlineSearchResultsState extends State<OnlineSearchResults> {
  // Typing back and forth (or reopening search) shouldn't refetch.
  static final _cache = <String, List<Track>>{};

  Timer? _debounce;
  Future<List<Track>>? _results;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(OnlineSearchResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _schedule();
  }

  void _schedule() {
    _debounce?.cancel();
    final query = widget.query.trim();
    final cached = _cache[query.toLowerCase()];
    if (cached != null) {
      _results = Future.value(cached);
      return;
    }
    _results = null;
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      setState(() => _results = _fetch(query));
    });
  }

  Future<List<Track>> _fetch(String query) async {
    final tracks = await Audius.search(query);
    if (_cache.length > 30) _cache.remove(_cache.keys.first);
    _cache[query.toLowerCase()] = tracks;
    return tracks;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final header = widget.header;
    return FutureBuilder<List<Track>>(
      future: _results,
      builder: (context, snapshot) {
        final Widget body;
        // A new query keeps the previous results in the snapshot until it
        // completes, so check the state rather than the data.
        final loading =
            _results == null ||
            snapshot.connectionState != ConnectionState.done;
        final tracks = loading ? null : snapshot.data;
        if (loading) {
          body = const SliverToBoxAdapter(child: TrackListSkeleton());
        } else if (snapshot.hasError) {
          body = SliverToBoxAdapter(
            child: _LoadError(
              error: snapshot.error!,
              onRetry: () =>
                  setState(() => _results = _fetch(widget.query.trim())),
            ),
          );
        } else if (tracks == null || tracks.isEmpty) {
          body = SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'Nothing found online for "${widget.query}" either',
                textAlign: TextAlign.center,
              ),
            ),
          );
        } else {
          body = SliverFadeIn(
            key: ObjectKey(tracks),
            sliver: trackSliver(
              context,
              tracks,
              source: PlaybackSource('search', '"${widget.query}" on Audius'),
            ),
          );
        }
        return CustomScrollView(
          slivers: [
            if (header != null) SliverToBoxAdapter(child: header),
            body,
            if (tracks != null && tracks.isNotEmpty)
              const SliverToBoxAdapter(child: _Attribution()),
          ],
        );
      },
    );
  }
}

/// Full-screen online search, opened from the library search.
class OnlineSearchScreen extends StatelessWidget {
  const OnlineSearchScreen({super.key, required this.query});

  final String query;

  static Route<void> route(String query) =>
      MaterialPageRoute(builder: (_) => OnlineSearchScreen(query: query));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('"$query" online')),
    body: OnlineSearchResults(query: query),
    bottomNavigationBar: const SafeArea(child: MiniPlayer()),
  );
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({required this.playlist});

  final AudiusPlaylist playlist;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => OnlinePlaylistScreen(playlist: playlist),
          ),
        ),
        child: SizedBox(
          width: 124,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Artwork(
                path: null,
                url: playlist.artUrl,
                size: 124,
                radius: 12,
                icon: Icons.queue_music,
              ),
              const SizedBox(height: 6),
              Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelLarge,
              ),
              Text(
                playlist.owner,
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

class OnlinePlaylistScreen extends StatefulWidget {
  const OnlinePlaylistScreen({super.key, required this.playlist});

  final AudiusPlaylist playlist;

  @override
  State<OnlinePlaylistScreen> createState() => _OnlinePlaylistScreenState();
}

class _OnlinePlaylistScreenState extends State<OnlinePlaylistScreen> {
  late Future<List<Track>> _tracks = Audius.playlistTracks(widget.playlist.id);

  @override
  Widget build(BuildContext context) {
    final playlist = widget.playlist;
    final source = PlaybackSource('discover', playlist.name);
    return Scaffold(
      appBar: AppBar(title: Text(playlist.name)),
      body: Shimmer(
        child: FutureBuilder<List<Track>>(
          future: _tracks,
          builder: (context, snapshot) {
            // A retry keeps the old error in the snapshot while loading.
            if (snapshot.connectionState != ConnectionState.done) {
              return const _PlaylistSkeleton();
            }
            if (snapshot.hasError) {
              return _LoadError(
                error: snapshot.error!,
                onRetry: () => setState(
                  () => _tracks = Audius.playlistTracks(playlist.id),
                ),
              );
            }
            final tracks = snapshot.data;
            if (tracks == null) return const _PlaylistSkeleton();
            if (tracks.isEmpty) {
              return const Center(child: Text('No songs that can be streamed'));
            }
            return TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 380),
              curve: Curves.easeOut,
              builder: (context, t, child) => Opacity(opacity: t, child: child),
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text(
                        'By ${playlist.owner} • ${tracks.length} songs',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: PlayShuffleBar(tracks: tracks, source: source),
                  ),
                  trackSliver(context, tracks, source: source),
                  const SliverToBoxAdapter(child: _Attribution()),
                ],
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: const SafeArea(child: MiniPlayer()),
    );
  }
}

/// Matches the loaded playlist page: owner line, play/shuffle, songs.
class _PlaylistSkeleton extends StatelessWidget {
  const _PlaylistSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
    physics: const NeverScrollableScrollPhysics(),
    children: const [
      ShimmerBones(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Bone(width: 150, height: 13),
              SizedBox(height: 14),
              Row(
                children: [
                  Expanded(child: Bone(height: 40, radius: 20)),
                  SizedBox(width: 12),
                  Expanded(child: Bone(height: 40, radius: 20)),
                ],
              ),
            ],
          ),
        ),
      ),
      TrackListSkeleton(count: 9),
    ],
  );
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is AudiusException
        ? error.toString()
        : 'Couldn\'t load from Audius';
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 40,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _Attribution extends StatelessWidget {
  const _Attribution();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
    child: Text(
      'Online music streams from Audius',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}
