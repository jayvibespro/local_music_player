import 'package:flutter_test/flutter_test.dart';
import 'package:local_music_player/models/track.dart';
import 'package:local_music_player/services/audius.dart';

Map<String, dynamic> _json({bool streamable = true}) => {
  'id': 'J7Xb000',
  'title': ' Murder She Wrote ',
  'duration': 201,
  'is_streamable': streamable,
  'artwork': {'480x480': 'https://example.com/480x480.jpg'},
  'user': {'name': 'Brooke Evers'},
};

void main() {
  group('Audius', () {
    test('converts a streamable track', () {
      final t = Audius.trackFromJson(_json())!;
      expect(t.id, 'audius:J7Xb000');
      expect(t.title, 'Murder She Wrote');
      expect(t.artist, 'Brooke Evers');
      expect(t.album, 'Audius');
      expect(t.durationMs, 201000);
      expect(t.artUrl, 'https://example.com/480x480.jpg');
      expect(t.artPath, isNull);
      expect(t.isOnline, isTrue);
      expect(
        t.path,
        startsWith('https://api.audius.co/v1/tracks/J7Xb000/stream'),
      );
    });

    test('skips tracks that cannot be streamed', () {
      expect(Audius.trackFromJson(_json(streamable: false)), isNull);
      expect(
        Audius.trackFromJson({..._json(), 'is_stream_gated': true}),
        isNull,
      );
    });

    test('online track survives a JSON round trip', () {
      final t = Audius.trackFromJson(_json())!.copyWith(artPath: '/a.jpg');
      final back = Track.fromJson(t.toJson());
      expect(back.path, t.path);
      expect(back.artUrl, t.artUrl);
      expect(back.artPath, '/a.jpg');
      expect(back.isOnline, isTrue);
    });

    test('local files are not online', () {
      const t = Track(
        id: '1',
        path: '/storage/emulated/0/Music/song.mp3',
        title: 'Song',
        artist: 'A',
        album: 'B',
        durationMs: 1000,
        modifiedMs: 0,
      );
      expect(t.isOnline, isFalse);
    });
  });
}
