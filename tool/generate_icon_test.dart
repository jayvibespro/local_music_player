// Renders the app icon PNGs into assets/icon/.
//
//   flutter test tool/generate_icon_test.dart
//   dart run flutter_launcher_icons
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = 1024.0;
const _violet = Color(0xFF7C3AED);
const _pink = Color(0xFFDB2777);

/// Relative heights of the sound-wave bars, left to right.
const _bars = [0.34, 0.62, 0.9, 1.0, 0.78, 0.52, 0.3];

void _paintBackground(Canvas canvas) {
  const rect = Rect.fromLTWH(0, 0, _size, _size);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_violet, _pink],
      ).createShader(rect),
  );
  // Soft highlight top-left and depth bottom-right.
  canvas.drawRect(
    rect,
    Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.7, -0.8),
        radius: 1.0,
        colors: [Color(0x40FFFFFF), Color(0x00FFFFFF)],
      ).createShader(rect),
  );
  canvas.drawRect(
    rect,
    Paint()
      ..shader = const RadialGradient(
        center: Alignment(0.9, 1.0),
        radius: 0.9,
        colors: [Color(0x55000000), Color(0x00000000)],
      ).createShader(rect),
  );
}

/// Draws the bars centred, spanning [widthFraction] of the canvas.
void _paintBars(Canvas canvas, double widthFraction, {required bool shadow}) {
  final totalWidth = _size * widthFraction;
  final maxHeight = totalWidth * 0.95;
  final slot = totalWidth / _bars.length;
  final barWidth = slot * 0.62;
  final left = (_size - totalWidth) / 2 + (slot - barWidth) / 2;

  for (var i = 0; i < _bars.length; i++) {
    final h = maxHeight * _bars[i];
    final r = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(left + i * slot + barWidth / 2, _size / 2),
        width: barWidth,
        height: h,
      ),
      Radius.circular(barWidth / 2),
    );
    if (shadow) {
      canvas.drawRRect(
        r.shift(const Offset(0, 14)),
        Paint()
          ..color = const Color(0x40000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
    }
    canvas.drawRRect(r, Paint()..color = const Color(0xFFFFFFFF));
  }
}

Future<void> _render(String name, void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder));
  final image =
      await recorder.endRecording().toImage(_size.toInt(), _size.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File('assets/icon/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  testWidgets('generate app icon', (tester) async {
    await tester.runAsync(() async {
      // Legacy / iOS icon: full-bleed tile.
      await _render('icon', (c) {
        _paintBackground(c);
        _paintBars(c, 0.58, shadow: true);
      });
      // Adaptive icon layers. flutter_launcher_icons insets these by 16%, which
      // keeps the bars inside the launcher's circular safe zone.
      await _render('background', _paintBackground);
      await _render('foreground', (c) => _paintBars(c, 0.64, shadow: true));
      await _render('monochrome', (c) => _paintBars(c, 0.64, shadow: false));
    });
  });
}
