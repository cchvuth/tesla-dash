// The pieces both layouts in main.dart are built from: the ring's centre,
// the side columns' cards, the buttons and the bottom bar. A part of
// main.dart, so they stay private to it.
part of 'main.dart';

/// Digital speed in the ring's hole, the limit sign above it, the cruise or
/// charge cue below; under them the gear, where [gear] asks for it (the
/// compact dash has it in its corner).
class _Centre extends StatelessWidget {
  const _Centre({required this.obd, this.gear = false});

  final Panda obd;
  final bool gear;

  @override
  Widget build(BuildContext context) {
    final o = obd;
    // Charging in P: the power going in, where the speed would be.
    final charge = o.wifiLive && o.charging && o.gear == 'P' && o.chargeKw != null;
    final cue = _cue(charge);
    return LayoutBuilder(
        builder: (context, c) => Stack(alignment: Alignment.center, children: [
          Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Scaled to the ring's hole, never past it, whatever the digits.
            SizedBox(
              width: c.maxWidth * 0.50,
              height: c.maxHeight * 0.40,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Text(
                  charge ? o.chargeKw!.round().toString() : o.live ? o.speed.round().toString() : '—',
                  style: TextStyle(
                    fontSize: 200,
                    height: 1,
                    fontWeight: FontWeight.w200,
                    // Dim when there is no data, so the dash reads as a gap.
                    color: charge ? kRegen : o.live ? Colors.white : Colors.white24,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            Text(charge ? 'kW' : o.speedUnit,
                style: const TextStyle(
                    color: Colors.white60, letterSpacing: 3, fontSize: 15)),
          ],
          ),
          // One short line below, mirroring the limit sign above: the speed
          // stays centred. As wide as the digits, which is also where the
          // ring's arc closes in at that height; longer lines shrink.
          if (cue != null)
            Positioned(
              bottom: c.maxHeight * 0.17,
              child: SizedBox(
                width: c.maxWidth * 0.5,
                height: c.maxHeight * 0.075,
                child: FittedBox(fit: BoxFit.scaleDown, child: cue),
              ),
            ),
          // The limit above the speed, scaled to the ring; the speed stays
          // centred between the kW readouts.
          Positioned(
            top: c.maxHeight * 0.1,
            child: SizedBox.square(
              dimension: c.maxHeight * 0.16,
              child: FittedBox(child: _SpeedLimit(limit: obd.speedLimit)),
            ),
          ),
          // Only the gear engaged, in the gap the ring leaves at its foot.
          if (gear)
            Positioned(
              bottom: c.maxHeight * 0.02,
              child: Text(o.gear,
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: const {'P', 'R', 'N', 'D'}.contains(o.gear) ? Colors.white : Colors.white38)),
            ),
        ]),
      );
  }

  /// The line under the speed: charging, the most the pack takes now and
  /// why; else the cruise set speed and gap while cruise holds one. (A
  /// regen cap shows on the ring itself.)
  Widget? _cue(bool charge) {
    final o = obd;
    const s = TextStyle(fontSize: 15, letterSpacing: 1, fontWeight: FontWeight.w600);
    if (charge) {
      final max = o.chargeMaxKw, why = o.chargeWhy;
      if (max == null && why == null) return null;
      return Text.rich(TextSpan(children: [
        if (max != null) TextSpan(text: 'MAX ${max.round()}', style: s.copyWith(color: Colors.white70)),
        if (why != null) TextSpan(text: '${max != null ? ' · ' : ''}$why', style: s.copyWith(color: kWarn)),
      ]));
    }
    final set = o.wifiLive ? o.cruiseSet : null;
    if (set != null) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Text('SET ${set.round()}', style: s.copyWith(color: kAccent)),
        if (o.followGap case final gap?) ...[
          const SizedBox(width: 10),
          const Icon(Icons.directions_car_filled, size: 16, color: kAccent),
          Text(' $gap', style: s.copyWith(color: kAccent)),
        ],
      ]);
    }
    return null;
  }
}

/// Column beside the ring.
class _SideColumn extends StatelessWidget {
  const _SideColumn({required this.children});

  final List<Widget> children;

  // Shrinks rather than overflows: a large font, or two cards at once.
  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) => FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: box.maxWidth, // bounded, for the rows that expand
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in children)
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), child: c),
              ],
            ),
          ),
        ),
      );
}

/// The route the car is driving, along the foot of the dash: time to go,
/// arrival time, the route's length and the energy it takes, range at
/// arrival (with what the route takes of the range now) and battery at
/// arrival, each after its icon, and the destination under them; the
/// compact dash has the essentials in one line. Shown while the bus says a
/// route is set, so a finished route never lingers whatever the Commander
/// last pushed; without the bus (no WiFi) it trusts the Commander alone, as
/// the Dash does. Minutes and the battery at arrival come off the bus, else
/// from the Commander; the length and the destination only over Bluetooth,
/// from the car's API through the Commander's own link to the car. Values
/// without data stay hidden.
class _Nav extends StatelessWidget {
  const _Nav({required this.obd, required this.bt, this.oneLine = false});

  final Panda obd;
  final Commander bt;
  final bool oneLine; // the compact dash: one row under the ring

  @override
  Widget build(BuildContext context) {
    final o = obd, bus = o.wifiLive; // without WiFi its route values are stale
    // The bus first; its 0 (none, or the last minute) lets the Commander's in.
    final mins = bus && (o.navMinutes ?? 0) > 0 ? o.navMinutes! : bt.navMinutes ?? 0;
    final route = bus && o.frames.containsKey(0x238)
        ? o.navRoute
        : bt.navDest != null || mins > 0;
    if (!route) return const SizedBox.shrink();
    final trip = mins > 0; // none yet, or a finished route's zeros
    final m = mins.round();
    // At arrival: the battery % worked out from the bus, else the
    // Commander's (the car's own, once it is linked to the infotainment);
    // the range left from that % and the battery now.
    final pct = trip ? (bus ? o.arrivePct : null) ?? bt.navArrivePct : null;
    final kwh = bus ? o.navEnergyKwh : null;
    final left = trip ? o.rangeAt(pct) : null;
    final dist = left == null ? null : '${left.round()} ${o.rangeUnit}';
    // Beside it, what the route takes of the range now.
    final drop = left == null || o.range == null ? 0 : (o.range! - left).round();
    // The route's own length, which the Commander gives in miles, to a
    // tenth while short as the car's screen does; and the energy it takes.
    final mi = trip ? bt.navMiles : null, len = mi == null ? null : o.kph ? mi * 1.609344 : mi;
    final length = len == null ? null : '${len < 9.95 ? len.toStringAsFixed(1) : len.round()} ${o.rangeUnit}';
    final use = trip ? o.tripKwh(pct) : null;
    final energy = pct != null ? '${pct.round()}%' : kwh != null ? '${kwh.toStringAsFixed(1)} kWh' : null;
    // Lines set tight: with the destination the two still fit the bar's
    // height at the text cap, so the ring keeps its size as a route comes
    // and goes.
    const big = TextStyle(
        fontSize: 18, height: 1.1, color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]);
    final togo = m < 1 ? '<1 min' : m < 60 ? '$m min' : '${m ~/ 60}h ${m % 60}m';
    // The arrival clock, in the phone's 12 or 24 hour format.
    final clock = TimeOfDay.fromDateTime(
            DateTime.now().add(Duration(seconds: (mins * 60).round())))
        .format(context);
    // Every value after its icon; [note]: a smaller grey figure after it.
    Widget stat(IconData icon, String text, {TextStyle style = big, String? note}) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: Colors.white70),
          const SizedBox(width: 4),
          Text.rich(
              TextSpan(text: text, children: [
                if (note != null)
                  TextSpan(text: note, style: const TextStyle(fontSize: 14, color: Colors.white54)),
              ]),
              style: style),
        ]);
    final battery = energy == null
        ? null
        : stat(Icons.battery_std, energy, style: (pct ?? 100) < 10 ? big.copyWith(color: kAlert) : big);
    // One line, scaled to the width it has, never wrapped.
    final line = FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(mainAxisSize: MainAxisSize.min, spacing: oneLine ? 14 : 20, children: [
        if (trip) ...[stat(Icons.hourglass_bottom, togo), stat(Icons.flag, clock)],
        if (!oneLine && length != null) stat(Icons.route, length),
        if (!oneLine && use != null) stat(Icons.bolt, '${use.toStringAsFixed(1)} kWh'),
        if (dist != null) stat(Icons.electric_car, dist, note: oneLine || drop <= 0 ? null : ' −$drop'),
        ?battery,
      ]),
    );
    // On a light grey card, set apart from the link icons and buttons.
    // As much room above and below as the bar allows: the place's line
    // under the name takes most of it.
    Widget card(Widget child) => Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: bt.navDest == null ? 3 : 1),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(12),
          ),
          child: child,
        );
    // Nothing to put on the line yet (the route's fields come round slowly).
    final blank = !trip && dist == null && energy == null && (oneLine || length == null);
    if (oneLine) return blank ? const SizedBox.shrink() : card(line);
    return card(Column(mainAxisSize: MainAxisSize.min, children: [
      // Its name, top centre, with the place beside it once Bluetooth has
      // one: two lines at most, so the bar grows no taller.
      Row(mainAxisSize: MainAxisSize.min, children: [
        const Text('DESTINATION', style: TextStyle(fontSize: 10, height: 1.2, letterSpacing: 1.5, color: Colors.white70)),
        if (bt.navDest case final dest?) ...[
          const SizedBox(width: 10),
          const Icon(Icons.place, size: 15, color: Colors.white70),
          const SizedBox(width: 4),
          Flexible(
            child: Text(dest,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, height: 1.1, color: Colors.white)),
          ),
        ],
      ]),
      if (!blank) line,
    ]));
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {required this.live, this.color = kAccent});

  final String text;
  final bool live;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // Red solid, not just another hue: it must not pass for the amber
    // level at a glance, in sunlight or to a colour-blind eye.
    final solid = live && color == kAlert;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: solid ? kAlert : live ? color.withValues(alpha: 0.18) : Colors.white10,
        border: Border.all(color: live ? color : Colors.white38),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 13,
              letterSpacing: 1.2,
              fontWeight: solid ? FontWeight.w700 : null,
              color: solid ? Colors.white : live ? color : Colors.white70)),
    );
  }
}

enum _Side { left, right, bottom }

/// A soft coloured glow along one screen edge.
class _Edge extends StatelessWidget {
  const _Edge({required this.side, required this.color});

  final _Side side;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final horizontal = side != _Side.bottom;
    return IgnorePointer(
      child: Align(
        alignment: switch (side) {
          _Side.left => Alignment.centerLeft,
          _Side.right => Alignment.centerRight,
          _Side.bottom => Alignment.bottomCenter,
        },
        child: Container(
          width: horizontal ? 70 : double.infinity,
          height: horizontal ? double.infinity : 45,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: switch (side) {
                _Side.left => Alignment.centerLeft,
                _Side.right => Alignment.centerRight,
                _Side.bottom => Alignment.bottomCenter,
              },
              end: switch (side) {
                _Side.left => Alignment.centerRight,
                _Side.right => Alignment.centerLeft,
                _Side.bottom => Alignment.topCenter,
              },
              colors: [color.withValues(alpha: 0.75), color.withValues(alpha: 0)],
            ),
          ),
        ),
      ),
    );
  }
}

/// The bar along the bottom: the link icons on the left, the route, Google
/// Maps and the car panel on the right.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.obd,
    required this.bt,
    required this.onWifi,
    required this.onBt,
    required this.onMaps,
  });

  final Panda obd;
  final Commander bt;
  final VoidCallback onWifi, onBt, onMaps;

  @override
  Widget build(BuildContext context) {
    // Each link's state at a glance: a word under its icon, and the seconds
    // left while a timer runs. The words tooltips and snackbars spell out.
    final (wIcon, wColor, wWord) = switch (obd.link) {
      WifiLink.idle => (Icons.wifi_off, Colors.white54, 'IDLE'),
      WifiLink.wifiOff => (Icons.wifi_off, kAlert, 'OFF'),
      WifiLink.scanning => (Icons.wifi_find, kAccent, 'SCAN'),
      WifiLink.joining => (Icons.wifi_find, kAccent, 'JOIN'),
      WifiLink.hello => (Icons.wifi, kAccent, 'HELLO'),
      WifiLink.live => (Icons.wifi, kRegen, 'LIVE'),
      WifiLink.quiet => (Icons.wifi, kWarn, 'QUIET'),
      WifiLink.away => (Icons.wifi_off, Colors.white54, 'AWAY'),
      WifiLink.retrying => (Icons.wifi_find, kWarn, 'RETRY'),
    };
    final (bIcon, bColor, bWord) = switch (bt.link) {
      BtLink.idle => (Icons.bluetooth_disabled, Colors.white54, 'IDLE'),
      BtLink.off => (Icons.bluetooth_disabled, kAlert, 'OFF'),
      BtLink.noLocation => (Icons.location_off, kAlert, 'NO LOC'),
      BtLink.scanning => (Icons.bluetooth_searching, kAccent, 'SCAN'),
      BtLink.linking => (Icons.bluetooth_searching, kAccent, 'LINK'),
      BtLink.approving => (Icons.touch_app, kWarn, 'PRESS'),
      BtLink.refused => (Icons.bluetooth_disabled, kAlert, 'DENIED'),
      // Left to the S3XY Dash on purpose: plain and grey, not a fault.
      BtLink.dash => (Icons.bluetooth, Colors.white54, 'DASH'),
      BtLink.paused => (Icons.pause_circle_outline, kWarn, 'WAIT'),
      BtLink.away => (Icons.bluetooth_searching, Colors.white54, 'AWAY'),
      BtLink.held => (Icons.app_blocking, kAlert, 'HELD'),
      BtLink.retrying => (Icons.bluetooth_searching, kWarn, 'RETRY'),
      BtLink.borrowed => (Icons.bluetooth_connected, kAccent, 'BORROW'),
      BtLink.buttons => (Icons.bluetooth_connected, kAccent, 'ACTION'),
      BtLink.lean => (Icons.bluetooth_connected, kRegen, 'READY'),
      BtLink.full => (Icons.bluetooth_connected, kRegen, 'LIVE'),
    };
    // Settled (WiFi live; Bluetooth ready with its car data), a link shrinks
    // to its icon and leaves the route the room; anything else stands out.
    return Row(children: [
        _LinkButton(
            icon: wIcon, color: wColor, word: wWord, until: obd.until,
            settled: obd.link == WifiLink.live,
            // Live, the speed frames a second: the screen redraws up to 45 a
            // second, so under ~36 the dash waits on the Commander (the car
            // sends about 50).
            stat: obd.link == WifiLink.live && obd.speedKnown ? '${obd.speedHz}' : null,
            statColor: obd.speedHz >= 36 ? Colors.white : obd.speedHz >= 18 ? kWarn : kAlert,
            tip: obd.link == WifiLink.live
                ? 'WiFi: live, ${obd.speedHz} speed frames/s (the car sends about 50), ${obd.frameHz} frames/s in all'
                : 'WiFi: ${obd.status}',
            onTap: onWifi),
        _LinkButton(
            icon: bIcon, color: bColor, word: bWord, until: bt.until,
            settled: bt.link == BtLink.lean || bt.link == BtLink.full,
            tip: 'Commander: ${bt.status}', onTap: onBt),
        // Charging takes the route's place, as in the compact dash.
        Expanded(child: obd.wifiLive && obd.charging ? const SizedBox() : _Nav(obd: obd, bt: bt)),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.map_outlined, color: Colors.white),
          tooltip: 'Google Maps beside the dash',
          onPressed: onMaps,
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.more_horiz, color: Colors.white),
          tooltip: 'More actions',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => CarPanel(bt: bt)),
          ),
        ),
      ]);
  }
}

/// A link's button in the bottom bar: its icon over a word for its state.
/// While a timer runs, a ring round the icon drains to the deadline and the
/// seconds left stand beside it. A big target, for a finger in a moving car;
/// [settled], just a small icon (still the bar's height to tap).
class _LinkButton extends StatefulWidget {
  const _LinkButton({
    required this.icon,
    required this.color,
    required this.word,
    required this.until,
    required this.settled,
    required this.tip,
    required this.onTap,
    this.stat,
    this.statColor = Colors.white,
  });

  /// A small figure under a settled icon.
  final String? stat;
  final Color statColor;
  final IconData icon;
  final Color color;
  final String word, tip;
  final DateTime? until;
  final bool settled;
  final VoidCallback onTap;

  @override
  State<_LinkButton> createState() => _LinkButtonState();
}

class _LinkButtonState extends State<_LinkButton> {
  late final Timer _tick;
  // When this deadline first showed: the ring's full turn.
  DateTime _from = DateTime.now();

  @override
  void initState() {
    super.initState();
    // The countdown moves on its own: the links notify only when they
    // change. Four times a second, so the ring drains smoothly.
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (widget.until != null) setState(() {});
    });
  }

  @override
  void didUpdateWidget(_LinkButton old) {
    super.didUpdateWidget(old);
    if (widget.until != old.until) _from = DateTime.now();
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final until = widget.until, now = DateTime.now();
    final left = until?.difference(now) ?? Duration.zero;
    final secs = (left.inMilliseconds / 1000).ceil();
    final span = until?.difference(_from).inMilliseconds ?? 0;
    final c = widget.color;
    return Tooltip(
      message: widget.tip,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          width: widget.settled ? 36 : 60,
          height: 44,
          child: widget.settled
              // On the big buttons' icon line (its word below), not the
              // bar's middle, so a small and a big one line up.
              ? Align(
                  alignment: const Alignment(0, -0.5),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(widget.icon, size: 18, color: c),
                    if (widget.stat case final s?)
                      Text(s,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              height: 1.1,
                              color: widget.statColor,
                              fontFeatures: const [FontFeature.tabularFigures()])),
                  ]))
              // Scaled while the button grows back, so it never spills.
              : FittedBox(fit: BoxFit.scaleDown, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            // The icon keeps one place whatever the state: a 28 dp spot at
            // the button's middle, the ring round it while a timer runs and
            // the seconds hung beside it, two digits' room, moving nothing.
            SizedBox(
              width: 60,
              height: 28,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox.square(
                  dimension: 28,
                  child: CustomPaint(
                    painter: secs > 0
                        ? _RingPainter(span <= 0 ? 0 : (left.inMilliseconds / span).clamp(0.0, 1.0), c)
                        : null,
                    child: Center(child: Icon(widget.icon, size: secs > 0 ? 16 : 22, color: c)),
                  ),
                ),
                if (secs > 0)
                  Positioned(
                    left: 45,
                    width: 15,
                    top: 0,
                    bottom: 0,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text('$secs',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              height: 1,
                              color: c,
                              fontFeatures: const [FontFeature.tabularFigures()])),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(widget.word,
                  style: TextStyle(fontSize: 10, height: 1.1, letterSpacing: 0.5, color: c)),
            ),
          ])),
        ),
      ),
    );
  }
}

/// A countdown round a link's icon: a faint track, and over it what is
/// left, from the top clockwise.
class _RingPainter extends CustomPainter {
  _RingPainter(this.left, this.color);

  final double left; // 1 at the start, 0 at the deadline
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2);
    Paint stroke(Color c, double w) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..color = c;
    canvas.drawOval(rect, stroke(color.withValues(alpha: 0.18), 2));
    canvas.drawArc(rect, -pi / 2, 2 * pi * left, false, stroke(color, 2.5));
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.left != left || old.color != color;
}

/// S3XY functions, pressed over Bluetooth. Lit from the state the bus already
/// reports over WiFi; dim while they cannot be pressed. Half down each side
/// of the screen ([right] the right-hand one), each door on its own side.
class _Actions extends StatelessWidget {
  const _Actions({required this.obd, required this.bt, required this.onTap, this.right = false});

  final Panda obd;
  final Commander bt;
  final void Function(S3xyAction) onTap;
  final bool right;


  @override
  Widget build(BuildContext context) {
    final o = obd;
    // White when off, solid light blue when on: both read in sunlight. A
    // button that cannot act right now looks the same; a tap says why.
    // Icons only, each the car's own; the name shows on a long press. A
    // stalled link lights nothing; a state only WiFi has, nothing without it.
    // [note]: a figure under the icon, inside the chip's own size. [level]
    // 1 amber, 2 red: the figure, or on a lit chip the chip itself (dark
    // digits on its light fill would read as muted).
    Widget chip(S3xyAction a, Glyph icon, String label, bool lit,
        {bool wifiOnly = false, String? note, int level = 0}) {
      lit = lit && (wifiOnly ? o.wifiLive : o.live);
      final fill = switch (level) { 2 => kAlert, 1 => kWarn, _ => kLit };
      final color = lit && level < 2 ? Colors.black : Colors.white;
      final noteColor = lit ? color : switch (level) { 2 => kAlert, 1 => kWarn, _ => color };
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Tooltip(
          message: label,
          child: InkWell(
            onTap: () => onTap(a),
            borderRadius: BorderRadius.circular(20),
            child: Container(
              height: 42,
              constraints: const BoxConstraints(minWidth: 52),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: lit ? fill : null,
                border: Border.all(color: lit ? fill : Colors.white70),
              ),
              child: note == null
                  ? GlyphIcon(icon, size: 24, color: color)
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      GlyphIcon(icon, size: 22, color: color),
                      // Four digits in the chip's width, whatever the font.
                      SizedBox(
                        width: 26,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(note,
                              style: TextStyle(
                                  fontSize: 11,
                                  height: 1.1,
                                  color: noteColor,
                                  fontFeatures: const [FontFeature.tabularFigures()])),
                        ),
                      ),
                    ]),
            ),
          ),
        ),
      );
    }

    // The cabin's CO2 on the recirculation chip, the button that changes
    // it: amber when a full car makes it stuffy, red when it makes it
    // drowsy. ponytail: fixed bands; tune from a log with a full car.
    final co2 = o.wifiLive ? o.co2ppm : null;
    final co2Level = co2 == null ? 0 : co2 >= 2500 ? 2 : co2 >= 1500 ? 1 : 0;
    // Once a figure has come, its slot stays, blank through a WiFi stall.
    final co2Note = o.co2ppm == null ? null : '${co2 ?? ''}';
    return Column(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      if (!right) ...[
        chip(S3xyAction.trunk, Glyph.trunk, 'Trunk', o.trunk),
        // Outside R: the screen's Mirror Auto Tilt (0x273), which a tilt
        // press overrides in R. In R: whether the mirrors are dipped (0x102),
        // so the override shows.
        chip(S3xyAction.mirrorTilt, Glyph.mirrorTilt, 'Mirror tilt',
            o.gear == 'R' ? o.mirrorDipped : o.tiltAuto,
            wifiOnly: true),
        // Lit while that door is open (latches from 0x102/0x103). Locks,
        // honk and flash live in More actions.
        chip(S3xyAction.doorFrontLeft, Glyph.doorFL, 'Front left door', o.doorFL),
        chip(S3xyAction.doorRearLeft, Glyph.doorRL, 'Rear left door', o.doorRL),
        // Lit while the charge port door is open (CP_status).
        chip(S3xyAction.chargePort, Glyph.chargePort, 'Charge port', o.chargePort,
            wifiOnly: true),
      ] else ...[
        chip(S3xyAction.frunk, Glyph.frunk, 'Frunk', o.frunk),
        // Lit while most of the air is recirculated (the HVAC controller,
        // 0x243); without that frame the Commander's Bluetooth reading
        // stands in. A press always toggles.
        if (o.wifiLive && o.frames.containsKey(0x243))
          chip(S3xyAction.recircToggle, Glyph.recirc, 'Recirculation', o.hvacOn && o.recircOn,
              note: co2Note, level: co2Level)
        else
          // Bluetooth's own value, cleared when that link drops. Its low
          // bits are the mode; the top bit is set while a Commander press
          // holds it.
          chip(S3xyAction.recircToggle, Glyph.recirc, 'Recirculation',
              ((bt.recircMode ?? 0) & 0x7F) == 1,
              note: co2Note, level: co2Level),
        chip(S3xyAction.doorFrontRight, Glyph.doorFR, 'Front right door', o.doorFR),
        chip(S3xyAction.doorRearRight, Glyph.doorRR, 'Rear right door', o.doorRR),
        // Lit while the screen's dome light is on or any map light is: the
        // lamps the S3XY Interior Lights press switches on.
        chip(S3xyAction.interiorLights, Glyph.interiorLight, 'Interior lights',
            o.domeLight == 'ON' || o.mapLight,
            wifiOnly: true),
      ],
    ]);
  }
}

/// The battery as a small dial, the speed ring in miniature: an arc round
/// 270°, empty at the left of its foot and full at the right, filled to the
/// charge (red below 20 %), the % in its hole and the range in the open
/// foot, where the ring has the gear. Over the %, a bolt while charging (the
/// arc dim green on to the limit) and the pack's coldest cells: ice blue
/// with the car's snowflake while too cold for full regen and power, a red
/// up arrow while it heats, and the target a preconditioning heats it to.
class _Battery extends StatelessWidget {
  const _Battery({required this.obd});

  final Panda obd;

  @override
  Widget build(BuildContext context) {
    final o = obd, pct = o.socPct, range = o.range;
    final color = (pct ?? 100) < 20 ? kAlert : kRegen;
    final charging = o.wifiLive && o.charging, t = o.packTempC, cold = (t ?? 99) <= 10;
    final heating = o.packHeating || o.precondC != null;
    // Drawn at 104 x 98 and shown at 85 %, the g-meter under it.
    return SizedBox(
      width: 88,
      height: 83,
      child: FittedBox(child: SizedBox(
      width: 104,
      height: 98,
      child: CustomPaint(
        painter: _DialPainter(((pct ?? 0).clamp(0, 100) / 100).toDouble(), color,
            limit: charging ? o.chargeLimitPct : null),
        child: Stack(alignment: Alignment.topCenter, children: [
          if (charging || t != null)
            Positioned(
              top: 15,
              width: 66,
              height: 19,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(mainAxisSize: MainAxisSize.min, spacing: 1, children: [
                  if (charging) const Icon(Icons.bolt, size: 17, color: kRegen),
                  if (cold) const Icon(Icons.ac_unit, size: 14, color: kCold),
                  if (t != null)
                    Text.rich(
                        TextSpan(text: '${t.abs() < 10 ? t.toStringAsFixed(1) : t.round()}°', children: [
                          if (o.precondC case final to?)
                            TextSpan(text: ' → ${to.round()}°', style: const TextStyle(color: kWarn)),
                        ]),
                        style: TextStyle(
                            fontSize: 14,
                            color: cold ? kCold : Colors.white70,
                            fontFeatures: const [FontFeature.tabularFigures()])),
                  if (heating) const Icon(Icons.arrow_upward, size: 14, color: kAlert),
                ]),
              ),
            ),
          // The figures shrink rather than reach the arc, whatever the font.
          Positioned(
            top: 34,
            width: 76,
            height: 36,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text.rich(
                  TextSpan(text: pct == null ? '—' : '${pct.round()}', children: [
                    if (pct != null) const TextSpan(text: '%', style: TextStyle(fontSize: 16)),
                  ]),
                  style: TextStyle(
                      fontSize: 28,
                      // Dim without a reading, so the dial reads as a gap.
                      color: pct == null ? Colors.white38 : color == kAlert ? kAlert : Colors.white,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ),
          if (range != null)
            Positioned(
              bottom: 0,
              width: 60,
              height: 18,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('${range.round()} ${o.rangeUnit}',
                    style: const TextStyle(fontSize: 15, color: Colors.white70)),
              ),
            ),
        ]),
      ),
    )));
  }
}

/// The dial's arc in the box's top square: a hairline track, open at the
/// foot, and over it the fill, clockwise from the left end to [fraction];
/// [limit], a charge limit %, dim on to it.
class _DialPainter extends CustomPainter {
  _DialPainter(this.fraction, this.color, {this.limit});

  final double fraction;
  final Color color;
  final int? limit;

  // Canvas angles: 0 = right, clockwise; from the bottom left over the top.
  static const _start = 0.75 * pi, _sweep = 1.5 * pi;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.width / 2), r = size.width / 2 - 4;
    final rect = Rect.fromCircle(center: c, radius: r);
    Paint stroke(Color color, double width) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color;
    canvas.drawArc(rect, _start, _sweep, false, stroke(Colors.white24, 1.5));
    if (fraction > 0) canvas.drawArc(rect, _start, _sweep * fraction, false, stroke(color, 6));
    // What is still to go in, a dim green on to the limit, after a red fill
    // too; solid, so the track does not show through. (The signal reaches
    // 102 %: never past the arc's end.)
    if (limit case final l? when l / 100 > fraction) {
      canvas.drawArc(rect, _start + _sweep * fraction, _sweep * (min(l, 100) / 100 - fraction), false,
          stroke(Color.alphaBlend(kRegen.withValues(alpha: 0.3), Colors.black), 6));
    }
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.fraction != fraction || old.color != color || old.limit != limit;
}

/// The g-meter, as Track Mode draws it: the dot where the force pushes the
/// driver (up braking, down speeding up, right in a left turn), its figure
/// beside it and this drive's peak under that. WiFi only.
class _GBall extends StatefulWidget {
  const _GBall({required this.obd});

  final Panda obd;

  @override
  State<_GBall> createState() => _GBallState();
}

class _GBallState extends State<_GBall> {
  // The last few dots, oldest first: about a fifth of a second at the
  // fast tick's 45 a second. Still, they gather under the dot.
  final _trail = <Offset>[];

  @override
  Widget build(BuildContext context) {
    final o = widget.obd, g = Offset(o.gLat ?? 0, o.gLong ?? 0);
    _trail.add(g);
    if (_trail.length > 10) _trail.removeAt(0);
    final peak = max(o.gMaxBrake, max(o.gMaxAccel, o.gMaxLat));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox.square(
        dimension: 72,
        child: CustomPaint(painter: _GPainter(List.of(_trail), (o.gMaxBrake, o.gMaxAccel, o.gMaxLat))),
      ),
      const SizedBox(width: 12),
      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text.rich(
            TextSpan(text: g.distance.toStringAsFixed(2), children: const [
              TextSpan(text: ' g', style: TextStyle(fontSize: 14, color: Colors.white70)),
            ]),
            style: const TextStyle(
                fontSize: 20, color: Colors.white, fontFeatures: [FontFeature.tabularFigures()])),
        Text('PEAK ${peak.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 12, letterSpacing: 0.8, color: Colors.white70)),
      ]),
    ]);
  }
}

/// Rings at 0.5 and 1 g on a crosshair; inside them, faint, how far this
/// drive has reached each way; the trail fading in to the dot, held at the
/// 1 g ring past it.
class _GPainter extends CustomPainter {
  _GPainter(this.trail, this.peaks);

  final List<Offset> trail; // g across, g along; the last one is now
  final (double, double, double) peaks; // brake, accel, across

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero), r = size.shortestSide / 2 - 1;
    Paint stroke(Color color, double width) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color;
    canvas.drawLine(c - Offset(r, 0), c + Offset(r, 0), stroke(Colors.white12, 1));
    canvas.drawLine(c - Offset(0, r), c + Offset(0, r), stroke(Colors.white12, 1));
    canvas.drawCircle(c, r / 2, stroke(Colors.white12, 1));
    canvas.drawCircle(c, r, stroke(Colors.white24, 1.5));
    // The reach: a quarter ellipse between each pair of peaks.
    final (b, a, l) = (peaks.$1.clamp(0, 1) * r, peaks.$2.clamp(0, 1) * r, peaks.$3.clamp(0, 1) * r);
    if (a + b + l > 0) {
      const w = 0.7071; // a conic's weight for a quarter ellipse
      final p = Path()
        ..moveTo(c.dx, c.dy - b)
        ..conicTo(c.dx + l, c.dy - b, c.dx + l, c.dy, w)
        ..conicTo(c.dx + l, c.dy + a, c.dx, c.dy + a, w)
        ..conicTo(c.dx - l, c.dy + a, c.dx - l, c.dy, w)
        ..conicTo(c.dx - l, c.dy - b, c.dx, c.dy - b, w)
        ..close();
      canvas.drawPath(p, Paint()..color = kAccent.withValues(alpha: 0.22));
    }
    Offset at(Offset g) => c + (g.distance > 1 ? g / g.distance : g) * r;
    for (var i = 1; i < trail.length; i++) {
      canvas.drawLine(at(trail[i - 1]), at(trail[i]),
          stroke(Colors.white.withValues(alpha: 0.7 * i / trail.length), 2)..strokeCap = StrokeCap.round);
    }
    canvas.drawCircle(at(trail.last), 5, Paint()..color = Colors.black);
    canvas.drawCircle(at(trail.last), 4, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_GPainter old) => !listEquals(old.trail, trail) || old.peaks != peaks;
}

/// Temperatures and battery health: the air outside (ice blue from +3 °C
/// down, where bridges freeze first), washer fluid once it runs low (the
/// pack's own temperature is in the battery dial); then the spread between the strongest and weakest cell
/// group, and how far full-pack energy has fallen from the BMS's figure for
/// it new.
class _Pack extends StatelessWidget {
  const _Pack({required this.obd});

  final Panda obd;

  @override
  Widget build(BuildContext context) {
    final o = obd, mv = o.imbalanceMv;
    final kwh = o.packKwh, isNew = o.packNewKwh;
    final out = o.outsideC;
    Widget row(String label, String value, {Color color = Colors.white}) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: MediaQuery.textScalerOf(context).scale(104), // aligns the values
            child: Text(label,
                maxLines: 1,
                softWrap: false,
                style: const TextStyle(
                    fontSize: 12, letterSpacing: 0.8, color: Colors.white70)),
          ),
          Text(value, style: TextStyle(fontSize: 16, color: color)),
        ]);
    // Shrinks rather than overflows when a large font meets a wide ring.
    return FittedBox(fit: BoxFit.scaleDown, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      row('OUTSIDE', out == null ? '—' : _deg(out), color: out != null && out <= 3 ? kCold : Colors.white),
      if (o.wifiLive && o.washerLow) row('WASHER', 'LOW', color: kWarn),
      row('IMBALANCE', mv == null ? '—' : '${mv.round()} mV'),
      row('DEGRADATION', kwh == null || isNew == null ? '—' : '${((1 - kwh / isNew) * 100).clamp(0, 100).toStringAsFixed(1)} %'),
    ]));
  }
}

/// A temperature as the car reads it: to the half degree near freezing,
/// whole degrees beyond.
String _deg(double c) => '${c.abs() < 10 ? c.toStringAsFixed(1) : c.round()} °C';

/// European-style sign; blank while the car reports no limit.
class _SpeedLimit extends StatelessWidget {
  const _SpeedLimit({required this.limit});

  final double? limit;

  @override
  Widget build(BuildContext context) => Container(
        width: 52,
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: limit == null ? Colors.white10 : Colors.white,
          border: Border.all(
            color: limit == null ? Colors.white24 : const Color(0xFFE23D3D),
            width: 5,
          ),
        ),
        child: Text(
          limit == null ? '—' : limit!.round().toString(),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: limit == null ? Colors.white24 : Colors.black,
          ),
        ),
      );
}

/// The lights on, each only while it is: DRL for the front light bar (DRL by
/// day, the position lamp at night), LOW and HIGH, from VCFRONT_lighting;
/// HIGH also from the lamps themselves. Green as the car's own indicators,
/// HIGH blue. Then GRIP while it has something to say, coloured by the road:
/// amber while traction or stability control steps in, ice blue while the
/// car judges the road slippery, both only while moving ([Panda.gripLit]);
/// Slip Start or Off-Road Assist left on names itself (amber on a dry road).
/// GRIP is WiFi only.
class _Lights extends StatelessWidget {
  const _Lights({required this.obd});

  final Panda obd;

  @override
  Widget build(BuildContext context) {
    final o = obd;
    Widget lamp(String label, Glyph icon, [Color lit = kRegen]) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Column(children: [
            GlyphIcon(icon, size: 20, color: lit),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 12, letterSpacing: 1, color: lit)),
          ]),
        );
    final grip = o.wifiLive && o.frames.containsKey(0x2B6) && (o.gripLit || o.tcMode != null);
    // Four lamps where three fitted: shrinks rather than overflows.
    return FittedBox(fit: BoxFit.scaleDown, child: Row(mainAxisSize: MainAxisSize.min, children: [
      if (o.drl == true) lamp('DRL', Glyph.drl),
      if (o.lowBeam == true) lamp('LOW', Glyph.lowBeam),
      if (o.highBeam == true) lamp('HIGH', Glyph.highBeam, kAccent),
      if (grip) lamp(o.tcMode ?? 'GRIP', Glyph.grip, o.gripLit && !o.gripHeld ? kCold : kWarn),
    ]));
  }
}

/// The car from above, front up, its seven seats 2 + 3 + 2 (the driver
/// front left: this car is LHD) and each tyre's pressure (psi) on its wheel.
/// Once the stream is live: beside each row its air temperature and fan as
/// the screen sets it (the third row has none), under the car what the pack
/// feeds besides the motors, and the seats coloured: grey while empty,
/// green once the belt is buckled, red while someone sits in it unbuckled
/// (that row's figures then step aside).
/// Not over Bluetooth, which has none of it; before the stream the saved
/// pressures on a plain car.
class _Cabin extends StatelessWidget {
  const _Cabin({required this.obd});

  final Panda obd;

  /// Each seat row's centre, as a share of the image's length, front first.
  static const _rowAt = [0.494, 0.664, 0.804];

  /// The axles, front and rear, as a share of the image's length.
  static const _axleAt = [0.205, 0.80];

  @override
  Widget build(BuildContext context) {
    final o = obd;
    if (o.viaBt) return const SizedBox.shrink();
    // Before the chime's frame, someone seated unbuckled would show plain.
    final live = o.wifiLive && o.frames.containsKey(0x3A1);
    final belt = live && o.anyBeltUnbuckled;
    final scale = MediaQuery.textScalerOf(context).scale;
    // The image's seats are white: multiplied by the colour, shading and all.
    final unbuckled = {
      'D': o.beltDriver, 'P': o.beltPass, '2L': o.belt2L, '2C': o.belt2C,
      '2R': o.belt2R, '3L': o.belt3L, '3R': o.belt3R,
    };
    // As tall as the column allows: the rows' figures sit on the seats.
    final carH = scale(240), carW = carH * 257 / 570; // the image's own shape
    final sideW = scale(62);
    // A tyre's psi on the body over its wheel: between the outline and the
    // seats, as far in from each side (the mirrors make the image wider than
    // the body, the left more than the right).
    Widget tyre(double? bar, double at, bool left) => Positioned(
          left: left ? carW * 0.10 : null,
          right: left ? null : carW * 0.068,
          width: carW * 0.21,
          top: carH * at - scale(13),
          height: scale(26),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(bar == null ? '—' : (bar * 14.5038).round().toString(),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                    shadows: [Shadow(blurRadius: 3)])),
            const Text('psi',
                style: TextStyle(color: Colors.white60, fontSize: 8, height: 1, shadows: [Shadow(blurRadius: 3)])),
          ]),
        );
    // A row's air and fan on a dark pill over its seats, centred on them.
    Widget row(double at, double? c, [String? fan]) => Positioned(
          left: carW * 0.2,
          width: carW * 0.62,
          top: carH * at - scale(fan == null ? 10 : 17),
          height: scale(fan == null ? 20 : 34),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(c == null ? '—' : '${c.round()}°',
                    style: const TextStyle(fontSize: 14, height: 1.1, fontWeight: FontWeight.w600, color: Colors.white)),
                if (fan != null)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    GlyphIcon(fan == 'OFF' ? Glyph.fanOff : Glyph.fan, size: 11, color: Colors.white70),
                    if (fan != 'OFF')
                      Text(' $fan', style: const TextStyle(fontSize: 10, height: 1.1, color: Colors.white70)),
                  ]),
              ]),
            ),
          ),
        );
    final car = SizedBox(
      width: carW,
      height: carH,
      child: Stack(fit: StackFit.expand, children: [
        Image.asset('assets/car/car.png', fit: BoxFit.fill),
        if (live)
          for (final MapEntry(key: s, value: off) in unbuckled.entries)
            Image.asset('assets/car/seat_$s.png',
                fit: BoxFit.fill,
                colorBlendMode: BlendMode.modulate,
                color: off ? kAlert : o.buckled.contains(s) ? kRegen : const Color(0xFF8C8C8C)),
        tyre(o.tpFL, _axleAt[0], true),
        tyre(o.tpFR, _axleAt[0], false),
        tyre(o.tpRL, _axleAt[1], true),
        tyre(o.tpRR, _axleAt[1], false),
        // A row with a seat unbuckled leaves the red in full view.
        if (live) ...[
          if (!o.beltDriver && !o.beltPass) row(_rowAt[0], o.cabinC1, o.fan1),
          if (!o.belt2L && !o.belt2C && !o.belt2R) row(_rowAt[1], o.cabinC2, o.fan2),
          if (!o.belt3L && !o.belt3R) row(_rowAt[2], o.cabinC3),
        ],
      ]),
    );
    Widget draw(String label, double? kw) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 11, letterSpacing: 1, color: Colors.white70)),
            Text(kw == null ? '—' : '${kw.toStringAsFixed(1)} kW',
                style: const TextStyle(
                    fontSize: 15, color: Colors.white, fontFeatures: [FontFeature.tabularFigures()])),
          ]),
        );
    // Shrinks rather than overflows in the column beside the ring.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        decoration: belt
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: kAlert.withValues(alpha: 0.18),
                border: Border.all(color: kAlert),
              )
            : null,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          car,
          // What the pack feeds besides the motors.
          if (live && o.otherKw != null) ...[
            const SizedBox(width: 6),
            SizedBox(
              width: sideW,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                draw('CLIMATE', o.climateKw),
                draw('12 V', o.lvKw),
                draw('OTHER', o.otherKw),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

/// While charging: to what % and by when, as the nav puts a route.
/// WiFi only.
class _Charge extends StatelessWidget {
  const _Charge({required this.obd, this.oneLine = false});

  final Panda obd;
  final bool oneLine; // the compact dash: one row under the ring

  @override
  Widget build(BuildContext context) {
    final o = obd;
    if (!o.wifiLive || !o.charging) return const SizedBox.shrink();
    const big = TextStyle(
        fontSize: 18, color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]);
    final pct = o.chargeLimitPct, m = o.chargeMinutes;
    final to = pct == null ? null : 'to $pct %';
    final when = m == null
        ? null
        : '${m < 60 ? '$m min' : '${m ~/ 60}h ${m % 60}m'}   '
            '${TimeOfDay.fromDateTime(DateTime.now().add(Duration(minutes: m))).format(context)}';
    if (to == null && when == null) return const SizedBox.shrink();
    if (oneLine) {
      return FittedBox(
          fit: BoxFit.scaleDown,
          child: Text([?to, ?when].join('   '), style: big));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('CHARGE',
          style: TextStyle(fontSize: 12, letterSpacing: 1.5, color: Colors.white70)),
      const SizedBox(height: 2),
      if (to != null) Text(to, style: big),
      if (when != null) FittedBox(fit: BoxFit.scaleDown, child: Text(when, style: big)),
    ]);
  }
}
