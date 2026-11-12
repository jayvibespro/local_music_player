import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_waveform/just_waveform.dart';
import 'package:local_music_player/audio/eq_presets.dart';
import 'package:local_music_player/audio/loudness.dart';
import 'package:local_music_player/models/playlist.dart';
import 'package:local_music_player/models/track.dart';
import 'package:local_music_player/services/library_search.dart';
import 'package:local_music_player/services/listening_stats.dart';
import 'package:local_music_player/services/lyrics.dart';
import 'package:local_music_player/services/play_history.dart';
import 'package:local_music_player/services/voice_match.dart';

Track _t(String id, String title, String artist, String album) => Track(
  id: id,
  path: '/music/$id.mp3',
  title: title,
  artist: artist,
  album: album,
  durationMs: 200000,
  modifiedMs: 0,
);

void main() {
  group('lyrics', () {
    test('synced LRC with metadata, offsets and multiple tags', () {
      final lyrics = parseLyrics(
        '[ar:Coldplay]\n[ti:Yellow]\n[offset:+500]\n'
        '[00:10.50]Look at the stars\n'
        '[00:05.00][00:20.00]Chorus\n',
        source: 'Yellow.lrc',
      )!;
      expect(lyrics.synced, isTrue);
      expect(
        [for (final l in lyrics.lines) l.text],
        ['Chorus', 'Look at the stars', 'Chorus'],
      );
      // +500 ms offset shows lines half a second earlier.
      expect(lyrics.lines.first.time, const Duration(milliseconds: 4500));
      expect(lyrics.lineAt(const Duration(seconds: 1)), -1);
      expect(lyrics.lineAt(const Duration(seconds: 12)), 1);
      expect(lyrics.lineAt(const Duration(minutes: 3)), 2);
    });

    test('plain lyrics are unsynced and trimmed', () {
      final lyrics = parseLyrics('\nFirst line\nSecond line\n\n', source: 'x')!;
      expect(lyrics.synced, isFalse);
      expect(lyrics.lines.length, 2);
      expect(lyrics.lineAt(Duration.zero), -1);
    });

    test('two-digit fractions are hundredths', () {
      final l = parseLyrics('[01:02.3]a\n[01:02.34]b', source: 'x')!;
      expect(
        l.lines[0].time,
        const Duration(minutes: 1, seconds: 2, milliseconds: 300),
      );
      expect(
        l.lines[1].time,
        const Duration(minutes: 1, seconds: 2, milliseconds: 340),
      );
    });

    test('empty input gives null', () {
      expect(parseLyrics('\n\n', source: 'x'), isNull);
    });
  });

  group('voice commands', () {
    test('transport', () {
      expect(
        (parseVoiceCommand('Next song') as TransportCommand).action,
        TransportAction.next,
      );
      expect(
        (parseVoiceCommand('pause the music') as TransportCommand).action,
        TransportAction.pause,
      );
      expect(
        (parseVoiceCommand('go back') as TransportCommand).action,
        TransportAction.previous,
      );
    });

    test('favourite and what is playing', () {
      expect(parseVoiceCommand('I love this song'), isA<FavoriteCommand>());
      expect(parseVoiceCommand("What's playing?"), isA<WhatsPlayingCommand>());
    });

    test('sleep timer', () {
      expect(
        (parseVoiceCommand('stop in 20 minutes') as SleepCommand).duration,
        const Duration(minutes: 20),
      );
      expect(
        (parseVoiceCommand('set a sleep timer for half an hour')
                as SleepCommand)
            .duration,
        const Duration(minutes: 30),
      );
      expect(
        (parseVoiceCommand('sleep timer one hour') as SleepCommand).duration,
        const Duration(hours: 1),
      );
      expect(
        (parseVoiceCommand('stop after this song') as SleepCommand).endOfSong,
        isTrue,
      );
      final off = parseVoiceCommand('cancel the sleep timer') as SleepCommand;
      expect(off.duration, isNull);
      expect(off.endOfSong, isFalse);
    });

    test('everything else is a play request', () {
      final c = parseVoiceCommand('play Yellow by Coldplay');
      expect((c as PlayCommand).query, 'play Yellow by Coldplay');
      // "play" alone resumes, it doesn't search.
      expect(parseVoiceCommand('play'), isA<TransportCommand>());
    });
  });

  group('search', () {
    final tracks = [
      _t('1', 'Yellow', 'Coldplay', 'Parachutes'),
      _t('2', 'Hello', 'Adele', '25'),
      _t('3', 'Fix You', 'Coldplay', 'X&Y'),
      _t('4', 'Mellow Yellow', 'Donovan', 'Mellow Yellow'),
    ];
    Map<String, List<Track>> group(String Function(Track) key) {
      final m = <String, List<Track>>{};
      for (final t in tracks) {
        (m[key(t)] ??= []).add(t);
      }
      return m;
    }

    SearchResults run(String q) => searchLibrary(
      q,
      tracks: tracks,
      artists: group((t) => t.artist),
      albums: group((t) => t.album),
      playlists: [Playlist(id: 'p', name: 'Road Trip')],
    );

    test('title prefix ranks above a later word', () {
      final r = run('yell');
      expect(r.songs.first.title, 'Yellow');
      expect(r.songs.map((t) => t.title), contains('Mellow Yellow'));
    });

    test('typos still find the artist', () {
      final r = run('colplay');
      expect(r.artists.map((e) => e.key), ['Coldplay']);
      expect(r.songs.map((t) => t.id).toSet(), {'1', '3'});
    });

    test('playlists match', () {
      expect(run('road').playlists.single.name, 'Road Trip');
    });

    test('short garbage finds nothing', () {
      expect(run('zq').isEmpty, isTrue);
    });
  });

  group('listening stats', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('stats_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('counts plays, ranks songs/artists, buckets days', () async {
      final history = PlayHistory(file: File('${dir.path}/h.json'));
      await history.load();
      final now = DateTime(2026, 11, 13, 20);
      final tracks = {
        'a': _t('a', 'Yellow', 'Coldplay', 'Parachutes'),
        'b': _t('b', 'Hello', 'Adele', '25'),
      };
      history
        ..record('a', at: now.subtract(const Duration(days: 1)))
        ..record('a', at: now)
        ..record('b', at: now)
        ..record('b', at: now.subtract(const Duration(days: 40)))
        ..addListening(const Duration(minutes: 30), at: now)
        ..addListening(
          const Duration(minutes: 10),
          at: now.subtract(const Duration(days: 1)),
        );

      final week = computeStats(
        history,
        (id) => tracks[id],
        StatsPeriod.week,
        now: now,
      );
      expect(week.plays, 3);
      expect(week.topTracks.first.item.id, 'a');
      expect(week.topTracks.first.plays, 2);
      expect(week.topArtists.first.item, 'Coldplay');
      expect(week.peakHour, 20);
      expect(week.buckets.length, 7);
      expect(week.buckets.last.time, const Duration(minutes: 30));
      // Listening time counts real days up to today.
      expect(
        history.listeningSince(DateTime(2026, 11, 12)),
        const Duration(minutes: 40),
      );

      final all = computeStats(
        history,
        (id) => tracks[id],
        StatsPeriod.all,
        now: now,
      );
      expect(all.plays, 4);
      expect(all.buckets.length, 12);
    });

    test('formatting', () {
      expect(formatListening(const Duration(minutes: 45)), '45 min');
      expect(
        formatListening(const Duration(hours: 2, minutes: 5)),
        '2 h 5 min',
      );
      expect(formatHour(0), '12 AM');
      expect(formatHour(20), '8 PM');
    });
  });

  group('loudness', () {
    test('ReplayGain parsing and target', () {
      expect(parseReplayGain('-7.89 dB'), -7.89);
      expect(parseReplayGain('+1.5 dB'), 1.5);
      expect(parseReplayGain('junk'), isNull);
      // A track tagged -8 dB (loud master) is turned down 4 dB to hit -14.
      expect(gainFromReplayGain(-8), -4);
      expect(clampGain(20), 6);
    });

    test('waveform estimate: louder audio measures louder', () {
      Waveform wave(int amp) => Waveform(
        version: 1,
        flags: 0,
        sampleRate: 44100,
        samplesPerPixel: 2205,
        length: 100,
        data: [
          for (var i = 0; i < 100; i++) ...[-amp, amp],
        ],
      );
      final loud = estimateLufs(wave(30000))!;
      final quiet = estimateLufs(wave(8000))!;
      expect(loud, greaterThan(quiet));
      expect(loud - quiet, closeTo(11.5, 0.2)); // 20·log10(30000/8000)
      expect(estimateLufs(wave(0)), isNull); // silence
    });
  });

  test('compact band labels', () {
    expect(formatHzShort(31), '31');
    expect(formatHzShort(1000), '1k');
    expect(formatHzShort(16000), '16k');
  });
}
