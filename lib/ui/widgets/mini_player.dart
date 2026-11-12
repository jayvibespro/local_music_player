import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import '../../models/track.dart';
import '../screens/now_playing_screen.dart';
import 'artwork.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = context.read<MusicHandler>();
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, snapshot) {
        final item = snapshot.data;
        if (item == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;

        return _SwipeToSkip(
          onNext: handler.skipToNext,
          onPrevious: handler.skipToPrevious,
          onOpen: () => Navigator.of(context).push(NowPlayingScreen.route()),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(
                  colors: [
                    Color.alphaBlend(
                      scheme.primary.withValues(alpha: 0.28),
                      scheme.surfaceContainerHigh,
                    ),
                    scheme.surfaceContainerHigh,
                  ],
                ),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.18),
                ),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.18),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Material(
                type: MaterialType.transparency,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () =>
                      Navigator.of(context).push(NowPlayingScreen.route()),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
                        child: Row(
                          children: [
                            Hero(
                              tag: 'artwork',
                              child: ArtworkWithIndicator(
                                path: artPathOf(item),
                                radius: 12,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    item.artist ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            StreamBuilder<bool>(
                              initialData: handler.playbackState.value.playing,
                              stream: handler.playbackState
                                  .map((s) => s.playing)
                                  .distinct(),
                              builder: (context, snap) {
                                final playing = snap.data ?? false;
                                return IconButton(
                                  iconSize: 34,
                                  icon: Icon(
                                    playing
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                  ),
                                  onPressed: playing
                                      ? handler.pause
                                      : handler.play,
                                );
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.skip_next_rounded),
                              onPressed: handler.skipToNext,
                            ),
                          ],
                        ),
                      ),
                      _ProgressLine(duration: item.duration),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.duration});

  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    final handler = context.read<MusicHandler>();
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<Duration>(
      stream: handler.positionStream,
      builder: (context, snapshot) {
        final total = duration?.inMilliseconds ?? 0;
        final pos = snapshot.data?.inMilliseconds ?? 0;
        final fraction = total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0;
        return SizedBox(
          height: 3,
          child: Stack(
            children: [
              Container(color: scheme.onSurface.withValues(alpha: 0.08)),
              FractionallySizedBox(
                widthFactor: fraction,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [scheme.primary, scheme.tertiary],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Swipe the mini player left/right to skip, up to open Now Playing. The
/// card follows the finger, slides out, and the next song slides in.
class _SwipeToSkip extends StatefulWidget {
  const _SwipeToSkip({
    required this.child,
    required this.onNext,
    required this.onPrevious,
    required this.onOpen,
  });

  final Widget child;
  final Future<void> Function() onNext;
  final Future<void> Function() onPrevious;
  final VoidCallback onOpen;

  @override
  State<_SwipeToSkip> createState() => _SwipeToSkipState();
}

class _SwipeToSkipState extends State<_SwipeToSkip>
    with SingleTickerProviderStateMixin {
  late final _anim = AnimationController.unbounded(vsync: this);
  double _width = 1;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails d) => _anim.value += d.delta.dx;

  Future<void> _onEnd(DragEndDetails d) async {
    final v = d.primaryVelocity ?? 0;
    final dx = _anim.value;
    final skip = dx.abs() > _width * 0.3 || v.abs() > 700;
    if (!skip) {
      await _anim.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutBack,
      );
      return;
    }
    final next = (v.abs() > 700 ? v : dx) < 0;
    HapticFeedback.selectionClick();
    await _anim.animateTo(
      next ? -_width : _width,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeIn,
    );
    await (next ? widget.onNext() : widget.onPrevious());
    // Bring the new song in from the other side.
    _anim.value = next ? _width : -_width;
    await _anim.animateTo(
      0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _width = c.maxWidth;
        return GestureDetector(
          onHorizontalDragUpdate: _onUpdate,
          onHorizontalDragEnd: _onEnd,
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < -300) widget.onOpen();
          },
          child: AnimatedBuilder(
            animation: _anim,
            builder: (context, child) => Transform.translate(
              offset: Offset(_anim.value, 0),
              child: Opacity(
                opacity: (1 - (_anim.value.abs() / _width) * 0.8).clamp(
                  0.0,
                  1.0,
                ),
                child: child,
              ),
            ),
            child: widget.child,
          ),
        );
      },
    );
  }
}
