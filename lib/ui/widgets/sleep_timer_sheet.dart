import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';

/// App-bar button for the sleep timer; shows the time left while one runs.
class SleepTimerButton extends StatelessWidget {
  const SleepTimerButton({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = context.read<MusicHandler>();
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<SleepTimer?>(
      stream: handler.sleepTimer,
      initialData: handler.sleepTimer.value,
      builder: (context, snapshot) {
        final timer = snapshot.data;
        if (timer == null) {
          return IconButton(
            tooltip: 'Sleep timer',
            icon: const Icon(Icons.bedtime_outlined),
            onPressed: () => showSleepTimerSheet(context),
          );
        }
        return TextButton.icon(
          onPressed: () => showSleepTimerSheet(context),
          icon: Icon(Icons.bedtime_rounded, color: scheme.primary),
          label: timer.endOfTrack
              ? Text('End', style: TextStyle(color: scheme.primary))
              : _Countdown(timer: timer),
        );
      },
    );
  }
}

class _Countdown extends StatelessWidget {
  const _Countdown({required this.timer});

  final SleepTimer timer;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return StreamBuilder<void>(
      stream: Stream<void>.periodic(const Duration(seconds: 1)),
      builder: (context, _) => Text(
        formatRemaining(timer.remaining ?? Duration.zero),
        style: TextStyle(
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

String formatRemaining(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return m >= 60
      ? '${d.inHours}:${m.remainder(60).toString().padLeft(2, '0')}:$s'
      : '$m:$s';
}

Future<void> showSleepTimerSheet(BuildContext context) {
  final handler = context.read<MusicHandler>();
  const options = [15, 30, 45, 60, 90];

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final active = handler.sleepTimer.value;
      void done() => Navigator.pop(context);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text(
                'Sleep timer',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(
                'Music fades out and pauses.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            for (final minutes in options)
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: Text(
                  minutes < 60
                      ? '$minutes minutes'
                      : minutes == 60
                      ? '1 hour'
                      : '${minutes ~/ 60} h ${minutes % 60} min',
                ),
                onTap: () {
                  handler.setSleepTimer(Duration(minutes: minutes));
                  done();
                },
              ),
            ListTile(
              leading: const Icon(Icons.music_off_outlined),
              title: const Text('End of this song'),
              selected: active?.endOfTrack ?? false,
              onTap: () {
                handler.sleepAtEndOfTrack();
                done();
              },
            ),
            if (active != null)
              ListTile(
                leading: const Icon(Icons.close_rounded),
                title: const Text('Turn off timer'),
                onTap: () {
                  handler.cancelSleepTimer();
                  done();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
