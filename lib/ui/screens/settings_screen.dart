import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../audio/eq_presets.dart';
import '../../services/music_library.dart';
import '../../services/settings.dart';
import '../widgets/spectrum_visualizer.dart';
import 'equalizer_screen.dart';
import 'folders_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final library = context.watch<MusicLibrary>();
    final scheme = Theme.of(context).colorScheme;

    Widget section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: scheme.primary),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          section('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_outlined),
                  label: Text('System'),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('Dark'),
                ),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (v) =>
                  settings.update((s) => s.themeMode = v.first),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            secondary: const Icon(Icons.contrast),
            title: const Text('Pure black'),
            subtitle: const Text('True black dark mode, easy on OLED screens'),
            value: settings.pureBlack,
            onChanged: (v) => settings.update((s) => s.pureBlack = v),
          ),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            secondary: const Icon(Icons.palette_outlined),
            title: const Text('Colours from album art'),
            subtitle: const Text('Re-theme the app around the current song'),
            value: settings.adaptiveColor,
            onChanged: (v) => settings.update((s) => s.adaptiveColor = v),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text(
              settings.adaptiveColor
                  ? 'Accent (used when a song has no artwork)'
                  : 'Accent',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              children: [
                for (final accent in Accent.values)
                  _AccentSwatch(
                    accent: accent,
                    selected: settings.accent == accent,
                    onTap: () => settings.update((s) => s.accent = accent),
                  ),
              ],
            ),
          ),
          section('Playback'),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            secondary: const Icon(Icons.blur_linear_rounded),
            title: const Text('Fade between songs'),
            subtitle: const Text(
              'Fade the end of each song out and the next one in',
            ),
            value: settings.fadeTransitions,
            onChanged: (v) => settings.update((s) => s.fadeTransitions = v),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: settings.fadeTransitions
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(72, 0, 20, 8),
                    child: Row(
                      children: [
                        Text(
                          'Fade length',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        Expanded(
                          child: Slider(
                            value: settings.fadeSeconds.toDouble(),
                            min: 1,
                            max: 12,
                            divisions: 11,
                            label: '${settings.fadeSeconds} s',
                            onChanged: (v) => settings.update(
                              (s) => s.fadeSeconds = v.round(),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 36,
                          child: Text(
                            '${settings.fadeSeconds} s',
                            textAlign: TextAlign.end,
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            secondary: const Icon(Icons.graphic_eq_rounded),
            title: const Text('Even out volume'),
            subtitle: const Text(
              'Play loud and quiet songs at a similar level. Uses '
              'ReplayGain tags, or measures songs without them',
            ),
            value: settings.normalizeVolume,
            onChanged: (v) => settings.update((s) => s.normalizeVolume = v),
          ),
          if (Platform.isAndroid)
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              secondary: const Icon(Icons.bar_chart_rounded),
              title: const Text('Visualizer'),
              subtitle: const Text(
                'Bars that move with the music on Now Playing. Android asks '
                'for microphone access to read the audio; nothing is recorded',
              ),
              value: settings.showVisualizer,
              onChanged: (v) async {
                if (v && !await requestVisualizerPermission(context)) return;
                await settings.update((s) => s.showVisualizer = v);
              },
            ),
          if (Platform.isAndroid)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: const Icon(Icons.equalizer_rounded),
              title: const Text('Equalizer'),
              subtitle: Text(
                settings.eqEnabled
                    ? 'On • ${EqPreset.byId(settings.eqPreset)?.label ?? 'Custom'}'
                    : 'Off',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(EqualizerScreen.route()),
            ),
          if (Platform.isAndroid) ...[
            section('Car & Bluetooth'),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              secondary: const Icon(Icons.directions_car_outlined),
              title: const Text('Auto-play in Android Auto'),
              subtitle: const Text(
                'Carry on where you left off when Android Auto connects',
              ),
              value: settings.autoPlayInCar,
              onChanged: (v) => settings.update((s) => s.autoPlayInCar = v),
            ),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              secondary: const Icon(Icons.bluetooth_audio_rounded),
              title: const Text('Resume on Bluetooth'),
              subtitle: const Text(
                'Carry on playing when a Bluetooth speaker, car or headphones '
                'connect',
              ),
              value: settings.resumeOnBluetooth,
              onChanged: (v) => settings.update((s) => s.resumeOnBluetooth = v),
            ),
          ],
          section('Library'),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Library sources'),
            subtitle: Text(
              '${library.tracks.length} songs • '
              'hidden songs & folders, short clips',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const FoldersScreen())),
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(Icons.refresh),
            title: const Text('Rescan library'),
            subtitle: Text(
              library.scanning ? 'Scanning…' : 'Look for new files',
            ),
            enabled: !library.scanning,
            onTap: library.rescan,
          ),
        ],
      ),
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  final Accent accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: accent.label,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.all(6),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent.color,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.transparent,
              width: 3,
            ),
            boxShadow: [
              if (selected)
                BoxShadow(
                  color: accent.color.withValues(alpha: 0.6),
                  blurRadius: 16,
                ),
            ],
          ),
          child: selected
              ? const Icon(Icons.check_rounded, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}
