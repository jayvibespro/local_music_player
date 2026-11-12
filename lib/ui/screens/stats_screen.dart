import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import '../../services/listening_stats.dart';
import '../../services/music_library.dart';
import '../widgets/artwork.dart';
import 'track_list_screen.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const StatsScreen());

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  StatsPeriod _period = StatsPeriod.week;

  @override
  Widget build(BuildContext context) {
    final handler = context.read<MusicHandler>();
    final library = context.watch<MusicLibrary>();
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Listening stats')),
      body: ListenableBuilder(
        listenable: handler.history,
        builder: (context, _) {
          final stats = computeStats(
            handler.history,
            library.trackById,
            _period,
          );
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              SegmentedButton<StatsPeriod>(
                segments: [
                  for (final p in StatsPeriod.values)
                    ButtonSegment(value: p, label: Text(p.label)),
                ],
                selected: {_period},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _period = s.first),
              ),
              const SizedBox(height: 24),
              if (stats.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: Column(
                    children: [
                      Icon(
                        Icons.insights_rounded,
                        size: 56,
                        color: scheme.primary,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Nothing yet for this period.\n'
                        'Stats build up as you listen.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              else ...[
                // Hero number.
                Text(
                  formatListening(stats.totalTime),
                  style: textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    '${stats.plays} plays',
                    '${stats.distinctSongs} songs',
                    if (stats.peakHour != null)
                      'most around ${formatHour(stats.peakHour!)}',
                  ].join(' • '),
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                _ListeningChart(buckets: stats.buckets),
                const SizedBox(height: 28),
                if (stats.topArtists.isNotEmpty) ...[
                  Text('Top artists', style: textTheme.titleMedium),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 132,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: stats.topArtists.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 16),
                      itemBuilder: (context, i) {
                        final r = stats.topArtists[i];
                        final art = library.artists[r.item]
                            ?.where((t) => t.artPath != null)
                            .firstOrNull
                            ?.artPath;
                        return InkWell(
                          borderRadius: BorderRadius.circular(48),
                          onTap: () => Navigator.of(context).push(
                            TrackListScreen.route(
                              title: r.item,
                              parentId: '${BrowseIds.artistPrefix}${r.item}',
                            ),
                          ),
                          child: SizedBox(
                            width: 88,
                            child: Column(
                              children: [
                                Artwork(
                                  path: art,
                                  size: 88,
                                  radius: 44,
                                  icon: Icons.person,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  r.item,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.labelLarge,
                                ),
                                Text(
                                  '${r.plays} plays',
                                  style: textTheme.labelSmall?.copyWith(
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
                  const SizedBox(height: 24),
                ],
                if (stats.topTracks.isNotEmpty) ...[
                  Text('Top songs', style: textTheme.titleMedium),
                  const SizedBox(height: 4),
                  for (final (i, r) in stats.topTracks.indexed)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: SizedBox(
                        width: 88,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 32,
                              child: Text(
                                '${i + 1}',
                                textAlign: TextAlign.center,
                                style: textTheme.titleMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Artwork(path: r.item.artPath),
                          ],
                        ),
                      ),
                      title: Text(
                        r.item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        r.item.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        '${r.plays}×',
                        style: textTheme.labelLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      onTap: () => handler.playTracks([
                        for (final t in stats.topTracks) t.item,
                      ], index: i),
                    ),
                ],
                if (stats.topAlbums.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text('Top albums', style: textTheme.titleMedium),
                  const SizedBox(height: 4),
                  for (final r in stats.topAlbums.take(5))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Artwork(
                        path: library.albums[r.item]
                            ?.where((t) => t.artPath != null)
                            .firstOrNull
                            ?.artPath,
                        icon: Icons.album,
                      ),
                      title: Text(
                        r.item,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        library.albums[r.item]?.first.artist ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        '${r.plays}×',
                        style: textTheme.labelLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      onTap: () => Navigator.of(context).push(
                        TrackListScreen.route(
                          title: r.item,
                          parentId: '${BrowseIds.albumPrefix}${r.item}',
                        ),
                      ),
                    ),
                ],
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Listening time per day or month. One series, so one colour and no legend;
/// tap (or hover) a bar for its exact value.
class _ListeningChart extends StatefulWidget {
  const _ListeningChart({required this.buckets});

  final List<ListeningBucket> buckets;

  @override
  State<_ListeningChart> createState() => _ListeningChartState();
}

class _ListeningChartState extends State<_ListeningChart> {
  int? _selected;

  @override
  void didUpdateWidget(_ListeningChart old) {
    super.didUpdateWidget(old);
    if (old.buckets.length != widget.buckets.length) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final buckets = widget.buckets;
    final maxMs = buckets.fold<int>(
      0,
      (m, b) => b.time.inMilliseconds > m ? b.time.inMilliseconds : m,
    );
    final selected = _selected;
    // Label every bar when few; otherwise about six evenly spaced labels.
    final labelEvery = buckets.length <= 12 ? 1 : (buckets.length / 6).ceil();

    return Semantics(
      label: 'Listening time chart',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 20,
            child: selected == null
                ? Text(
                    'Tap a bar for details',
                    style: textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                : Text(
                    '${_describe(buckets[selected])}: '
                    '${formatListening(buckets[selected].time)}',
                    style: textTheme.labelLarge,
                  ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 140,
            child: LayoutBuilder(
              builder: (context, c) {
                final slot = c.maxWidth / buckets.length;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => setState(() {
                    final i = (d.localPosition.dx / slot).floor();
                    _selected = i == _selected
                        ? null
                        : i.clamp(0, buckets.length - 1);
                  }),
                  child: CustomPaint(
                    size: Size(c.maxWidth, c.maxHeight),
                    painter: _BarsPainter(
                      values: [
                        for (final b in buckets)
                          maxMs == 0 ? 0 : b.time.inMilliseconds / maxMs,
                      ],
                      selected: selected,
                      bar: scheme.primary,
                      muted: scheme.primary.withValues(alpha: 0.35),
                      baseline: scheme.outlineVariant,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final (i, b) in buckets.indexed)
                Expanded(
                  child: Text(
                    i % labelEvery == 0 ? b.label : '',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _describe(ListeningBucket b) {
    final d = b.start;
    return buckets12(widget.buckets)
        ? '${b.label} ${d.year}'
        : '${b.label} ${d.day}/${d.month}';
  }

  static bool buckets12(List<ListeningBucket> b) =>
      b.length == 12 && b.first.start.day == 1 && b.last.start.day == 1;
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.values,
    required this.selected,
    required this.bar,
    required this.muted,
    required this.baseline,
  });

  final List<double> values;
  final int? selected;
  final Color bar;
  final Color muted;
  final Color baseline;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final slot = size.width / values.length;
    // Thin bars with a 2px+ gap; rounded tops, square at the baseline.
    final width = (slot - 2).clamp(2.0, 18.0);
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v <= 0) continue;
      final h = (v * (size.height - 4)).clamp(2.0, size.height);
      final left = i * slot + (slot - width) / 2;
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTWH(left, size.height - h, width, h),
        topLeft: const Radius.circular(4),
        topRight: const Radius.circular(4),
      );
      canvas.drawRRect(
        rect,
        Paint()..color = selected == null || selected == i ? bar : muted,
      );
    }
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      Paint()
        ..color = baseline
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.values != values ||
      old.selected != selected ||
      old.bar != bar ||
      old.muted != muted;
}
