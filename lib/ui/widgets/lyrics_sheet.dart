import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../audio/music_handler.dart';
import '../../services/lyrics.dart';

Future<void> showLyricsSheet(
  BuildContext context,
  Lyrics lyrics,
  String title,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.92,
      child: _LyricsView(lyrics: lyrics, title: title),
    ),
  );
}

class _LyricsView extends StatefulWidget {
  const _LyricsView({required this.lyrics, required this.title});

  final Lyrics lyrics;
  final String title;

  @override
  State<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<_LyricsView> {
  late final MusicHandler _handler = context.read<MusicHandler>();
  late final List<GlobalKey> _keys = [
    for (final _ in widget.lyrics.lines) GlobalKey(),
  ];
  StreamSubscription<Duration>? _sub;
  int _current = -1;

  /// Auto-scroll pauses for a few seconds after the user scrolls.
  DateTime _userScrolledAt = DateTime(0);

  @override
  void initState() {
    super.initState();
    if (widget.lyrics.synced) {
      _current = widget.lyrics.lineAt(_handler.position);
      _sub = _handler.positionStream.listen(_onPosition);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(_current));
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onPosition(Duration position) {
    final line = widget.lyrics.lineAt(position);
    if (line == _current) return;
    setState(() => _current = line);
    if (DateTime.now().difference(_userScrolledAt) >
        const Duration(seconds: 4)) {
      _scrollTo(line);
    }
  }

  void _scrollTo(int line) {
    if (line < 0 || line >= _keys.length) return;
    final ctx = _keys[line].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.35,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final lines = widget.lyrics.lines;
    final synced = widget.lyrics.synced;

    return NotificationListener<UserScrollNotification>(
      onNotification: (_) {
        _userScrolledAt = DateTime.now();
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 160),
        itemCount: lines.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Text(
                synced ? widget.title : '${widget.title} • not synced',
                style: textTheme.labelMedium?.copyWith(color: scheme.primary),
              ),
            );
          }
          final index = i - 1;
          final line = lines[index];
          final active = synced && index == _current;
          final past = synced && index < _current;
          final style = textTheme.headlineSmall!.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.25,
            color: !synced
                ? scheme.onSurface
                : active
                ? scheme.primary
                : scheme.onSurface.withValues(alpha: past ? 0.35 : 0.5),
          );
          return InkWell(
            key: _keys[index],
            borderRadius: BorderRadius.circular(8),
            onTap: line.time == null ? null : () => _handler.seek(line.time!),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: AnimatedScale(
                scale: active ? 1.04 : 1.0,
                alignment: Alignment.centerLeft,
                duration: const Duration(milliseconds: 250),
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 250),
                  style: style,
                  child: Text(line.text.isEmpty ? '♪' : line.text),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
