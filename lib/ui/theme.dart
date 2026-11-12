import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../models/track.dart';

const fontFamily = 'Montserrat';

/// Builds the app theme from a seed colour. Dark mode uses deep, slightly
/// seed-tinted blacks (or true black for OLED) with vivid accents.
ThemeData buildTheme({
  required Brightness brightness,
  required Color seed,
  bool pureBlack = false,
}) {
  final dark = brightness == Brightness.dark;
  var scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
  );

  if (dark) {
    Color tint(Color base, double amount) =>
        Color.alphaBlend(seed.withValues(alpha: amount), base);
    final base = pureBlack ? Colors.black : const Color(0xFF09090F);
    scheme = scheme.copyWith(
      surface: base,
      surfaceContainerLowest: base,
      surfaceContainerLow: tint(const Color(0xFF0F0F17), 0.03),
      surfaceContainer: tint(const Color(0xFF14141E), 0.04),
      surfaceContainerHigh: tint(const Color(0xFF1B1B27), 0.05),
      surfaceContainerHighest: tint(const Color(0xFF242432), 0.06),
      outlineVariant: const Color(0xFF2A2A38),
    );
  }

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    fontFamily: fontFamily,
  );
  final text = base.textTheme;

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: text.copyWith(
      displaySmall: text.displaySmall?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -1,
      ),
      headlineMedium: text.headlineMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
      ),
      headlineSmall: text.headlineSmall?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: text.labelLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
      ),
      labelSmall: text.labelSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 1.6,
      ),
      bodySmall: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 26,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
        color: scheme.onSurface,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? scheme.surfaceContainerLow : null,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primary.withValues(alpha: dark ? 0.22 : 0.18),
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: fontFamily,
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.12),
      thumbColor: scheme.primary,
      overlayColor: scheme.primary.withValues(alpha: 0.15),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 12.5,
        color: scheme.onSurfaceVariant,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbVisibility: const WidgetStatePropertyAll(true),
      interactive: true,
      radius: const Radius.circular(8),
      crossAxisMargin: 2,
      mainAxisMargin: 4,
      minThumbLength: 48,
      thickness: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.dragged) ? 8 : 5,
      ),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.dragged)
            ? scheme.primary
            : scheme.primary.withValues(alpha: 0.55),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
  );
}

/// Shows the (themed) scrollbar on every vertical scroll view, on all
/// platforms. Material only adds one automatically on desktop.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (axisDirectionToAxis(details.direction) != Axis.vertical) return child;
    return Scrollbar(controller: details.controller, child: child);
  }
}

/// Extracts a seed colour from the current song's artwork so the app can
/// re-theme itself around what's playing.
class ArtColors extends ChangeNotifier {
  ArtColors(Stream<MediaItem?> mediaItems) {
    _sub = mediaItems.listen(_onItem);
  }

  late final StreamSubscription<MediaItem?> _sub;
  final _cache = <String, Color?>{};
  String? _path;
  Color? seed;

  Future<void> _onItem(MediaItem? item) async {
    final path = artPathOf(item);
    if (path == _path) return;
    _path = path;

    Color? color;
    if (path != null) {
      color = _cache.containsKey(path)
          ? _cache[path]
          : _cache[path] = await _extract(path);
      if (_path != path) return; // track changed while extracting
    }
    if (color != seed) {
      seed = color;
      notifyListeners();
    }
  }

  static Future<Color?> _extract(String path) async {
    try {
      final scheme = await ColorScheme.fromImageProvider(
        provider: ResizeImage(FileImage(File(path)), width: 96),
      );
      return scheme.primary;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
