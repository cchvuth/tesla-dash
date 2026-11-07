// Renders the dash in a few real situations at the phone's own resolution,
// so new stats can be judged in place. Set DASH_SHOT=/some/dir to write the
// PNGs; otherwise it only checks they lay out.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tesla_dash/commander.dart';
import 'package:tesla_dash/gauge.dart';
import 'package:tesla_dash/main.dart';
import 'package:tesla_dash/panda.dart';


const _dpr = 2.8125; // the S23 Ultra at its display size: 823 x 384 dp

Panda _car() => Panda()
  ..status = 'live'
  ..kph = true
  ..lowBeam = false
  ..highBeam = false
  ..drl = true
  ..tpFL = 2.6
  ..tpFR = 2.6
  ..tpRL = 2.65
  ..tpRR = 2.6
  ..cellVMax = 3.902
  ..cellVMin = 3.898
  ..packKwh = 81.76
  ..packNewKwh = 84
  ..packLeftKwh = 50.62
  ..packBufferKwh = 3.68;

/// The belts' and the grip frames have come: the seat map shows, and GRIP
/// can once it has something to say.
Panda _seen(Panda o) => o
  ..frames[0x2B6] = Frame(0)
  ..frames[0x3A1] = Frame(0);

final _shots = <String, (Size, Panda Function())>{
  // A dark November morning: ice on the bridge, a cold pack, a full car
  // recirculating, a third-row seat unbuckled.
  'cold-morning': (const Size(823.5, 384), () {
    final o = _car()
      ..speed = 38
      ..gear = 'D'
      ..frontKw = -3
      ..rearKw = -18
      ..pedalPct = 0
      ..socPct = 64
      ..rangeMi = 193
      ..speedLimit = 50
      ..lowBeam = true
      ..outsideC = -1.5
      ..washerLow = true
      ..slippery = true
      ..packTempC = 3.5
      ..packHeating = true
      ..regenMaxKw = 24
      ..hvacOn = true
      ..recircOn = true
      ..co2ppm = 1650
      ..cabinC1 = 21
      ..cabinC2 = 19
      ..cabinC3 = 16
      ..fan1 = 'MED'
      ..fan2 = 'MED'
      ..buckled.addAll({'D', 'P', '2L', '2C', '2R', '3R'})
      ..belt3L = true
      ..navRoute = true
      ..navMinutes = 14
      ..navEnergyKwh = 47.9
      // Easing off on regen before the bridge; gentle peaks on the ice.
      ..gLong = -0.1
      ..gLat = 0.02
      ..gMaxAccel = 0.18
      ..gMaxBrake = 0.22
      ..gMaxLat = 0.15;
    o.frames[0x238] = Frame(0);
    o.frames[0x243] = Frame(0);
    o.frames[0x2B6] = Frame(0);
    o.frames[0x3A1] = Frame(0);
    return o;
  }),
  // The motorway on Autopilot, the car asking for a hand on the wheel.
  'highway-cruise': (const Size(823.5, 384), () {
    // The pack (400 V, 113.5 A = 45.4 kW) over the motors' 42: 3.4 kW of
    // other draws, the compressor's 1.7 and the 12 V side's 0.8 among them.
    final o = _car()
      ..onFrame(0x118, 1, [0, 0, 0x80, 0, 0, 0, 0, 0])
      ..onFrame(0x132, 1, [0x40, 0x9C, 0x90, 0xFB, 0, 0])
      ..onFrame(0x2E5, 1, [0, 0, 0, 0, 0xD0, 0x48, 0])
      ..onFrame(0x266, 1, [0, 0, 0, 0, 0x88, 0x60, 0])
      ..onFrame(0x2A7, 1, [150, 137, 75, 21, 46, 188, 5, 129])
      ..onFrame(0x2B4, 1, [183, 5, 88, 14, 34, 2])
      ..speed = 108
      ..gear = 'D'
      ..frontKw = 18
      ..rearKw = 24
      ..pedalPct = 0
      ..socPct = 71
      ..rangeMi = 214
      ..speedLimit = 110
      ..autopilot = 'AUTOPILOT'
      ..handsOn = 3
      ..cruiseSet = 110
      ..followGap = 3
      ..lowBeam = true
      ..outsideC = 4.5
      ..packTempC = 24
      ..co2ppm = 820
      ..cabinC1 = 22
      ..cabinC2 = 21
      ..cabinC3 = 20
      ..fan1 = '4'
      ..fan2 = 'HIGH'
      ..buckled.addAll({'D', 'P'})
      ..navRoute = true
      ..navMinutes = 96
      ..navEnergyKwh = 38
      // A long motorway curve to the left; this drive's peaks so far.
      ..gLong = 0.02
      ..gLat = 0.12
      ..gMaxAccel = 0.31
      ..gMaxBrake = 0.42
      ..gMaxLat = 0.28;
    o.frames[0x238] = Frame(0);
    o.frames[0x2B6] = Frame(0);
    o.frames[0x3A1] = Frame(0);
    return o;
  }),
  // A Supercharger in the cold: the pack still warming holds it back.
  'charging': (const Size(823.5, 384), () => _seen(_car()
    ..speed = 0
    ..gear = 'P'
    ..socPct = 46
    ..rangeMi = 140
    ..charging = true
    ..chargeKw = 48
    ..chargeMaxKw = 62
    ..chargeWhy = 'COLD PACK'
    ..chargeLimitPct = 80
    ..chargeMinutes = 35
    ..outsideC = 2
    ..packTempC = 9
    ..packHeating = true
    ..co2ppm = 560
    ..cabinC1 = 20
    ..cabinC2 = 18
    ..cabinC3 = 17
    ..fan1 = 'LOW'
    ..fan2 = 'OFF')),
  // Beside Google Maps: traction control stepping in on a slushy junction.
  'compact-cold': (const Size(405, 384), () => _seen(_car()
    ..speed = 22
    ..gear = 'D'
    ..frontKw = 30
    ..rearKw = 45
    ..socPct = 64
    ..rangeMi = 193
    ..speedLimit = 50
    ..outsideC = -1.5
    ..gripHeld = true
    ..packTempC = 3.5
    ..regenMaxKw = 24)),
  // WiFi up, none of the newer figures in yet: what the gaps look like.
  'no-new-data': (const Size(823.5, 384), () => _car()
    ..speed = 64
    ..gear = 'D'
    ..frontKw = 10
    ..rearKw = 20
    ..socPct = 58
    ..rangeMi = 175),
  // ScanMyTesla off: the Commander's Bluetooth alone; what only WiFi has
  // must not show.
  'bluetooth-only': (const Size(823.5, 384), () => Panda()
    ..kph = true
    ..fromBt({61: 72, 66: 4, 51: 30, 53: 50, 111: 58, 112: 175, 110: 70, 81: 0x11,
        80: 0x11, 105: 3, 35: 4088, 36: 2531, 37: 368, 34: 840, 43: 1951, 44: 1949})),
};

/// The Commander's own figures, where a scene has them: with ScanMyTesla off
/// it is linked to the car, so the route comes whole.
final _bts = <String, Commander Function()>{
  'bluetooth-only': () => Commander()
    ..ready = true
    ..navDest = 'Eiffel Tower, Paris'
    ..navMiles = 31.1
    ..navMinutes = 38
    ..navArrivePct = 48,
};

void main() {
  tearDown(() => TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!.reset());

  for (final MapEntry(key: name, value: (size, car)) in _shots.entries) {
    testWidgets('dash: $name', (t) async {
      t.view
        ..physicalSize = size * _dpr
        ..devicePixelRatio = _dpr;
      final key = GlobalKey();
      await t.pumpWidget(MaterialApp(
          theme: kTheme,
          debugShowCheckedModeBanner: false,
          home: RepaintBoundary(
              key: key, child: DashPage(demo: car(), bt: _bts[name]?.call() ?? Commander()))));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      // The car's pictures decode off the test's clock: wait for them, or a
      // shot can miss them.
      await t.runAsync(() => Future.wait([
            for (final e in find.byType(Image).evaluate()) precacheImage((e.widget as Image).image, e),
          ]));
      await t.pump();
      final out = Platform.environment['DASH_SHOT'];
      if (out != null) {
        await t.runAsync(() async {
          final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
              .toImage(pixelRatio: _dpr);
          final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
          File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      }
      await t.pumpWidget(const SizedBox());
    });
  }

  // The nav bar: shown only with a route; the Commander's minutes and % at
  // arrival over the bus's kWh; a long destination trims rather than wraps.
  for (final parked in [false, true]) {
    testWidgets('dash parked=$parked', (t) async {
      t.view
        ..physicalSize = const Size(823, 384)
        ..devicePixelRatio = 1;
      final o = Panda()
        ..status = 'live'
        ..frameHz = 158
        ..kph = true
        ..speed = parked ? 0 : 74
        ..gear = parked ? 'P' : 'D'
        ..frontKw = parked ? 0 : 48
        ..rearKw = parked ? 0 : 96
        ..pedalPct = parked ? 0 : 38
        ..socPct = 59
        ..cellVMax = 3.912
        ..cellVMin = 3.898
        ..packKwh = 76.4
        ..packNewKwh = 78.8
        ..domeLight = 'OFF'
        ..rangeMi = 205
        ..speedLimit = 70
        ..recirc = 'AUTO'
        ..autopilot = parked ? null : 'AUTOPILOT'
        ..tpFL = 2.9
        ..tpFR = 2.9
        ..tpRL = 2.8
        ..tpRR = 2.9
        ..lowBeam = true
        ..drl = true
        ..highBeam = false
        ..navRoute = !parked
        ..navEnergyKwh = parked ? null : 31.4
        ..doorFL = parked
        ..frunk = parked
        ..beltDriver = !parked
        ..belt3L = !parked
        ..blindL = !parked
        ..indR = !parked
        ..blinkLit = !parked
        ..braking = !parked;
      o.frames[0x238] = Frame(0); // the bus carries the route flag
      o.frames[0x2B6] = Frame(0); // the grip frame, saying nothing
      final bt = Commander()
        ..ready = true
        ..navDest = parked ? null : 'Eiffel Tower, Champ de Mars, 5 Av. Anatole France, Paris'
        ..navMiles = parked ? null : 11.2
        ..navMinutes = parked ? null : 16
        ..navArrivePct = parked ? null : 64;
      await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: o, bt: bt)));
      await t.pump(const Duration(milliseconds: 700));
      expect(find.text('16 min'), parked ? findsNothing : findsOneWidget);
      expect(find.text('64%'), parked ? findsNothing : findsOneWidget);
      expect(find.text('18 km'), parked ? findsNothing : findsOneWidget); // 11.2 mi
      // Only the lights on, DRL first; GRIP has nothing to say.
      expect(find.text('HIGH'), findsNothing);
      expect(find.text('GRIP'), findsNothing);
      expect(t.getTopLeft(find.text('DRL')).dx, lessThan(t.getTopLeft(find.text('LOW')).dx));
      await t.pumpWidget(const SizedBox()); // dispose, cancel blink timer
    });
  }

  // Edge to edge, the camera's cutout widens one side of the safe area:
  // the pedal line must still grow from the ring's centre.
  testWidgets('pedal line centred on the ring beside a cutout', (t) async {
    t.view
      ..physicalSize = const Size(823, 384)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(left: 28)
      ..viewPadding = const FakeViewPadding(left: 28);
    final o = _car()
      ..speed = 60
      ..gear = 'D'
      ..pedalPct = 50;
    await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: o, bt: Commander())));
    await t.pump(const Duration(milliseconds: 300));
    final line = find.byWidgetPredicate((w) => w is Container && w.color == kAccent);
    expect(t.getCenter(line).dx, closeTo(t.getCenter(find.byType(RingGauge)).dx, 0.5));
    await t.pumpWidget(const SizedBox());
  });

  // Frames captured in the car on a short route
  // (8 min to a 4.4 km destination, 60 % now): the energy the route takes
  // and the range it uses, its length to a tenth, and a buckled seat green.
  testWidgets('trip energy, route length and a buckled seat', (t) async {
    t.view
      ..physicalSize = const Size(823, 384)
      ..devicePixelRatio = 1;
    final o = Panda()
      ..status = 'live'
      ..kph = true
      ..gear = 'D'
      ..packKwh = 81.76
      ..packLeftKwh = 50.62
      ..packBufferKwh = 3.68
      ..rangeMi = 192
      ..navRoute = true
      ..navMinutes = 8
      ..navEnergyKwh = 49.44
      ..cabinC1 = 21
      ..cabinC3 = 17
      ..buckled.add('D');
    o.frames[0x238] = Frame(0);
    o.frames[0x3A1] = Frame(0);
    final bt = Commander()..navMiles = 2.734;
    await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: o, bt: bt)));
    await t.pump(const Duration(milliseconds: 700));
    expect(find.text('1.2 kWh'), findsOneWidget); // 50.62 - 49.44
    expect(find.text('4.4 km'), findsOneWidget);
    // 301 km at arrival, 8 less than the 309 now.
    expect(find.textContaining('301 km', findRichText: true), findsOneWidget);
    expect(find.textContaining('−8', findRichText: true), findsOneWidget);
    // The image's driver seat tinted green; the rest grey, none red.
    Finder seats(Color c) => find.byWidgetPredicate((w) => w is Image && w.color == c);
    expect(seats(kRegen), findsOneWidget);
    expect(t.widget<Image>(seats(kRegen)).image, const AssetImage('assets/car/seat_D.png'));
    expect(seats(kAlert), findsNothing);
    expect(find.text('17°'), findsOneWidget);
    o
      ..belt3R = true // someone sat in the back, unbuckled
      ..notifyListeners();
    await t.pump();
    expect(t.widget<Image>(seats(kAlert)).image, const AssetImage('assets/car/seat_3R.png'));
    // That row's figure steps off the red seat; the others stay.
    expect(find.text('17°'), findsNothing);
    expect(find.text('21°'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  // A Commander that is not a key to the car sends no nav fields: minutes
  // and kWh come off the bus, and values with nothing to show stay hidden.
  testWidgets('nav from the bus alone', (t) async {
    t.view
      ..physicalSize = const Size(823, 384)
      ..devicePixelRatio = 1;
    final o = Panda()
      ..status = 'live'
      ..gear = 'D'
      ..navRoute = true
      ..navMinutes = 16
      ..navEnergyKwh = 31.4;
    o.frames[0x238] = Frame(0);
    await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: o, bt: Commander())));
    await t.pump(const Duration(milliseconds: 700));
    expect(find.text('16 min'), findsOneWidget);
    expect(find.text('31.4 kWh'), findsOneWidget);
    expect(find.byIcon(Icons.place), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
