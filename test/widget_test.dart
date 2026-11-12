import 'package:flutter_test/flutter_test.dart';
import 'package:local_music_player/audio/music_handler.dart';
import 'package:local_music_player/models/track.dart';

void main() {
  test('stableId is deterministic and hex', () {
    final a = stableId('/storage/emulated/0/Music/song.mp3');
    expect(a, stableId('/storage/emulated/0/Music/song.mp3'));
    expect(a, isNot(stableId('/storage/emulated/0/Music/other.mp3')));
    expect(RegExp(r'^[0-9a-f]+$').hasMatch(a), isTrue);
  });

  test('Track survives a JSON round trip', () {
    const track = Track(
      id: 'abc',
      path: '/music/a.mp3',
      title: 'A',
      artist: 'Artist',
      album: 'Album',
      durationMs: 1000,
      modifiedMs: 42,
      trackNumber: 3,
      artPath: '/art/x.jpg',
    );
    expect(Track.fromJson(track.toJson()).toJson(), track.toJson());
  });

  test('browse item ids split on the last separator', () {
    final id = BrowseIds.trackItem('album/Odd | Name', 'ff00');
    final sep = id.lastIndexOf(BrowseIds.separator);
    expect(id.substring(0, sep), 'album/Odd | Name');
    expect(id.substring(sep + 1), 'ff00');
  });
}
