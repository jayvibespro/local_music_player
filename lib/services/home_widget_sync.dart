import 'dart:async';
import 'dart:io';

import 'package:home_widget/home_widget.dart';
import 'package:rxdart/rxdart.dart';

import '../audio/music_handler.dart';
import '../models/track.dart';

/// Keeps the Android home-screen widget showing the current song.
class HomeWidgetSync {
  HomeWidgetSync._();

  static const _provider = 'com.jacksons.local_music_player.NowPlayingWidget';

  static StreamSubscription<void>? _sub;

  static void start(MusicHandler handler) {
    if (!Platform.isAndroid || _sub != null) return;
    _sub =
        Rx.combineLatest2(
              handler.mediaItem,
              handler.playbackState.map((s) => s.playing).distinct(),
              (item, playing) => (
                title: item?.title,
                artist: item?.artist,
                artPath: artPathOf(item),
                playing: playing,
              ),
            )
            .distinct()
            // Skip bursts (e.g. several quick skips).
            .debounceTime(const Duration(milliseconds: 300))
            .asyncMap((s) async {
              try {
                await Future.wait([
                  HomeWidget.saveWidgetData<String>('title', s.title),
                  HomeWidget.saveWidgetData<String>('artist', s.artist),
                  HomeWidget.saveWidgetData<String>('artPath', s.artPath),
                  HomeWidget.saveWidgetData<bool>('playing', s.playing),
                ]);
                await HomeWidget.updateWidget(qualifiedAndroidName: _provider);
              } catch (_) {
                // No widget placed, or the launcher refused: nothing to do.
              }
            })
            .listen(null);
  }
}
