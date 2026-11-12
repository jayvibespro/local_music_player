import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:local_music_player/services/playback_store.dart';

void main() {
  test('snapshot survives a JSON round trip', () {
    const snapshot = PlaybackSnapshot(
      trackIds: ['a', 'b', 'c'],
      index: 2,
      position: Duration(minutes: 1, seconds: 23),
      shuffle: true,
      shuffleIndices: [2, 0, 1],
      loopMode: LoopMode.one,
      source: PlaybackSource('playlist/42', 'Road trip'),
    );
    final back = PlaybackSnapshot.fromJson(snapshot.toJson());
    expect(back.trackIds, ['a', 'b', 'c']);
    expect(back.index, 2);
    expect(back.position, const Duration(minutes: 1, seconds: 23));
    expect(back.shuffle, isTrue);
    expect(back.shuffleIndices, [2, 0, 1]);
    expect(back.loopMode, LoopMode.one);
    expect(back.source?.id, 'playlist/42');
    expect(back.source?.title, 'Road trip');
  });

  test('restored shuffle order reuses the saved order once', () {
    final order = RestoredShuffleOrder([3, 1, 0, 2])..insert(0, 4);
    expect(order.indices, [3, 1, 0, 2]);
    // Later inserts (e.g. "add to queue") behave like the default order.
    order.insert(4, 1);
    expect(order.indices.toSet(), {0, 1, 2, 3, 4});
  });

  test('invalid saved order falls back to a fresh shuffle', () {
    final order = RestoredShuffleOrder([0, 0, 1])..insert(0, 3);
    expect(order.indices.toSet(), {0, 1, 2});
  });
}
