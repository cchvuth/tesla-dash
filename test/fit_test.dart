// The phone sits in landscape (S23 Ultra: 823 x 384 dp) and its keyboard
// takes half of that or more. Dialogs and pages must fit, or scroll, and
// never spill over their own buttons (an overflow fails the test); the
// field being typed in must stay in view above the keyboard.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tesla_dash/commander.dart';
import 'package:tesla_dash/diag.dart';
import 'package:tesla_dash/gauge.dart';
import 'package:tesla_dash/main.dart';
import 'package:tesla_dash/panda.dart';


const _screen = Size(823, 384);
const _keyboards = [160.0, 200.0, 240.0]; // dp, as tall as phone keyboards get

Future<void> _frames(WidgetTester t, [int n = 30]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 16));
  }
}

/// Raises the keyboard as Android 11+ does: its inset eases in over 285 ms,
/// a frame at a time, and the focused field scrolls into view as it rises.
Future<void> _raise(WidgetTester t, double kb) async {
  const ime = Cubic(0.2, 0, 0, 1);
  for (var ms = 16; ms <= 288; ms += 16) {
    t.view.viewInsets = FakeViewPadding(bottom: kb * ime.transform((ms / 285).clamp(0.0, 1.0)));
    await t.pump(const Duration(milliseconds: 16));
  }
  await _frames(t);
}

/// With the keyboard down every field shows, above [button]. Then each
/// field is tapped and the keyboard raised: the dialog shrinks and scrolls,
/// its buttons stay above the keyboard, and the field's line stays in view.
Future<void> _fits(WidgetTester t, String button) async {
  final fields = find.byType(TextField);
  final n = fields.evaluate().length;
  final buttons = t.getRect(find.text(button)).top;
  for (var i = 0; i < n; i++) {
    expect(t.getRect(fields.at(i)).bottom, lessThanOrEqualTo(buttons));
  }
  for (final kb in _keyboards) {
    for (var i = 0; i < n; i++) {
      t.view.resetViewInsets();
      await _frames(t);
      // As a user would: the dialog scrolls (the sliders make it taller than
      // the screen), so the field is scrolled into view before it is tapped.
      await t.ensureVisible(fields.at(i));
      await t.tap(fields.at(i));
      await _raise(t, kb);
      expect(t.getRect(find.text(button)).bottom, lessThanOrEqualTo(_screen.height - kb));
      final shown = t.getRect(find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(SingleChildScrollView)));
      final line = t.getRect(find.descendant(of: fields.at(i), matching: find.byType(EditableText)));
      final where = 'field $i, keyboard $kb dp';
      expect(line.top, greaterThanOrEqualTo(shown.top - 0.5), reason: where);
      expect(line.bottom, lessThanOrEqualTo(shown.bottom + 0.5), reason: where);
    }
  }
  t.view.resetViewInsets();
  await _frames(t);
}

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
    view
      ..physicalSize = _screen
      ..devicePixelRatio = 1;
  });
  tearDown(() => TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!.reset());

  testWidgets('Commander link dialog', (t) async {
    await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: Panda(), bt: Commander())));
    await t.tap(find.byIcon(Icons.wifi_off));
    await _frames(t);
    await _fits(t, 'Reconnect');
    await t.pumpWidget(const SizedBox()); // dispose, cancel timers
  });

  // Each link's state as a word under its icon; while a timer runs, the
  // seconds left beside it, ticking down on their own.
  testWidgets('link states and countdowns in the bottom bar', (t) async {
    final o = Panda(), bt = Commander();
    await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: o, bt: bt)));
    o.show(WifiLink.retrying, 'link lost — retrying in 5s', DateTime.now().add(const Duration(milliseconds: 4500)));
    bt.show(BtLink.paused, 'waiting for the WiFi stream to start');
    await t.pump();
    Finder on(String tip, String text) => find.descendant(of: find.byTooltip(tip), matching: find.text(text));
    expect(on('WiFi: link lost — retrying in 5s', 'RETRY'), findsOneWidget);
    expect(on('WiFi: link lost — retrying in 5s', '5'), findsOneWidget);
    expect(on('Commander: waiting for the WiFi stream to start', 'WAIT'), findsOneWidget);
    // A real second (the test's own clock does not move DateTime.now), and
    // the button's tick redraws it with the link saying nothing.
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await t.pump(const Duration(milliseconds: 300));
    expect(on('WiFi: link lost — retrying in 5s', '4'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    // Everything connected: both shrink to their icons, no words.
    final ready = Commander()..show(BtLink.lean, 'ready');
    await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: Panda()..status = 'live', bt: ready)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.wifi), findsOneWidget);
    expect(find.byIcon(Icons.bluetooth_connected), findsOneWidget);
    expect(find.text('LIVE'), findsNothing);
    expect(find.text('READY'), findsNothing);
    expect(t.getSize(find.byTooltip('WiFi: live')).width, 36);
    await t.pumpWidget(const SizedBox());
  });

  // Counting down from two digits to one leaves the icon where it was.
  testWidgets('icon stays put: 10 s to 9 s, and with no timer', (t) async {
    final o = Panda();
    await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: o, bt: Commander())));
    o.show(WifiLink.retrying, 'retrying', DateTime.now().add(const Duration(milliseconds: 10400)));
    await t.pump();
    expect(find.text('11'), findsOneWidget);
    final at = t.getCenter(find.byIcon(Icons.wifi_find));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1700)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('9'), findsOneWidget);
    expect(t.getCenter(find.byIcon(Icons.wifi_find)), at);
    // No timer (SCAN shows the same icon): still the same spot.
    o.show(WifiLink.scanning, 'looking');
    await t.pump();
    expect(find.text('SCAN'), findsOneWidget);
    expect(t.getCenter(find.byIcon(Icons.wifi_find)), at);
    await t.pumpWidget(const SizedBox());
  });

  // The gaps around a WiFi stream's start: on sliders, kept on release.
  testWidgets('Bluetooth gaps on the WiFi dialog', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: Panda(), bt: Commander())));
    await t.tap(find.byIcon(Icons.wifi_off));
    await _frames(t);
    expect(find.text('Bluetooth off before WiFi starts: 1.0 s'), findsOneWidget);
    expect(find.text('Bluetooth buttons after WiFi is live: 0.0 s'), findsOneWidget);
    expect(find.text('Bluetooth data after WiFi is live: 5.0 s'), findsOneWidget);
    expect(find.text('Bluetooth back if no WiFi stream: 15.0 s'), findsOneWidget);
    // Each to an end; the lower ones sit below the short dialog's fold.
    final prefs = await SharedPreferences.getInstance();
    Future<void> slide(int i, double dx) async {
      await t.ensureVisible(find.byType(Slider).at(i));
      await t.drag(find.byType(Slider).at(i), Offset(dx, 0));
      await _frames(t);
    }
    await slide(1, 400); // all the way up
    expect(find.text('Bluetooth buttons after WiFi is live: 10.0 s'), findsOneWidget);
    expect(prefs.getInt('btButtonsMs'), 10000);
    await slide(2, -400); // all the way down
    expect(find.text('Bluetooth data after WiFi is live: 0.0 s'), findsOneWidget);
    expect(prefs.getInt('btRejoinMs'), 0);
    await slide(3, -400);
    expect(find.text('Bluetooth back if no WiFi stream: 0.0 s'), findsOneWidget);
    expect(prefs.getInt('btBackMs'), 0);
    // The switch for waiting on the WiFi stream: off, kept when flipped.
    expect(find.text('Bluetooth waits for the WiFi stream, no time limit'), findsOneWidget);
    expect(t.widget<Switch>(find.byType(Switch)).value, isFalse);
    await t.ensureVisible(find.byType(Switch));
    await t.tap(find.byType(Switch));
    await _frames(t);
    expect(t.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(prefs.getBool('btWifiFirst'), isTrue);
    // The fallback slider has nothing to time once Bluetooth waits for the stream.
    expect(t.widget<Slider>(find.byType(Slider).last).onChanged, isNull);
    expect(t.widget<Slider>(find.byType(Slider).first).onChanged, isNotNull);
    await t.pumpWidget(const SizedBox());
  });

  // The dash caps text at 1.15; the nav bar's longest values and a full
  // battery must still fit instead of running off, and a destination's
  // second line must not grow the bar and shrink the ring.
  testWidgets('Nav bar at the text cap', (t) async {
    t.platformDispatcher.textScaleFactorTestValue = 2; // capped to 1.15
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final o = Panda()
      ..status = 'live'
      ..kph = true
      ..gear = 'D'
      ..navRoute = true
      ..navMinutes = 610 // 10h 10m
      ..socPct = 100
      ..rangeMi = 320 // a full battery: 515 km now
      ..packKwh = 81.76
      ..packLeftKwh = 81
      ..packBufferKwh = 3.68
      ..navEnergyKwh = 80;
    o.frames[0x238] = Frame(0);
    await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: o, bt: Commander())));
    await _frames(t);
    expect(find.textContaining('508 km'), findsOneWidget); // left at arrival, 7 used
    expect(find.text('1.0 kWh'), findsOneWidget); // the route's energy
    expect(find.text('98%'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget); // the battery dial
    final ring = t.getSize(find.byType(RingGauge));
    await t.pumpWidget(const SizedBox());
    final bt = Commander()..navDest = 'Eiffel Tower, Champ de Mars, 5 Av. Anatole France, Paris';
    await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: o, bt: bt)));
    await _frames(t);
    expect(t.getSize(find.byType(RingGauge)), ring);
    await t.pumpWidget(const SizedBox());
  });

  // Beside Google Maps the dash gets about half the screen, a third or two
  // thirds if the divider is dragged, less the status bar: the compact
  // layout must fit every split, and the full one keeps the map button.
  for (final size in const [
    Size(270, 340), Size(405, 340), Size(405, 384), Size(545, 384), Size(823, 384),
  ]) {
    testWidgets('Dash at ${size.width.round()} x ${size.height.round()}', (t) async {
      t.view.physicalSize = size;
      final o = Panda()
        ..status = 'live'
        ..kph = true
        ..speed = 74
        ..gear = 'D'
        ..frontKw = 48
        ..rearKw = 96
        ..socPct = 59
        ..rangeMi = 192
        ..speedLimit = 70
        ..autopilot = 'AUTOPILOT'
        ..beltDriver = true
        ..navRoute = true
        ..navMinutes = 610
        ..packKwh = 81.76
        ..packLeftKwh = 50.62
        ..packBufferKwh = 3.68
        ..navEnergyKwh = 49.44;
      o.frames[0x238] = Frame(0);
      await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: o, bt: Commander())));
      await _frames(t);
      expect(find.text('74'), findsOneWidget); // the speed
      expect(find.byIcon(Icons.map_outlined), size.width < 700 ? findsNothing : findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  }

  // ScanMyTesla off: the Commander's Bluetooth data alone, and what only
  // WiFi has (the tyres) gone from the column.
  testWidgets('Dash on Bluetooth only', (t) async {
    t.view.physicalSize = const Size(823, 384);
    final o = Panda()
      ..fromBt({61: 74, 66: 4, 51: 96, 53: 192, 111: 59, 112: 192, 105: 3, 81: 0x11,
          35: 4088, 36: 2531, 37: 368, 34: 800, 43: 1950, 44: 1948});
    await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: o, bt: Commander())));
    await _frames(t);
    expect(find.text('74'), findsOneWidget);
    expect(find.text('AUTOPILOT'), findsOneWidget);
    expect(find.text('TYRES  psi'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  // Before the first frame, or with the link down, there is nothing to show:
  // the compact dash must still lay out (an empty battery gauge once could
  // not).
  testWidgets('Compact dash without data', (t) async {
    t.view.physicalSize = const Size(405, 384);
    await t.pumpWidget(MaterialApp(theme: kTheme, home: DashPage(demo: Panda(), bt: Commander())));
    await _frames(t);
    expect(find.text('—'), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Diagnostics and its dialogs', (t) async {
    final o = Panda();
    for (var id = 0x100; id < 0x140; id++) {
      o.frames[id] = Frame(0);
    }
    await t.pumpWidget(MaterialApp(theme: kTheme, home: DiagPage(obd: o, bt: Commander())));
    await _frames(t);
    // Every tool and every frame below them can be scrolled to.
    await t.scrollUntilVisible(find.text('0x13F'), 200);
    for (final (tool, button) in [('Find tyre pressure', 'Search'), ('Find nav data', 'Start')]) {
      await t.scrollUntilVisible(find.text(tool), -200);
      await t.pump(); // lay out where it scrolled to before tapping
      await t.tap(find.text(tool));
      await _frames(t);
      await _fits(t, button);
      await t.tap(find.text('Cancel'));
      await _frames(t);
    }
    await t.pumpWidget(const SizedBox());
  });
}
