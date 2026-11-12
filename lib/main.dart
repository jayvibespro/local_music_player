import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'audio/music_handler.dart';
import 'services/app_intents.dart';
import 'services/home_widget_sync.dart';
import 'services/music_library.dart';
import 'services/settings.dart';
import 'ui/screens/home_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final library = MusicLibrary();
  final settings = Settings();
  final loaded = Future.wait([library.load(), settings.load()]);

  // The handler is also started headless when Android Auto connects, so it
  // must not depend on any widget state.
  final handler = await AudioService.init(
    builder: () => MusicHandler(library, settings),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.jacksons.local_music_player.playback',
      androidNotificationChannelName: 'Music playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'drawable/ic_music_note',
      androidBrowsableRootExtras: {
        'android.media.browse.SEARCH_SUPPORTED': true,
        // 1 = list, 2 = grid
        'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 1,
        'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1,
      },
    ),
  );

  final session = await AudioSession.instance;
  // Music ducks under navigation prompts and notifications instead of
  // pausing; calls still pause (and resume) via MusicHandler.
  await session.configure(
    const AudioSessionConfiguration.music().copyWith(
      androidWillPauseWhenDucked: false,
    ),
  );

  await loaded;
  HomeWidgetSync.start(handler);
  AppIntents.start(handler, navigatorKey);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: library),
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider(create: (_) => ArtColors(handler.mediaItem)),
        Provider.value(value: handler),
      ],
      child: const MusicPlayerApp(),
    ),
  );
}

/// Lets requests from outside the app (voice shortcut) open UI.
final navigatorKey = GlobalKey<NavigatorState>();

class MusicPlayerApp extends StatelessWidget {
  const MusicPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final artSeed = context.watch<ArtColors>().seed;
    final seed = settings.adaptiveColor && artSeed != null
        ? artSeed
        : settings.accent.color;

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Music Player',
      debugShowCheckedModeBanner: false,
      themeMode: settings.themeMode,
      themeAnimationDuration: const Duration(milliseconds: 600),
      scrollBehavior: const AppScrollBehavior(),
      theme: buildTheme(brightness: Brightness.light, seed: seed),
      darkTheme: buildTheme(
        brightness: Brightness.dark,
        seed: seed,
        pureBlack: settings.pureBlack,
      ),
      // Edge-to-edge system bars that follow the active theme.
      builder: (context, child) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
              .copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: Colors.transparent,
              ),
          child: child!,
        );
      },
      home: const HomeScreen(),
    );
  }
}
