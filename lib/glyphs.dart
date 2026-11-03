import 'dart:math';

import 'package:flutter/material.dart';

/// The dash's icons, on Material's 24-unit grid with one stroke and round
/// ends. Frunk, trunk, recirculation, charge port and the doors are the
/// car's own icons: traced from photos of its screen and of its manual door
/// release, then cleaned up as vectors. The headlamps are the standard
/// symbols the car's indicators use. Code, not files: nothing to load.
enum Glyph {
  frunk,
  trunk,
  mirrorTilt,
  recirc,
  interiorLight,
  chargePort,
  doorFL,
  doorFR,
  doorRL,
  doorRR,
  lowBeam,
  highBeam,
  drl,
  grip,
  fan,
  fanOff,
}

class GlyphIcon extends StatelessWidget {
  const GlyphIcon(this.glyph, {super.key, this.size = 24, this.color});

  final Glyph glyph;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _GlyphPainter(glyph, color ?? IconTheme.of(context).color ?? Colors.white),
      );
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);

  final Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // The traced icons; the right-hand doors, the frunk and the trunk face
    // the other way.
    if (_traced[glyph] case (final strokes, final fills)) {
      if (const {Glyph.doorFR, Glyph.doorRR, Glyph.frunk, Glyph.trunk}.contains(glyph)) {
        canvas
          ..translate(24, 0)
          ..scale(-1, 1);
      }
      for (final p in strokes) {
        canvas.drawPath(p, line);
      }
      for (final p in fills) {
        canvas.drawPath(p, Paint()..color = color);
      }
      return;
    }
    switch (glyph) {
      case Glyph.mirrorTilt:
        // The door mirror on its arm, and the way it dips.
        canvas.drawRRect(
            RRect.fromLTRBR(2.8, 4, 14.6, 11.4, const Radius.circular(3.4)), line);
        canvas.drawPath(
            Path()
              ..moveTo(14.6, 7.7)
              ..lineTo(19.6, 7.7)
              ..lineTo(19.6, 11.2)
              ..moveTo(8.7, 14.2)
              ..lineTo(8.7, 21)
              ..moveTo(5.8, 18.1)
              ..lineTo(8.7, 21)
              ..lineTo(11.6, 18.1),
            line);
      case Glyph.interiorLight:
        // A dome lamp under the headliner, shining down.
        canvas.drawLine(const Offset(3.4, 5), const Offset(20.6, 5), line);
        canvas.drawArc(
            Rect.fromCircle(center: const Offset(12, 5), radius: 4.4), 0, pi, false, line);
        for (final (a, b) in const [
          (Offset(12, 12.4), Offset(12, 16)),
          (Offset(7.6, 11.2), Offset(5.6, 14)),
          (Offset(16.4, 11.2), Offset(18.4, 14)),
          (Offset(4.8, 9), Offset(2.6, 10.2)),
          (Offset(19.2, 9), Offset(21.4, 10.2)),
        ]) {
          canvas.drawLine(a, b, line);
        }
      case Glyph.grip:
        // The stability-control symbol: a car over two skidding tracks.
        canvas.drawPath(
            Path()
              ..moveTo(4.6, 9.4)
              ..lineTo(7, 4.6)
              ..lineTo(17, 4.6)
              ..lineTo(19.4, 9.4),
            line);
        canvas.drawRRect(
            RRect.fromLTRBR(3.2, 9.4, 20.8, 14.4, const Radius.circular(2.2)), line);
        for (final x in const [8.2, 15.8]) {
          canvas.drawPath(
              Path()
                ..moveTo(x, 16.6)
                ..cubicTo(x - 2.8, 17.8, x + 2.8, 19.6, x, 21.2),
              line);
        }
      case Glyph.fan || Glyph.fanOff:
        // Four blades round a hub; off, struck through with a gap each side.
        final off = glyph == Glyph.fanOff;
        if (off) canvas.saveLayer(const Rect.fromLTWH(0, 0, 24, 24), Paint());
        final fill = Paint()..color = color;
        for (var i = 0; i < 4; i++) {
          canvas
            ..drawPath(_blade, fill)
            ..translate(12, 12)
            ..rotate(pi / 2)
            ..translate(-12, -12);
        }
        canvas.drawCircle(const Offset(12, 12), 1.8, fill);
        if (off) {
          const a = Offset(3.6, 3.6), b = Offset(20.4, 20.4);
          canvas
            ..drawLine(a, b, Paint()
              ..blendMode = BlendMode.clear
              ..strokeWidth = 5.2)
            ..drawLine(a, b, line)
            ..restore();
        }
      default:
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color;
}

final _traced = <Glyph, (List<Path>, List<Path>)>{
  Glyph.frunk: (_frunkStrokes, _frunkFills),
  Glyph.trunk: (_trunkStrokes, _trunkFills),
  Glyph.recirc: (_recircStrokes, _recircFills),
  Glyph.chargePort: (_boltStrokes, _boltFills),
  Glyph.doorFL: ([_door(front: true)], _doorFills),
  Glyph.doorFR: ([_door(front: true)], _doorFills),
  Glyph.doorRL: ([_door(front: false)], _doorFills),
  Glyph.doorRR: ([_door(front: false)], _doorFills),
  Glyph.lowBeam: (_lowBeamStrokes, <Path>[]),
  Glyph.highBeam: (_highBeamStrokes, <Path>[]),
  Glyph.drl: (<Path>[], _drlFills),
};

// Generated from the vectorised photos (stroke 1.9 throughout).
final _frunkStrokes = [
  Path()..moveTo(14.1, 16.64)..cubicTo(14.1, 18.59, 12.51, 20.18, 10.56, 20.18)..cubicTo(8.62, 20.18, 7.03, 18.59, 7.03, 16.64)..cubicTo(7.03, 14.69, 8.62, 13.1, 10.56, 13.1)..cubicTo(12.51, 13.1, 14.1, 14.69, 14.1, 16.64)..close(),
  Path()..moveTo(7.39, 18.2)..lineTo(3.95, 17.67)..cubicTo(3.37, 17.58, 2.95, 17.08, 2.95, 16.5)..lineTo(2.95, 12.57)..cubicTo(2.95, 11.4, 9.29, 9.4, 12.87, 9.4)..lineTo(16.1, 9.4)..lineTo(21.05, 7.03),
  Path()..moveTo(13.77, 18.11)..lineTo(21.05, 18.11),
  Path()..moveTo(6, 3.82)..cubicTo(9.28, 3.82, 13.77, 6.44, 16.45, 9.23),
];
final _frunkFills = <Path>[];
final _trunkStrokes = [
  Path()..moveTo(2.95, 5.38)..cubicTo(11.56, 5.38, 11.74, 8.46, 20.24, 9.96)..cubicTo(20.59, 10.02, 20.81, 10.36, 20.73, 10.71)..cubicTo(19.97, 13.84, 20.74, 12.99, 21.03, 15.5)..cubicTo(21.19, 16.82, 20.17, 18.06, 18.83, 18.06)..lineTo(15.58, 18.06),
  Path()..moveTo(13.85, 8.08)..lineTo(18.54, 3.93)..lineTo(20.15, 4.94),
  Path()..moveTo(2.95, 18.06)..lineTo(9.29, 18.06),
  Path()..moveTo(15.91, 16.59)..cubicTo(15.91, 18.52, 14.36, 20.07, 12.43, 20.07)..cubicTo(10.51, 20.07, 8.95, 18.52, 8.95, 16.59)..cubicTo(8.95, 14.67, 10.51, 13.11, 12.43, 13.11)..cubicTo(14.36, 13.11, 15.91, 14.67, 15.91, 16.59)..close(),
];
final _trunkFills = <Path>[];
/// The car's door-release icon turned a quarter left, as it sits on the
/// door, so it reads as the car from above, nose up, with a door swung open
/// on its left side: the outline is the body, the gap the door opening, the
/// slanted stroke the door on its front hinge. A front door opens near the
/// nose, a rear one near the tail. Shapes and corners from the traced photo.
Path _door({required bool front}) {
  const k = 0.5523, l = 8.6, r = 19.0, t = 3.4, b = 20.6;
  final hinge = front ? 7.0 : 12.2, end = hinge + 7.0; // the opening
  return Path()
    ..moveTo(l, end)
    ..lineTo(l, b - 1.4)
    ..cubicTo(l, b - 1.4 + 1.4 * k, l + 1.4 - 1.4 * k, b, l + 1.4, b)
    ..lineTo(r - 2.2, b)
    ..cubicTo(r - 2.2 + 2.2 * k, b, r, b - 2.2 + 2.2 * k, r, b - 2.2)
    ..lineTo(r, t + 2.2)
    ..cubicTo(r, t + 2.2 - 2.2 * k, r - 2.2 + 2.2 * k, t, r - 2.2, t)
    ..lineTo(l + 3.6, t)
    ..cubicTo(l + 3.6 - 3.6 * k, t, l, t + 3.6 - 3.6 * k, l, t + 3.6)
    ..lineTo(l, hinge)
    ..lineTo(l - 3.6, hinge + 4.56);
}

final _doorFills = <Path>[];
// One fan blade, from the hub up and swept clockwise; the fan turns it four
// times.
final _blade = Path()
  ..moveTo(12, 10.2)
  ..cubicTo(10.4, 8.8, 10.1, 4.6, 12.3, 2.9)
  ..cubicTo(14.4, 1.4, 17.8, 3.4, 16.5, 6.5)
  ..cubicTo(15.7, 8.4, 13.6, 9.3, 12, 10.2)
  ..close();
final _recircStrokes = [
  Path()..moveTo(6.53, 16.9)..lineTo(5.93, 16.9)..cubicTo(4.28, 16.9, 2.95, 15.57, 2.95, 13.92)..lineTo(2.95, 7.8)..cubicTo(2.95, 6.15, 4.28, 4.82, 5.93, 4.82)..lineTo(18.07, 4.82)..cubicTo(19.72, 4.82, 21.05, 6.15, 21.05, 7.8)..lineTo(21.05, 13.92)..cubicTo(21.05, 15.57, 19.72, 16.9, 18.07, 16.9)..lineTo(14.09, 16.9),
];
final _recircFills = [
  Path()..moveTo(9.79, 17.45)..cubicTo(9.44, 17.17, 9.44, 16.63, 9.79, 16.36)..lineTo(12.95, 13.83)..cubicTo(13.41, 13.46, 14.09, 13.79, 14.09, 14.38)..lineTo(14.09, 19.43)..cubicTo(14.09, 20.02, 13.41, 20.34, 12.95, 19.98)..close(),
];
final _boltStrokes = <Path>[];
final _boltFills = [
  Path()..moveTo(5.29, 13.23)..lineTo(11.75, 2.2)..cubicTo(11.95, 1.85, 12.49, 1.99, 12.49, 2.4)..lineTo(12.49, 9.77)..cubicTo(12.49, 9.99, 12.67, 10.17, 12.89, 10.17)..lineTo(18.37, 10.17)..cubicTo(18.67, 10.17, 18.87, 10.51, 18.71, 10.77)..lineTo(12.25, 21.8)..cubicTo(12.05, 22.15, 11.51, 22.01, 11.51, 21.6)..lineTo(11.51, 14.23)..cubicTo(11.51, 14.01, 11.33, 13.83, 11.11, 13.83)..lineTo(5.63, 13.83)..cubicTo(5.33, 13.83, 5.13, 13.49, 5.29, 13.23)..close(),
];
// The lamp symbols of ISO 7000 (0082 high beam, 0083 low beam, 2611
// daytime running lights), the ones the car's own indicators follow, from
// the standard's SVGs: the lamp at the centre of its outline, four beams
// rather than five so they stay apart at the dash's 20 dp.
final _lamp = Path()..moveTo(11.57, 6.07)..lineTo(14.55, 6.07)..cubicTo(16.72, 6.07, 18.68, 6.73, 20.09, 7.8)..cubicTo(21.51, 8.88, 22.39, 10.36, 22.39, 12)..cubicTo(22.39, 13.64, 21.51, 15.12, 20.09, 16.2)..cubicTo(18.68, 17.27, 16.72, 17.93, 14.55, 17.93)..lineTo(11.57, 17.93)..cubicTo(10.11, 14.27, 10.11, 9.73, 11.57, 6.07)..close();
final _lowBeamStrokes = [
  _lamp,
  Path()..moveTo(3.31, 8.86)..lineTo(8.35, 6.96),
  Path()..moveTo(3.29, 12.53)..lineTo(7.69, 10.68),
  Path()..moveTo(3.29, 16.23)..lineTo(7.7, 14.38),
  Path()..moveTo(3.31, 19.97)..lineTo(8.44, 18.04),
];
final _highBeamStrokes = [
  _lamp,
  Path()..moveTo(2.56, 6.55)..lineTo(8.32, 6.55),
  Path()..moveTo(2.56, 10.18)..lineTo(7.62, 10.18),
  Path()..moveTo(2.56, 13.82)..lineTo(7.62, 13.82),
  Path()..moveTo(2.56, 17.45)..lineTo(8.32, 17.45),
];
final _drlFills = [
  Path()..moveTo(14.21, 6.53)..cubicTo(18.46, 6.53, 21.91, 8.98, 21.91, 12)..cubicTo(21.91, 15.02, 18.46, 17.47, 14.21, 17.47)..lineTo(12.65, 17.35)..cubicTo(11.03, 15.39, 11.03, 8.61, 12.65, 6.65)..close(),
  Path()..moveTo(10.56, 8.04)..cubicTo(10.56, 8.59, 10.11, 9.04, 9.56, 9.04)..cubicTo(9.01, 9.04, 8.56, 8.59, 8.56, 8.04)..cubicTo(8.56, 7.49, 9.01, 7.04, 9.56, 7.04)..cubicTo(10.11, 7.04, 10.56, 7.49, 10.56, 8.04)..close(),
  Path()..moveTo(7.36, 8.04)..cubicTo(7.36, 8.46, 7.01, 8.81, 6.59, 8.81)..cubicTo(6.16, 8.81, 5.82, 8.46, 5.82, 8.04)..cubicTo(5.82, 7.62, 6.16, 7.27, 6.59, 7.27)..cubicTo(7.01, 7.27, 7.36, 7.62, 7.36, 8.04)..close(),
  Path()..moveTo(4.61, 8.04)..cubicTo(4.61, 8.38, 4.34, 8.65, 4, 8.65)..cubicTo(3.66, 8.65, 3.39, 8.38, 3.39, 8.04)..cubicTo(3.39, 7.7, 3.66, 7.43, 4, 7.43)..cubicTo(4.34, 7.43, 4.61, 7.7, 4.61, 8.04)..close(),
  Path()..moveTo(9.26, 11.99)..cubicTo(9.26, 12.54, 8.82, 12.99, 8.27, 12.99)..cubicTo(7.71, 12.99, 7.27, 12.54, 7.27, 11.99)..cubicTo(7.27, 11.44, 7.71, 11, 8.27, 11)..cubicTo(8.82, 11, 9.26, 11.44, 9.26, 11.99)..close(),
  Path()..moveTo(6.06, 11.99)..cubicTo(6.06, 12.42, 5.72, 12.76, 5.29, 12.76)..cubicTo(4.87, 12.76, 4.52, 12.42, 4.52, 11.99)..cubicTo(4.52, 11.57, 4.87, 11.22, 5.29, 11.22)..cubicTo(5.72, 11.22, 6.06, 11.57, 6.06, 11.99)..close(),
  Path()..moveTo(3.31, 11.99)..cubicTo(3.31, 12.33, 3.04, 12.6, 2.7, 12.6)..cubicTo(2.37, 12.6, 2.09, 12.33, 2.09, 11.99)..cubicTo(2.09, 11.66, 2.37, 11.38, 2.7, 11.38)..cubicTo(3.04, 11.38, 3.31, 11.66, 3.31, 11.99)..close(),
  Path()..moveTo(10.56, 15.95)..cubicTo(10.56, 16.5, 10.11, 16.95, 9.56, 16.95)..cubicTo(9.01, 16.95, 8.56, 16.5, 8.56, 15.95)..cubicTo(8.56, 15.4, 9.01, 14.95, 9.56, 14.95)..cubicTo(10.11, 14.95, 10.56, 15.4, 10.56, 15.95)..close(),
  Path()..moveTo(7.36, 15.95)..cubicTo(7.36, 16.37, 7.01, 16.72, 6.59, 16.72)..cubicTo(6.16, 16.72, 5.82, 16.37, 5.82, 15.95)..cubicTo(5.82, 15.52, 6.16, 15.18, 6.59, 15.18)..cubicTo(7.01, 15.18, 7.36, 15.52, 7.36, 15.95)..close(),
  Path()..moveTo(4.61, 15.95)..cubicTo(4.61, 16.28, 4.34, 16.56, 4, 16.56)..cubicTo(3.66, 16.56, 3.39, 16.28, 3.39, 15.95)..cubicTo(3.39, 15.61, 3.66, 15.34, 4, 15.34)..cubicTo(4.34, 15.34, 4.61, 15.61, 4.61, 15.95)..close(),
];
