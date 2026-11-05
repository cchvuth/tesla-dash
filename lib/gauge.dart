import 'dart:math';

import 'package:flutter/material.dart';

/// The dash's face. Named rather than inherited: painter text does not read
/// the theme, and a phone set to a decorative system font should not get to
/// redraw the speedometer.
const kFont = 'Roboto';

const kAccent = Color(0xFF4EA1FF);
const kRegen = Color(0xFF3DDC97);
const kAlert = Color(0xFFE23D3D);

/// A button that is on: a solid light blue that reads in sunlight.
const kLit = Color(0xFF9CD3FF);

/// Cold enough to matter: ice on the road, a pack that holds back.
const kCold = Color(0xFF8FD8FF);

/// Look now, not yet alarming: the car stepping in, a limit, stale air.
const kWarn = Color(0xFFFFB020);

/// Two arcs of one ring: left third rear motor, right third front motor.
/// Speed sits in the hole, the gear at its foot.
///
/// Motor sectors put zero 15° below the middle: power climbs towards the top of the
/// ring, regen drops below it in green. Scaled for everyday driving, not the
/// motor's peak — a 250 kW span never moved off the bottom in traffic.
/// [regenCapKw]: the most regen the pack takes now (less when cold or
/// full), red on the regen side past it.
class RingGauge extends StatefulWidget {
  const RingGauge({
    super.key,
    required this.frontKw,
    required this.rearKw,
    this.regenCapKw,
    this.maxKw = 160,
    this.minKw = -60,
    this.glideAll = true,
    required this.child,
  });

  final double? frontKw, rearKw, regenCapKw;
  final double maxKw, minKw;
  final Widget child;

  /// Glide on every change. Off, a change under [_jumpKw] lands at once and
  /// only a jump glides: the screen then redraws as the data comes (30 a
  /// second) instead of at its full rate, a third less CPU in a replay.
  final bool glideAll;

  @override
  State<RingGauge> createState() => _RingGaugeState();
}

class _RingGaugeState extends State<RingGauge> {
  static const _glide = Duration(milliseconds: 140);
  static const _jumpKw = 2.0;
  DateTime _glideUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void didUpdateWidget(RingGauge old) {
    super.didUpdateWidget(old);
    final jump = ((widget.frontKw ?? 0) - (old.frontKw ?? 0)).abs() >= _jumpKw ||
        ((widget.rearKw ?? 0) - (old.rearKw ?? 0)).abs() >= _jumpKw;
    // A jump glides, and so does whatever comes while it does: landing at
    // once mid-glide would be the very jump it smooths.
    if (jump) _glideUntil = DateTime.now().add(_glide);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final glide = w.glideAll || DateTime.now().isBefore(_glideUntil);
    return TweenAnimationBuilder<_Vals>(
        tween: _ValsTween(end: _Vals(
          (w.frontKw ?? 0).clamp(w.minKw, w.maxKw).toDouble(),
          (w.rearKw ?? 0).clamp(w.minKw, w.maxKw).toDouble(),
        )),
        duration: glide ? _glide : Duration.zero,
        curve: Curves.easeOut,
        builder: (context, v, _) => CustomPaint(
          painter: _RingPainter(
            v,
            known: (w.frontKw != null, w.rearKw != null),
            cap: w.regenCapKw,
            maxKw: w.maxKw,
            minKw: w.minKw,
          ),
          child: Center(child: w.child),
        ),
      );
  }
}

class _Vals {
  const _Vals(this.front, this.rear);
  final double front, rear;
  _Vals lerp(_Vals o, double t) => _Vals(
        front + (o.front - front) * t,
        rear + (o.rear - rear) * t,
      );
}

class _ValsTween extends Tween<_Vals> {
  _ValsTween({required _Vals end}) : super(begin: end, end: end);
  @override
  _Vals lerp(double t) => (begin ?? end!).lerp(end!, t);
}

double _deg(double d) => d * pi / 180;

class _RingPainter extends CustomPainter {
  _RingPainter(
    this.v, {
    required this.known,
    required this.cap,
    required this.maxKw,
    required this.minKw,
  });

  final _Vals v;
  final (bool, bool) known;
  final double? cap;
  final double maxKw, minKw;

  // Sector angles, canvas convention: 0° = right, clockwise positive.
  static final _gap = _deg(4);
  static final _left = (start: _deg(120) + _gap, sweep: _deg(120) - 2 * _gap);
  static final _right = (start: _deg(-60) + _gap, sweep: _deg(120) - 2 * _gap);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = min(size.width, size.height) / 2 - 6;
    final rect = Rect.fromCircle(center: c, radius: r);
    final w = r * 0.085;

    Paint stroke(Color color) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.butt
      ..color = color;
    void arc(double start, double sweep, Color color) =>
        canvas.drawArc(rect, start, sweep, false, stroke(color));

    // Empty track: a hairline, so only the live fill reads as weight.
    for (final s in [_left, _right]) {
      canvas.drawArc(rect, s.start, s.sweep, false,
          stroke(Colors.white24)..strokeWidth = 1.5);
    }

    // Rear: left sector, zero 15° below halfway, power climbing clockwise
    // towards the top, regen dropping back towards the bottom. Power gets the
    // longer span, as it has the bigger range.
    final half = _left.sweep / 2;
    final drop = _deg(15);
    final zl = _left.start + half - drop, zr = _right.start + half + drop;
    _motor(arc, v.rear, zero: zl, posSpan: half + drop, negSpan: half - drop, up: true);
    // Front: mirror image.
    _motor(arc, v.front, zero: zr, posSpan: half + drop, negSpan: half - drop, up: false);

    // Regen the pack cannot take now, red past the cap. The cap is the whole
    // pack's, so a motor's share is what the other is not already using: a
    // fill that reaches its red is regen at the cap.
    if (cap case final total?) {
      void capped(double kw, double zero, bool up) {
        final at = kw.clamp(0, -minKw) / -minKw * (half - drop); // from zero to the cap
        final rest = half - drop - at;
        if (rest <= 0) return;
        canvas.drawArc(rect, up ? zero - (half - drop) : zero + at, rest, false,
            stroke(kAlert)..strokeWidth = w * 0.3);
      }

      capped(total - max(0, -v.front), zl, true);
      capped(total - max(0, -v.rear), zr, false);
    }

    // Zero ticks on the motor sectors.
    for (final a in [zl, zr]) {
      final d = Offset(cos(a), sin(a));
      canvas.drawLine(c + d * (r - w), c + d * (r + w * 0.4),
          Paint()..color = Colors.white54..strokeWidth = 2);
    }

    // Sector readouts, just inside the ring.
    final ri = r * 0.72;
    _label(canvas, known.$2 ? '${v.rear.round()}' : '—', c + Offset(-ri, -r * 0.06), r * 0.16, Colors.white, weight: FontWeight.w200);
    // Two short lines: one line this size reached the arc.
    _label(canvas, 'kW\nREAR', c + Offset(-ri, r * 0.155), r * 0.085, Colors.white70, spacing: 0.5);
    _label(canvas, known.$1 ? '${v.front.round()}' : '—', c + Offset(ri, -r * 0.06), r * 0.16, Colors.white, weight: FontWeight.w200);
    _label(canvas, 'kW\nFRONT', c + Offset(ri, r * 0.155), r * 0.085, Colors.white70, spacing: 0.5);
  }

  void _motor(void Function(double, double, Color) arc, double kw,
      {required double zero, required double posSpan, required double negSpan, required bool up}) {
    if (kw >= 0) {
      final s = posSpan * kw / maxKw;
      arc(up ? zero : zero - s, s, kAccent);
    } else {
      final s = negSpan * kw / minKw;
      arc(up ? zero - s : zero, s, kRegen);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.v != v || old.known != known || old.cap != cap;
}

void _label(Canvas canvas, String s, Offset at, double size, Color color,
    {FontWeight weight = FontWeight.w500, double spacing = 0}) {
  final tp = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        fontFamily: kFont,
        color: color,
        fontSize: size,
        fontWeight: weight,
        letterSpacing: spacing,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
}
