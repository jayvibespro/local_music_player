import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import '../../models/track.dart';
import '../../services/music_library.dart';
import 'artwork.dart';

/// Swipeable album covers for the queue, in play order.
///
/// The current song's cover sits in the middle, on top. The previous and
/// next covers sit behind it on either side, smaller and tilted towards the
/// centre. Swiping left plays the next song, swiping right the previous one;
/// tapping a side cover jumps to it and double-tapping the middle one adds
/// the song to favourites.
///
/// An invisible [PageView] supplies the drag and fling physics; the covers
/// themselves are painted in a [Stack] ordered by distance from the centre,
/// so the middle cover is always on top (PageView would paint the next page
/// over the current one).
class CoverCarousel extends StatefulWidget {
  const CoverCarousel({super.key});

  @override
  State<CoverCarousel> createState() => _CoverCarouselState();
}

class _CoverCarouselState extends State<CoverCarousel> {
  late final MusicHandler _handler;
  late final StreamSubscription<PlayOrder> _sub;
  late PlayOrder _order;
  PageController? _controller;

  /// True from the moment the user drags until the scroll settles.
  bool _dragging = false;

  /// Bumped on each double-tap to replay the heart animation.
  int _heartBurst = 0;

  /// Share of the width one swipe moves; the visual spacing of the covers
  /// matches it, so covers follow the finger exactly.
  static const _spacing = 0.62;
  static const _sideScale = 0.8;
  static const _tilt = 0.6; // radians at one page away
  static const _radius = 24.0;

  @override
  void initState() {
    super.initState();
    _handler = context.read<MusicHandler>();
    _order = _handler.playOrder;
    _sub = _handler.playOrderStream.listen(_onOrder);
  }

  @override
  void dispose() {
    _sub.cancel();
    _controller?.dispose();
    super.dispose();
  }

  double? get _page {
    final c = _controller;
    if (c == null || !c.hasClients || !c.position.haveDimensions) return null;
    return c.page;
  }

  /// The PageController's viewport fraction depends on the width, so it is
  /// (re)created during layout.
  PageController _controllerFor(double fraction) {
    final old = _controller;
    if (old != null && (old.viewportFraction - fraction).abs() < 0.001) {
      return old;
    }
    final page = _page?.round() ?? _order.position;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    return _controller = PageController(
      viewportFraction: fraction,
      initialPage: page,
    );
  }

  /// Song changed from elsewhere (buttons, auto-advance, notification,
  /// Android Auto) or the queue changed: bring the carousel in line.
  void _onOrder(PlayOrder next) {
    final previous = _order;
    setState(() => _order = next);
    final c = _controller;
    final page = _page;
    if (c == null || page == null || _dragging) return;

    if (!listEquals(previous.trackIds, next.trackIds)) {
      // New queue or reshuffle: snap, don't fly past unrelated covers.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && c.hasClients) c.jumpToPage(_order.position);
      });
      return;
    }
    final distance = (page - next.position).abs();
    if (distance < 0.001) return;
    if (distance > 3) {
      c.jumpToPage(next.position);
    } else {
      c.animateToPage(
        next.position,
        duration: Duration(milliseconds: 360 + (80 * distance).round()),
        curve: Curves.easeOutCubic,
      );
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _dragging = true;
    } else if (n is ScrollEndNotification && _dragging) {
      // Fires once the fling has settled, so the song changes when the
      // cover lands rather than halfway through the swipe.
      _dragging = false;
      final page = _page?.round();
      if (page != null &&
          page != _order.position &&
          page >= 0 &&
          page < _order.indices.length) {
        HapticFeedback.selectionClick();
        _handler.skipToIndex(_order.indices[page]);
      }
    }
    return false;
  }

  void _onTapUp(TapUpDetails details, double width, double size) {
    final dx = details.localPosition.dx - width / 2;
    if (dx.abs() <= size / 2) return; // middle cover
    final target = _order.position + (dx > 0 ? 1 : -1);
    if (target < 0 || target >= _order.indices.length) return;
    HapticFeedback.selectionClick();
    _handler.skipToIndex(_order.indices[target]);
  }

  void _onDoubleTap() {
    if (_order.trackIds.isEmpty) return;
    final id = _order.trackIds[_order.position];
    final library = context.read<MusicLibrary>();
    if (!library.isFavorite(id)) library.toggleFavorite(id);
    HapticFeedback.lightImpact();
    setState(() => _heartBurst++);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final size = math.min(width * 0.68, 320.0);
        final step = size * _spacing;
        final controller = _controllerFor(step / width);
        final count = _order.trackIds.length;

        return SizedBox(
          width: width,
          height: size + 48,
          child: StreamBuilder<bool>(
            initialData: _handler.playbackState.value.playing,
            stream: _handler.playbackState.map((s) => s.playing).distinct(),
            builder: (context, snap) {
              final playing = snap.data ?? false;
              // The middle cover settles back slightly while paused.
              return TweenAnimationBuilder<double>(
                tween: Tween(end: playing ? 1.0 : 0.88),
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeOutBack,
                builder: (context, pauseScale, _) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _onTapUp(d, width, size),
                  onDoubleTap: _onDoubleTap,
                  child: Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      AnimatedBuilder(
                        animation: controller,
                        builder: (context, _) => _covers(
                          page: _page ?? _order.position.toDouble(),
                          size: size,
                          step: step,
                          pauseScale: pauseScale,
                          playing: playing,
                        ),
                      ),
                      if (_heartBurst > 0)
                        IgnorePointer(
                          child: _HeartBurst(
                            key: ValueKey(_heartBurst),
                            size: size,
                          ),
                        ),
                      NotificationListener<ScrollNotification>(
                        onNotification: _onScroll,
                        child: PageView.builder(
                          controller: controller,
                          itemCount: count,
                          allowImplicitScrolling: false,
                          itemBuilder: (_, _) => const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _covers({
    required double page,
    required double size,
    required double step,
    required double pauseScale,
    required bool playing,
  }) {
    final count = _order.trackIds.length;
    if (count == 0) {
      return Artwork(path: null, size: size * pauseScale, radius: _radius);
    }
    final library = context.read<MusicLibrary>();
    final scheme = Theme.of(context).colorScheme;

    // Only the covers that can be on screen, farthest first so the middle
    // one paints on top.
    final first = math.max(0, page.floor() - 2);
    final last = math.min(count - 1, page.ceil() + 2);
    final visible = [for (var i = first; i <= last; i++) i]
      ..sort((a, b) => (b - page).abs().compareTo((a - page).abs()));

    // Glow under the middle cover, fading while between songs.
    final settled = 1 - math.min(1.0, (page - page.round()).abs() * 2);
    final glowSize = size * pauseScale;

    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        SizedBox.square(
          dimension: glowSize,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(_radius),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(
                    alpha: (playing ? 0.55 : 0.2) * settled,
                  ),
                  blurRadius: playing ? 70 : 30,
                  spreadRadius: -6,
                  offset: const Offset(0, 24),
                ),
              ],
            ),
          ),
        ),
        for (final i in visible)
          _cover(
            index: i,
            delta: i - page,
            size: size,
            step: step,
            pauseScale: pauseScale,
            track: library.trackById(_order.trackIds[i]),
          ),
      ],
    );
  }

  Widget _cover({
    required int index,
    required double delta,
    required double size,
    required double step,
    required double pauseScale,
    required Track? track,
  }) {
    final d = delta.abs();
    final t = math.min(d, 1.0);
    // Spacing tracks the finger for the neighbours, then bunches up.
    final dx = delta.sign * (d <= 1 ? d * step : step + (d - 1) * step * 0.45);
    final scale =
        lerpDouble(pauseScale, _sideScale, t)! - (d > 1 ? (d - 1) * 0.1 : 0);
    // Turn the side covers to face the middle: their inner edge recedes.
    final angle = delta.clamp(-1.0, 1.0) * _tilt;
    final dim = math.min(0.75, t * 0.4 + math.max(0.0, d - 1) * 0.5);
    final opacity = (2.6 - d).clamp(0.0, 1.0);

    Widget cover = SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Cached as its own layer: only the transform changes per frame.
          RepaintBoundary(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_radius),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x55000000),
                    blurRadius: 24,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Hero(
                // Only the current song's cover matches the mini player.
                tag: index == _order.position ? 'artwork' : 'cover-$index',
                child: Artwork(
                  path: track?.artPath,
                  url: track?.artUrl,
                  size: size,
                  radius: _radius,
                ),
              ),
            ),
          ),
          if (dim > 0.01)
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: dim),
                borderRadius: BorderRadius.circular(_radius),
              ),
            ),
        ],
      ),
    );
    if (opacity < 1) cover = Opacity(opacity: opacity, child: cover);

    return KeyedSubtree(
      key: ValueKey('$index-${_order.trackIds[index]}'),
      child: Transform.translate(
        offset: Offset(dx, 0),
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0012)
            ..rotateY(angle),
          child: Transform.scale(scale: scale, child: cover),
        ),
      ),
    );
  }
}

/// A heart that pops over the cover and fades away.
class _HeartBurst extends StatelessWidget {
  const _HeartBurst({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      builder: (context, t, _) {
        final scale = Curves.elasticOut.transform(math.min(1.0, t * 1.6));
        final alpha = t < 0.6 ? 1.0 : (1 - t) / 0.4;
        return Transform.scale(
          scale: 0.4 + scale * 0.6,
          child: Icon(
            Icons.favorite_rounded,
            size: size * 0.38,
            color: Colors.white.withValues(alpha: alpha * 0.95),
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: alpha * 0.35),
                blurRadius: 24,
              ),
            ],
          ),
        );
      },
    );
  }
}
