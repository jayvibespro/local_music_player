import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import 'playing_indicator.dart';

class Artwork extends StatelessWidget {
  const Artwork({
    super.key,
    required this.path,
    this.url,
    this.size = 48,
    this.radius = 8,
    this.icon = Icons.music_note,
  });

  final String? path;

  /// Web image shown when there's no local [path] (online songs).
  final String? url;
  final double size;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      color: scheme.primaryContainer,
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.5, color: scheme.onPrimaryContainer),
    );
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: path == null
            ? url == null
                  ? placeholder
                  : Image.network(
                      url!,
                      fit: BoxFit.cover,
                      cacheWidth: pixels,
                      gaplessPlayback: true,
                      frameBuilder: (_, child, frame, sync) =>
                          frame == null && !sync ? placeholder : child,
                      errorBuilder: (_, _, _) => placeholder,
                    )
            : Image.file(
                File(path!),
                fit: BoxFit.cover,
                cacheWidth: pixels,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

/// Artwork for the current song, overlaid with an animated equaliser that
/// moves while playing and rests when paused.
class ArtworkWithIndicator extends StatelessWidget {
  const ArtworkWithIndicator({
    super.key,
    required this.path,
    this.url,
    this.size = 48,
    this.radius = 8,
  });

  final String? path;
  final String? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final handler = context.read<MusicHandler>();
    return SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Artwork(path: path, url: url, size: size, radius: radius),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(radius),
            ),
          ),
          Center(
            child: StreamBuilder<bool>(
              initialData: handler.playbackState.value.playing,
              stream: handler.playbackState.map((s) => s.playing).distinct(),
              builder: (context, snapshot) => PlayingIndicator(
                playing: snapshot.data ?? false,
                size: size * 0.42,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
