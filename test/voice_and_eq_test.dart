import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_music_player/audio/eq_presets.dart';
import 'package:local_music_player/services/play_history.dart';
import 'package:local_music_player/services/voice_match.dart';

void main() {
  group('parseVoiceQuery', () {
    test('plain name', () {
      final q = parseVoiceQuery('Coldplay');
      expect(q.text, 'coldplay');
      expect(q.shuffle, isFalse);
      expect(q.kind, isNull);
      expect(q.collection, isNull);
    });

    test('shuffle prefix and suffix', () {
      expect(parseVoiceQuery('shuffle Coldplay').shuffle, isTrue);
      expect(parseVoiceQuery('shuffle Coldplay').text, 'coldplay');
      expect(parseVoiceQuery('Coldplay on shuffle').shuffle, isTrue);
      expect(parseVoiceQuery('play shuffle Coldplay').text, 'coldplay');
    });

    test('kind hints', () {
      final album = parseVoiceQuery('the album Parachutes');
      expect(album.kind, VoiceKind.album);
      expect(album.text, 'parachutes');
      expect(parseVoiceQuery('my Road Trip playlist').kind, VoiceKind.playlist);
      expect(parseVoiceQuery('my Road Trip playlist').text, 'road trip');
      expect(parseVoiceQuery('songs by Adele').kind, VoiceKind.artist);
    });

    test('collections', () {
      expect(
        parseVoiceQuery('my favourites').collection,
        VoiceCollection.favorites,
      );
      expect(
        parseVoiceQuery('shuffle my favorites').collection,
        VoiceCollection.favorites,
      );
      expect(
        parseVoiceQuery('liked songs').collection,
        VoiceCollection.favorites,
      );
      final mix = parseVoiceQuery('my driving mix');
      expect(mix.collection, VoiceCollection.mix);
      expect(mix.shuffle, isTrue);
      expect(parseVoiceQuery('').collection, VoiceCollection.everything);
      expect(
        parseVoiceQuery('some music').collection,
        VoiceCollection.everything,
      );
      expect(
        parseVoiceQuery('recently played').collection,
        VoiceCollection.recent,
      );
      expect(
        parseVoiceQuery('my top songs').collection,
        VoiceCollection.mostPlayed,
      );
      expect(parseVoiceQuery('new music').collection, VoiceCollection.added);
    });

    test('a song called "Favourites" is not hijacked by extra words', () {
      expect(parseVoiceQuery('favourites by Adele').collection, isNull);
    });
  });

  group('similarity', () {
    test('exact and "the"', () {
      expect(similarity('coldplay', 'Coldplay'), 1);
      expect(similarity('beatles', 'The Beatles'), greaterThan(0.95));
    });

    test('mis-heard and partial names pass the threshold', () {
      expect(similarity('colplay', 'Coldplay'), greaterThan(matchThreshold));
      expect(
        similarity('parachute', 'Parachutes'),
        greaterThan(matchThreshold),
      );
      expect(
        similarity('dark side of the moon', 'The Dark Side of the Moon'),
        greaterThan(0.9),
      );
      expect(
        similarity('road trip', 'Road Trip 2024'),
        greaterThan(matchThreshold),
      );
    });

    test('unrelated names stay below the threshold', () {
      expect(similarity('coldplay', 'Adele'), lessThan(matchThreshold));
      expect(similarity('yellow', 'Hello'), lessThan(0.9));
    });

    test('bestMatch picks the closest', () {
      final best = bestMatch('adel', ['Coldplay', 'Adele', 'Muse'], (s) => s);
      expect(best!.item, 'Adele');
    });
  });

  group('EqPreset', () {
    test('interpolates on a log scale and holds at the ends', () {
      final p = EqPreset('t', 'T', const [(100, 0), (1000, 10)]);
      expect(p.gainAt(50), 0);
      expect(p.gainAt(5000), 10);
      expect(p.gainAt(316.2278), closeTo(5, 0.01)); // geometric midpoint
    });

    test('flat is flat; ids are unique', () {
      final flat = EqPreset.byId('flat')!;
      for (final hz in [60.0, 230.0, 910.0, 3600.0, 14000.0]) {
        expect(flat.gainAt(hz), 0);
      }
      final ids = EqPreset.all.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('formatHz', () {
      expect(formatHz(60), '60 Hz');
      expect(formatHz(910), '910 Hz');
      expect(formatHz(3600), '3.6 kHz');
      expect(formatHz(1000), '1 kHz');
      expect(formatHz(14000), '14 kHz');
    });
  });

  group('PlayHistory', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('history_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('recent, most played, forget, and persistence', () async {
      final file = File('${dir.path}/history.json');
      final history = PlayHistory(file: file);
      await history.load();
      history
        ..record('a')
        ..record('b')
        ..record('a')
        ..record('c');
      expect(history.recent, ['c', 'a', 'b']);
      expect(history.mostPlayed(), ['a', 'c', 'b']); // ties: most recent first
      history.forget('c');
      expect(history.recent, ['a', 'b']);
      await history.save();

      final reloaded = PlayHistory(file: file);
      await reloaded.load();
      expect(reloaded.recent, ['a', 'b']);
      expect(reloaded.playCount('a'), 2);
    });
  });
}
