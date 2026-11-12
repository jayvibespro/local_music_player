import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import '../../models/track.dart';
import '../../services/music_library.dart';
import '../widgets/artwork.dart';
import '../widgets/mini_player.dart';
import '../widgets/selection.dart';
import '../widgets/track_tile.dart';

/// Album, artist or collection page: a big cover that shrinks into the app
/// bar, colours taken from the cover, Play/Shuffle, and the songs (grouped
/// by album on artist pages).
class TrackListScreen extends StatelessWidget {
  const TrackListScreen({
    super.key,
    required this.title,
    required this.parentId,
    this.artPath,
  });

  static Route<void> route({
    required String title,
    required String parentId,
    String? artPath,
  }) => MaterialPageRoute(
    builder: (_) =>
        TrackListScreen(title: title, parentId: parentId, artPath: artPath),
  );

  final String title;

  /// A [BrowseIds] list id; resolved via the handler so the app and Android
  /// Auto always show the same tracks.
  final String parentId;
  final String? artPath;

  bool get _isArtist => parentId.startsWith(BrowseIds.artistPrefix);
  bool get _isAlbum => parentId.startsWith(BrowseIds.albumPrefix);

  @override
  Widget build(BuildContext context) {
    final handler = context.read<MusicHandler>();
    context.watch<MusicLibrary>(); // rebuild when the library changes
    final tracks = handler.tracksFor(parentId);
    final art =
        artPath ?? tracks.where((t) => t.artPath != null).firstOrNull?.artPath;

    return _CoverTheme(
      artPath: art,
      child: Builder(
        builder: (context) => Scaffold(
          body: SelectableTracks(
            tracks: tracks,
            child: CustomScrollView(
              slivers: [
                _Header(
                  title: title,
                  artPath: art,
                  circle: _isArtist,
                  subtitle: _subtitle(tracks),
                ),
                SliverToBoxAdapter(
                  child: PlayShuffleBar(
                    tracks: tracks,
                    source: handler.sourceFor(parentId),
                  ),
                ),
                if (tracks.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text('No songs')),
                  )
                else if (_isArtist)
                  ..._albumSections(context, handler, tracks)
                else
                  trackSliver(
                    context,
                    tracks,
                    source: handler.sourceFor(parentId),
                    leading: _isAlbum
                        ? (i) => _TrackNumber(tracks[i].trackNumber ?? i + 1)
                        : null,
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 88)),
              ],
            ),
          ),
          bottomNavigationBar: const SafeArea(child: MiniPlayer()),
        ),
      ),
    );
  }

  String _subtitle(List<Track> tracks) {
    final total = tracks.fold<Duration>(
      Duration.zero,
      (d, t) => d + t.duration,
    );
    final minutes = total.inMinutes;
    final length = minutes >= 60
        ? '${minutes ~/ 60} h ${minutes % 60} min'
        : '$minutes min';
    final parts = <String>[
      if (_isAlbum && tracks.isNotEmpty) tracks.first.artist,
      if (_isArtist) '${tracks.map((t) => t.album).toSet().length} albums',
      '${tracks.length} song${tracks.length == 1 ? '' : 's'}',
      if (minutes > 0) length,
    ];
    return parts.join(' • ');
  }

  /// Artist page: one section per album, in album order.
  List<Widget> _albumSections(
    BuildContext context,
    MusicHandler handler,
    List<Track> tracks,
  ) {
    final byAlbum = <String, List<Track>>{};
    for (final t in tracks) {
      (byAlbum[t.album] ??= []).add(t);
    }
    final source = handler.sourceFor(parentId);
    final textTheme = Theme.of(context).textTheme;
    return [
      for (final MapEntry(key: album, value: albumTracks)
          in byAlbum.entries) ...[
        SliverToBoxAdapter(
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            leading: Artwork(
              path: albumTracks
                  .where((t) => t.artPath != null)
                  .firstOrNull
                  ?.artPath,
              icon: Icons.album,
            ),
            title: Text(album, style: textTheme.titleMedium),
            subtitle: Text('${albumTracks.length} songs'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              TrackListScreen.route(
                title: album,
                parentId: '${BrowseIds.albumPrefix}$album',
              ),
            ),
          ),
        ),
        SliverFixedExtentList(
          itemExtent: trackTileExtent,
          delegate: SliverChildBuilderDelegate((context, i) {
            final track = albumTracks[i];
            return TrackTile(
              track: track,
              leading: _TrackNumber(track.trackNumber ?? i + 1),
              // Play the whole artist from this song.
              onTap: () => handler.playTracks(
                tracks,
                index: tracks.indexOf(track),
                from: source,
              ),
            );
          }, childCount: albumTracks.length),
        ),
      ],
    ];
  }
}

class _TrackNumber extends StatelessWidget {
  const _TrackNumber(this.number);

  final int number;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 48,
    child: Text(
      '$number',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.artPath,
    required this.circle,
    required this.subtitle,
  });

  final String title;
  final String? artPath;
  final bool circle;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final top = MediaQuery.paddingOf(context).top;
    const coverSize = 200.0;
    const expanded = 380.0;

    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: expanded,
      backgroundColor: scheme.surface,
      title: LayoutBuilder(
        builder: (context, _) {
          // Fade the small title in once the big header has scrolled away.
          final settings = context
              .dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
          final t = settings == null
              ? 1.0
              : ((settings.maxExtent - settings.currentExtent) /
                        (settings.maxExtent - settings.minExtent))
                    .clamp(0.0, 1.0);
          return Opacity(
            opacity: ((t - 0.7) / 0.3).clamp(0.0, 1.0),
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          );
        },
      ),
      flexibleSpace: FlexibleSpaceBar(
        stretchModes: const [StretchMode.zoomBackground],
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (artPath != null)
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                child: Image.file(
                  File(artPath!),
                  fit: BoxFit.cover,
                  cacheWidth: 120,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    scheme.primary.withValues(alpha: 0.25),
                    scheme.surface.withValues(alpha: 0.7),
                    scheme.surface,
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(24, top + 56, 24, 16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      shape: circle ? BoxShape.circle : BoxShape.rectangle,
                      borderRadius: circle ? null : BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.4),
                          blurRadius: 40,
                          offset: const Offset(0, 16),
                        ),
                      ],
                    ),
                    child: Hero(
                      tag: 'cover-$title',
                      child: Artwork(
                        path: artPath,
                        size: coverSize,
                        radius: circle ? coverSize / 2 : 20,
                        icon: circle ? Icons.person : Icons.album,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Re-themes its child with colours from [artPath] (cached per image).
class _CoverTheme extends StatefulWidget {
  const _CoverTheme({required this.artPath, required this.child});

  final String? artPath;
  final Widget child;

  @override
  State<_CoverTheme> createState() => _CoverThemeState();
}

class _CoverThemeState extends State<_CoverTheme> {
  static final _cache = <(String, Brightness), ColorScheme>{};
  ColorScheme? _scheme;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  Future<void> _load() async {
    final path = widget.artPath;
    if (path == null) return;
    final brightness = Theme.of(context).brightness;
    final key = (path, brightness);
    final cached = _cache[key];
    if (cached != null) {
      if (_scheme != cached) setState(() => _scheme = cached);
      return;
    }
    try {
      final scheme = await ColorScheme.fromImageProvider(
        provider: ResizeImage(FileImage(File(path)), width: 96),
        brightness: brightness,
      );
      _cache[key] = scheme;
      if (mounted) setState(() => _scheme = scheme);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final scheme = _scheme;
    if (scheme == null) return widget.child;
    return AnimatedTheme(
      duration: const Duration(milliseconds: 400),
      data: base.copyWith(
        colorScheme: base.colorScheme.copyWith(
          primary: scheme.primary,
          onPrimary: scheme.onPrimary,
          primaryContainer: scheme.primaryContainer,
          onPrimaryContainer: scheme.onPrimaryContainer,
          secondaryContainer: scheme.secondaryContainer,
          onSecondaryContainer: scheme.onSecondaryContainer,
          tertiary: scheme.tertiary,
          tertiaryContainer: scheme.tertiaryContainer,
          onTertiaryContainer: scheme.onTertiaryContainer,
        ),
      ),
      child: widget.child,
    );
  }
}
