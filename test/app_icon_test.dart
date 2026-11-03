// The launcher icon: the phone as the car's display, on its mount above the
// dashboard, showing docs/screenshots/highway-cruise.png (redraw the
// screenshots first when the dash changes). Regenerate the Android and iOS
// assets with
//   APP_ICON=1 flutter test test/app_icon_test.dart
// (APP_ICON_PREVIEW=<file.png> also writes a preview under launcher masks).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';


const _res = 'android/app/src/main/res';

Paint _stroke(double w, Color c, {StrokeCap cap = StrokeCap.butt}) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeCap = cap
  ..color = c;

/// [scale] is the share of the canvas the icon's square takes: 0.62 for an
/// adaptive layer (keeps the phone inside the 66 dp safe zone; the backdrop
/// bleeds to the edges), about 0.92 for a pre-shaped legacy icon ([rounded]).
class MountIcon extends CustomPainter {
  const MountIcon(this.shot, {this.scale = 1, this.rounded = false});

  /// The dash on the phone's screen.
  final ui.Image shot;
  final double scale;
  final bool rounded;

  @override
  void paint(Canvas c, Size s) {
    final u = s.width * scale, o = (s.width - u) / 2;
    Offset p(double x, double y) => Offset(o + x * u, o + y * u);
    if (rounded) {
      c.clipRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(o, o, u, u), Radius.circular(u * 0.23)));
    }
    final all = Offset.zero & s;
    c.drawRect(
        all,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(0, -0.2),
            radius: 0.9,
            colors: [Color(0xFF17212C), Color(0xFF040608)],
          ).createShader(all));

    // Dashboard top: the parabola y = 0.8 - 0.28x(1 - x) across the icon,
    // carried on to the canvas edges (its Bezier control is where the end
    // tangents meet).
    double y(double x) => 0.8 - 0.28 * x * (1 - x);
    final x0 = -o / u, x1 = 1 + o / u;
    final cy = y(x0) + (-0.28 + 0.56 * x0) * (0.5 - x0);
    final edge = Path()
      ..moveTo(p(x0, y(x0)).dx, p(x0, y(x0)).dy)
      ..quadraticBezierTo(p(0.5, cy).dx, p(0.5, cy).dy, p(x1, y(x1)).dx, p(x1, y(x1)).dy);
    c.drawPath(
        Path.from(edge)
          ..lineTo(s.width, s.height)
          ..lineTo(0, s.height)
          ..close(),
        Paint()..color = const Color(0xFF1E252D));
    c.drawPath(edge, _stroke(u * 0.012, Colors.white24));

    // Mount stem, then the phone on its side: the screen in the
    // screenshot's own proportions, a bezel round it.
    c.drawLine(p(0.5, 0.56), p(0.5, 0.73),
        _stroke(u * 0.05, const Color(0xFF39424D), cap: StrokeCap.round));
    final w = u * 0.80;
    final screen = Rect.fromCenter(center: p(0.5, 0.42), width: w, height: w * shot.height / shot.width);
    final phone = screen.inflate(u * 0.03);
    final body = RRect.fromRectAndRadius(phone, Radius.circular(phone.height * 0.18));
    c.drawRRect(body, Paint()..color = const Color(0xFF39424D));
    c.drawRRect(body.deflate(phone.height * 0.012), _stroke(phone.height * 0.012, Colors.white24));
    c.clipRRect(RRect.fromRectAndRadius(screen, Radius.circular(phone.height * 0.12)));
    // Medium is mipmapped: the sharpest for shrinking this far.
    c.drawImageRect(shot, Offset.zero & Size(shot.width.toDouble(), shot.height.toDouble()), screen,
        Paint()..filterQuality = FilterQuality.medium);
  }

  @override
  bool shouldRepaint(_) => false;
}

Future<ui.Image> _render(int px, CustomPainter p) {
  final rec = ui.PictureRecorder();
  p.paint(Canvas(rec), Size(px.toDouble(), px.toDouble()));
  return rec.endRecording().toImage(px, px);
}

Future<void> _save(ui.Image img, String path) async {
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {

  testWidgets('launcher icon', (t) async {
    if (Platform.environment['APP_ICON'] == null) return;
    await t.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
          File('docs/screenshots/highway-cruise.png').readAsBytesSync());
      final shot = (await codec.getNextFrame()).image;
      const density = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};
      for (final MapEntry(key: d, value: x) in density.entries) {
        // Adaptive foreground: 108 dp, full bleed. Legacy: 48 dp, pre-shaped.
        await _save(await _render((108 * x).round(), MountIcon(shot, scale: 0.62)),
            '$_res/mipmap-$d/ic_launcher_foreground.png');
        await _save(await _render((48 * x).round(), MountIcon(shot, scale: 0.92, rounded: true)),
            '$_res/mipmap-$d/ic_launcher.png');
      }
      // iOS: one full-bleed square per entry of the asset catalogue; the
      // system rounds the corners.
      const ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
      final icons = jsonDecode(File('$ios/Contents.json').readAsStringSync())['images'] as List;
      for (final i in icons.cast<Map<String, dynamic>>()) {
        final pt = double.parse((i['size'] as String).split('x').first);
        final px = (pt * double.parse((i['scale'] as String).replaceAll('x', ''))).round();
        await _save(await _render(px, MountIcon(shot, scale: 0.92)), '$ios/${i['filename']}');
      }

      final preview = Platform.environment['APP_ICON_PREVIEW'];
      if (preview == null) return;
      // The adaptive layer as launchers cut it: the middle 72 of 108 dp,
      // masked to a circle, a squircle and a rounded square.
      final layer = await _render(432, MountIcon(shot, scale: 0.62));
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawRect(const Rect.fromLTWH(0, 0, 1000, 360), Paint()..color = const Color(0xFF2B3442));
      final masks = <Path Function(Rect)>[
        (r) => Path()..addOval(r),
        (r) => Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.38))),
        (r) => Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.20))),
      ];
      for (final (i, mask) in masks.indexed) {
        final dst = Rect.fromLTWH(50.0 + i * 320, 40, 280, 280);
        c.save();
        c.clipPath(mask(dst));
        // 288 px of 432 is the visible 72 dp.
        c.drawImageRect(layer, const Rect.fromLTWH(72, 72, 288, 288), dst, Paint());
        c.restore();
      }
      await _save(await rec.endRecording().toImage(1000, 360), preview);
    });
  });
}
