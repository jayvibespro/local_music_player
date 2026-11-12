import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio/music_handler.dart';
import '../ui/widgets/voice_sheet.dart';

/// Requests from outside the app, delivered by MainActivity:
///  - "Hey Google, play … on Music Player" (play-from-search intent),
///  - the "Voice command" shortcut on the app icon.
class AppIntents {
  AppIntents._();

  static const _channel = MethodChannel(
    'com.jacksons.local_music_player/intents',
  );

  static void start(MusicHandler handler, GlobalKey<NavigatorState> navigator) {
    if (!Platform.isAndroid) return;
    Future<void> handle(Map<Object?, Object?>? action) async {
      if (action == null) return;
      switch (action['type']) {
        case 'search':
          await handler.playRequest(action['query'] as String? ?? '', {
            for (final key in ['focus', 'artist', 'album', 'title', 'playlist'])
              if (action[key] case final String value)
                'android.intent.extra.$key': value,
          });
        case 'voice':
          // A context below the Navigator, so the sheet can find it.
          final context = navigator.currentState?.overlay?.context;
          if (context != null && context.mounted) await showVoiceSheet(context);
      }
    }

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAction') {
        await handle(call.arguments as Map<Object?, Object?>?);
      }
    });
    // A request that launched the app before Dart was listening.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await handle(await _channel.invokeMethod('takePendingAction'));
      } catch (_) {}
    });
  }
}
