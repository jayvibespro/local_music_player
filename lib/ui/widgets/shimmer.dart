import 'package:flutter/material.dart';

import 'track_tile.dart' show trackTileExtent;

/// Drives one shimmer sweep for every [ShimmerBones] below it, so all the
/// placeholders on a screen shine as a single surface rather than each on
/// its own beat. The sheen is tinted with the theme's accent.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});

  final Widget child;

  static ShimmerState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<ShimmerState>();

  @override
  State<Shimmer> createState() => ShimmerState();
}

class ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController.unbounded(
    vsync: this,
  );

  Listenable get changes => _sweep;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect "remove animations": keep a still sheen instead.
    if (MediaQuery.disableAnimationsOf(context)) {
      _sweep
        ..stop()
        ..value = 0.5;
    } else if (!_sweep.isAnimating) {
      _sweep.repeat(
        min: -0.6,
        max: 1.6,
        period: const Duration(milliseconds: 1500),
      );
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  LinearGradient gradient(ColorScheme scheme) {
    final base = scheme.surfaceContainerHighest;
    final glow = Color.lerp(base, scheme.primary, 0.22)!;
    final peak = Color.lerp(
      glow,
      scheme.brightness == Brightness.dark ? Colors.white : scheme.surface,
      scheme.brightness == Brightness.dark ? 0.18 : 0.55,
    )!;
    return LinearGradient(
      begin: const Alignment(-1, -0.35),
      end: const Alignment(1, 0.35),
      colors: [base, glow, peak, glow, base],
      stops: const [0.25, 0.42, 0.5, 0.58, 0.75],
      transform: _Slide(_sweep.value),
    );
  }

  RenderBox? get _box {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box : null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Slide extends GradientTransform {
  const _Slide(this.progress);

  final double progress;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * progress, 0, 0);
}

/// Paints its (opaque) child with the nearest [Shimmer]'s sweep, positioned
/// relative to the whole shimmer area. Without a [Shimmer] above, it brings
/// its own.
class ShimmerBones extends StatelessWidget {
  const ShimmerBones({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Shimmer.maybeOf(context) == null) {
      return Shimmer(child: _Bones(child: child));
    }
    return _Bones(child: child);
  }
}

class _Bones extends StatefulWidget {
  const _Bones({required this.child});

  final Widget child;

  @override
  State<_Bones> createState() => _BonesState();
}

class _BonesState extends State<_Bones> {
  ShimmerState? _shimmer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shimmer?.changes.removeListener(_repaint);
    _shimmer = Shimmer.maybeOf(context);
    _shimmer?.changes.addListener(_repaint);
  }

  void _repaint() => setState(() {});

  @override
  void dispose() {
    _shimmer?.changes.removeListener(_repaint);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shimmer = _shimmer;
    final area = shimmer?._box;
    final self = context.findRenderObject();
    if (shimmer == null ||
        area == null ||
        self is! RenderBox ||
        !self.hasSize ||
        !self.attached) {
      // First frame: nothing laid out yet to align the sweep with. Try
      // again next frame (the sweep may be paused for reduced motion).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return Opacity(opacity: 0, child: widget.child);
    }
    final offset = self.localToGlobal(Offset.zero, ancestor: area);
    final gradient = shimmer.gradient(Theme.of(context).colorScheme);
    return ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (_) => gradient.createShader(
        Rect.fromLTWH(
          -offset.dx,
          -offset.dy,
          area.size.width,
          area.size.height,
        ),
      ),
      child: widget.child,
    );
  }
}

/// A placeholder shape (the shimmer supplies its colour).
class Bone extends StatelessWidget {
  const Bone({
    super.key,
    this.width,
    this.height = 12,
    this.radius = 6,
    this.circle = false,
  });

  final double? width;
  final double height;
  final double radius;
  final bool circle;

  @override
  Widget build(BuildContext context) => Container(
    width: circle ? height : width,
    height: height,
    decoration: BoxDecoration(
      color: Colors.black,
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circle ? null : BorderRadius.circular(radius),
    ),
  );
}

/// Fades and lifts [child] in, [index] steps after the first, so a column
/// of placeholders cascades in instead of popping up at once.
class _Stagger extends StatelessWidget {
  const _Stagger({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final delay = (index * 0.08).clamp(0.0, 0.6);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + (index * 60).clamp(0, 480)),
      curve: Interval(delay, 1, curve: Curves.easeOutCubic),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 10),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Placeholder in the shape of a [TrackTile].
class TrackTileSkeleton extends StatelessWidget {
  const TrackTileSkeleton({super.key, this.index = 0});

  final int index;

  @override
  Widget build(BuildContext context) {
    // Varied, repeatable line lengths look like real titles.
    const titles = [0.62, 0.45, 0.72, 0.52, 0.66, 0.4, 0.58, 0.7];
    const subtitles = [0.4, 0.55, 0.32, 0.46, 0.36, 0.5, 0.28, 0.42];
    final title = titles[index % titles.length];
    final subtitle = subtitles[index % subtitles.length];
    return SizedBox(
      height: trackTileExtent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Bone(width: 48, height: 48, radius: 8),
            const SizedBox(width: 16),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) => Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Bone(width: c.maxWidth * title, height: 14),
                    const SizedBox(height: 8),
                    Bone(width: c.maxWidth * subtitle, height: 11),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            const Bone(width: 4, height: 18, radius: 2),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// A list's worth of [TrackTileSkeleton]s, cascading in.
class TrackListSkeleton extends StatelessWidget {
  const TrackListSkeleton({super.key, this.count = 8});

  final int count;

  @override
  Widget build(BuildContext context) => ShimmerBones(
    child: Column(
      children: [
        for (var i = 0; i < count; i++)
          _Stagger(
            index: i,
            child: TrackTileSkeleton(index: i),
          ),
      ],
    ),
  );
}

/// A horizontal row of cover-card placeholders.
class CardRowSkeleton extends StatelessWidget {
  const CardRowSkeleton({super.key, this.size = 124, this.count = 4});

  final double size;
  final int count;

  @override
  Widget build(BuildContext context) => ShimmerBones(
    child: ListView(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        for (var i = 0; i < count; i++)
          _Stagger(
            index: i,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SizedBox(
                width: size,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Bone(width: size, height: size, radius: 12),
                    const SizedBox(height: 8),
                    Bone(width: size * (i.isEven ? 0.8 : 0.62), height: 12),
                    const SizedBox(height: 6),
                    Bone(width: size * (i.isEven ? 0.45 : 0.55), height: 10),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Fades a sliver in when it replaces a skeleton. Give it a key that
/// changes with the content so new results fade in too.
class SliverFadeIn extends StatelessWidget {
  const SliverFadeIn({super.key, required this.sliver});

  final Widget sliver;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 380),
    curve: Curves.easeOut,
    builder: (context, t, child) => SliverOpacity(opacity: t, sliver: child),
    child: sliver,
  );
}
