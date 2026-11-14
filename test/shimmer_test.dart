import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_music_player/ui/widgets/shimmer.dart';

Widget _app({bool reduceMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: const Scaffold(
      body: Shimmer(
        child: Column(
          children: [
            SizedBox(height: 170, child: CardRowSkeleton()),
            TrackListSkeleton(count: 5),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('skeletons shimmer in sync without errors', (tester) async {
    await tester.pumpWidget(_app());
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    expect(find.byType(ShaderMask), findsNWidgets(2));
    expect(find.byType(TrackTileSkeleton), findsNWidgets(5));
  });

  testWidgets('still shows the sheen with reduced motion', (tester) async {
    await tester.pumpWidget(_app(reduceMotion: true));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Became visible on the frame after layout, though the sweep is paused.
    expect(find.byType(ShaderMask), findsNWidgets(2));
  });

  testWidgets('brings its own shimmer when used alone', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TrackListSkeleton(count: 2))),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(find.byType(ShaderMask), findsOneWidget);
  });
}
