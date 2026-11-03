import 'dart:async';
import 'dart:math' show max, min, pi;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'car_panel.dart';
import 'commander.dart';
import 'gauge.dart';
import 'glyphs.dart';
import 'panda.dart';
import 'diag.dart';

part 'widgets.dart';

// The Commander's panda endpoint. Turn it on first: S3XY Buttons app ->
// Commander Settings -> ScanMyTesla support, then join the `S3XY_OBD` wifi
// (password 12345678). Editable in the app and remembered.
const kDefaultHost = '192.168.4.1';
const kDefaultPort = 1338;
const kDefaultSsid = 'S3XY_OBD';
const kDefaultPassword = '12345678';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(
      [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const DashApp());
}

/// The app's look; the layout tests render with it too.
final kTheme = ThemeData.dark(useMaterial3: true).copyWith(
  scaffoldBackgroundColor: Colors.black,
  textTheme: ThemeData.dark().textTheme.apply(fontFamily: kFont),
  // The landscape screen is short: 8 dp clear above and below a dialog,
  // not 24, leave the field being typed in room above a tall keyboard.
  dialogTheme: const DialogThemeData(
      insetPadding: EdgeInsets.symmetric(horizontal: 40, vertical: 8)),
);

class DashApp extends StatelessWidget {
  const DashApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tesla Dash',
        debugShowCheckedModeBanner: false,
        theme: kTheme,
        home: const DashPage(),
      );
}

class DashPage extends StatefulWidget {
  const DashPage({super.key, this.demo, this.bt});

  /// Pre-populated state instead of a live link. Lets the layout be rendered
  /// offline (see test/dash_shot_test.dart) without a car or a dongle.
  final Panda? demo;
  final Commander? bt;

  @override
  State<DashPage> createState() => _DashPageState();
}

class _DashPageState extends State<DashPage> {
  late final Panda _obd = widget.demo ?? Panda();
  late final Commander _bt = widget.bt ?? Commander();
  String _host = kDefaultHost;
  int _port = kDefaultPort;
  String _ssid = kDefaultSsid;
  String _password = kDefaultPassword;
  // The gaps around a WiFi stream's start (see [_stepAside]), in ms, tuned
  // in the WiFi dialog: after Bluetooth steps aside, before the hello; and
  // once the stream is live, before Bluetooth takes car data again. 1 s
  // and 5 s held in the car.
  int _settleMs = 1000, _rejoinMs = 5000;

  void _connect({bool now = false}) =>
      _obd.connect(_host, _port, ssid: _ssid, password: _password, now: now);

  @override
  void initState() {
    super.initState();
    _bt.onData = _obd.fromBt; // the Commander's data stands in for WiFi's
    if (widget.demo == null) _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _host = prefs.getString('host') ?? kDefaultHost;
    _port = prefs.getInt('port') ?? kDefaultPort;
    _ssid = prefs.getString('ssid') ?? kDefaultSsid;
    _password = prefs.getString('password') ?? kDefaultPassword;
    _settleMs = prefs.getInt('btSettleMs') ?? _settleMs;
    _rejoinMs = prefs.getInt('btRejoinMs') ?? _rejoinMs;
    // The last pressures seen: the car sends them only on the move and shows
    // its stored ones when parked, as the dash then does too.
    final t = prefs.getStringList('tyres');
    if (t != null && t.length == 4) {
      final v = [for (final s in t) double.tryParse(s)];
      _obd
        ..tpFL ??= v[0]
        ..tpFR ??= v[1]
        ..tpRL ??= v[2]
        ..tpRR ??= v[3];
    }
    _tyres = [_obd.tpFL, _obd.tpFR, _obd.tpRL, _obd.tpRR];
    if (mounted) setState(() {});
    _obd.addListener(_linksChanged);
    _obd.addListener(_saveTyres);
    _bt.addListener(_linksChanged);
    // Back in front (phone woke, or the S3XY app was used): try both now.
    _life = AppLifecycleListener(onResume: () {
      _obd.kick();
      _bt.kick();
    });
    // Bluetooth first, then the WiFi stream, took the Commander down; the
    // other way round held. So each new stream waits for Bluetooth to step
    // aside, and Bluetooth comes back once the stream runs.
    _obd.beforeStream = _stepAside;
    _connect();
    _bt.connect();
  }

  Timer? _btBack;
  bool _streamSeen = true; // the last step-aside was followed by a stream

  /// Before a WiFi stream starts: Bluetooth off the Commander (see
  /// [Commander.pause]), and back once the stream is live ([_linksChanged])
  /// or, should it never be, after a while.
  Future<void> _stepAside() async {
    // iOS cannot tell whether S3XY_OBD is joined, so every WiFi retry gets
    // here, ScanMyTesla off too, and Bluetooth (then the whole dash) would
    // never stay up. Once a step-aside brought no stream, none until one
    // shows. ponytail: a retry after that goes out with Bluetooth up.
    if (!_streamSeen && defaultTargetPlatform == TargetPlatform.iOS) return;
    _streamSeen = false;
    _btBack?.cancel();
    // Back with the buttons only once the stream runs ([_linksChanged]).
    _bt.dataHold = true;
    _bt.resumeAt = DateTime.now().add(const Duration(seconds: 15));
    _btBack = Timer(const Duration(seconds: 15), () {
      _bt.dataHold = false; // no stream came: Bluetooth carries the dash
      _bt.resume();
    });
    // A link was up: give the Commander a moment before the hello.
    if (await _bt.pause()) await Future<void>.delayed(Duration(milliseconds: _settleMs));
  }

  AppLifecycleListener? _life;
  List<double?> _tyres = const [null, null, null, null];

  /// Keeps new pressures for the next start (see [_load]).
  void _saveTyres() {
    final o = _obd, t = [o.tpFL, o.tpFR, o.tpRL, o.tpRR];
    if (listEquals(t, _tyres)) return;
    _tyres = t;
    SharedPreferences.getInstance()
        .then((p) => p.setStringList('tyres', [for (final v in t) v?.toString() ?? '']));
  }
  bool _wasLive = false, _wasReady = false, _wasApproving = false;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _approval;

  void _linksChanged() {
    _bt.wifiLive = _obd.wifiLive;
    // The stream runs: Bluetooth back on after a moment, onto a Commander
    // already streaming. Either link reaching the Commander means it is
    // awake: the other one tries without waiting out its backoff.
    if (_obd.wifiLive && !_wasLive) {
      _wasLive = true; // first: the kick below may notify, and land here again
      _streamSeen = true;
      _btBack?.cancel();
      // The buttons at once, no car data yet; what WiFi lacks after the
      // wait, on the same link.
      _bt.resume();
      _bt.kick();
      _bt.dataAt = DateTime.now().add(Duration(milliseconds: _rejoinMs));
      _btBack = Timer(Duration(milliseconds: _rejoinMs), () => _bt.dataHold = false);
    }
    if (_bt.ready && !_wasReady) _obd.kick(); // it still scans: no WiFi with ScanMyTesla off
    final flipped = _bt.approving != _wasApproving;
    _wasLive = _obd.wifiLive;
    _wasReady = _bt.ready;
    _wasApproving = _bt.approving;

    // The one step that needs a hand: say so until it is done. Another
    // message may have replaced the prompt meanwhile; only close our own.
    if (!flipped || !mounted) return;
    _approval?.close();
    _approval = null;
    if (!_bt.approving) return;
    // Cleared first, so the prompt is the current bar and close() is safe.
    final bar = (ScaffoldMessenger.of(context)..clearSnackBars()).showSnackBar(const SnackBar(
      duration: Duration(minutes: 2),
      content: Text('Approve this phone for the Commander: '
          'in the car, double-press the right scroll wheel'),
    ));
    bar.closed.then((_) {
      if (identical(_approval, bar)) _approval = null;
    });
    _approval = bar;
  }

  @override
  void dispose() {
    _btBack?.cancel();
    _life?.dispose();
    if (widget.demo == null) _obd.dispose(); // only what we created
    if (widget.bt == null) _bt.dispose();
    super.dispose();
  }

  /// Google Maps in the other half of the screen; the dash then lays itself
  /// out for the half it keeps (see [_Compact]).
  Future<void> _maps() async {
    final r = await const MethodChannel('tesla_dash/net')
        .invokeMethod<String>('openMaps')
        .catchError((_) => 'missing');
    // The first time, Android asks to let the app hold the split landscape.
    final say = switch (r) {
      'opened' => null,
      'asked' => 'Allow Tesla Dash to modify system settings, so split screen '
          'stays landscape, then tap the map again',
      _ => 'Google Maps is not installed',
    };
    if (say != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(say), duration: const Duration(seconds: 10)));
    }
  }

  /// The Bluetooth icon: what the Commander link is doing, and try it now.
  void _btStatus() {
    if (_approval != null) return; // the approval prompt already says it all
    if (!_bt.ready) _bt.kick(ask: true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 8),
          // Connected, also say where the nav data stands: subscribed, how
          // much came, and whether the Commander's own car link is up.
          content: Text(_bt.ready
              ? 'Commander Bluetooth: connected\nCar data: ${_bt.pushInfo}, '
                  '${_bt.pushCount} pushes. ${_bt.carLink}.'
              : 'Commander Bluetooth: ${_bt.status}')));
  }

  /// Presses an S3XY function over Bluetooth. Frunk and trunk only in P: a
  /// lid rising at speed blinds the driver, whatever the car would allow.
  Future<void> _press(S3xyAction a) async {
    String? err;
    if (!_bt.ready) {
      _bt.kick(ask: true); // look now, and offer to switch Bluetooth on
      err = 'Commander Bluetooth: ${_bt.status}';
    } else if (a.opens && !_obd.parked) {
      err = const {'R', 'N', 'D'}.contains(_obd.gear)
          ? '${a.label} opens in P only'
          : _bt.dash && !_obd.live
              ? '${a.label}: no gear while the S3XY Dash has the car data (turn ScanMyTesla on)'
              : '${a.label}: gear unknown — no live data';
    } else if (a == S3xyAction.mirrorTilt && const {'P', 'N', 'D'}.contains(_obd.gear)) {
      err = 'Mirror tilt acts in R only'; // S3XY: auto-tilt override, Reverse
    } else {
      try {
        await _bt.tryAction(a);
      } catch (e) {
        err = '${a.label}: $e';
      }
    }
    // While approving, the approval prompt already says what is needed, if
    // it is still up.
    if (err == null || !mounted || (_bt.approving && _approval != null)) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(err)));
  }

  Future<void> _settings() async {
    final host = TextEditingController(text: _host);
    final port = TextEditingController(text: '$_port');
    final ssid = TextEditingController(text: _ssid);
    final password = TextEditingController(text: _password);
    // A gap, in seconds, on a slider; it applies and is kept on release.
    Widget gap(String label, int ms, double maxS, String key, void Function(int) set, StateSetter redraw) =>
        Row(children: [
          Expanded(child: Text('$label: ${(ms / 1000).toStringAsFixed(1)} s')),
          SizedBox(
            width: 240,
            child: Slider(
              value: ms / 1000,
              max: maxS,
              divisions: (maxS * 10).round(), // 100 ms steps
              onChanged: (v) => redraw(() => set((v * 1000).round())),
              onChangeEnd: (v) async =>
                  (await SharedPreferences.getInstance()).setInt(key, (v * 1000).round()),
            ),
          ),
        ]);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, redraw) => AlertDialog(
        // The landscape screen is short: the fields go two to a row to fit
        // above the buttons, and scroll when the keyboard takes half of it.
        scrollable: true,
        title: const Text('Commander link'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          // What the WiFi icon stands for.
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
                _obd.wifiLive ? 'Live: ${_obd.frameHz} frames/s from $_host:$_port' : _obd.status,
                style: const TextStyle(color: Colors.white70)),
          ),
          Row(children: [
            Expanded(
              child: TextField(
                controller: ssid,
                decoration: const InputDecoration(labelText: 'WiFi name'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: password,
                decoration: const InputDecoration(labelText: 'WiFi password'),
              ),
            ),
          ]),
          Row(children: [
            Expanded(
              child: TextField(
                controller: host,
                decoration: const InputDecoration(labelText: 'Host'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Port'),
              ),
            ),
          ]),
          // Bluetooth stays off the Commander while its WiFi stream starts:
          // the dash has no buttons for that spell, shorter if these hold.
          const SizedBox(height: 8),
          gap('Bluetooth off before WiFi starts', _settleMs, 5, 'btSettleMs',
              (v) => _settleMs = v, redraw),
          gap('Bluetooth data after WiFi is live', _rejoinMs, 10, 'btRejoinMs',
              (v) => _rejoinMs = v, redraw),
        ]),
        actions: [
          // Bluetooth sticks to the Commander it was approved on; this lets
          // it pair with a replacement.
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'forget'),
            child: const Text('Find another Commander'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'diag'),
            child: const Text('Diagnostics'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('Reconnect'),
          ),
        ],
      )),
    );
    if (!mounted) return;
    if (action == 'diag') {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => DiagPage(obd: _obd, bt: _bt)),
      );
      return;
    }
    if (action == 'forget') {
      await _bt.forget();
      return;
    }
    if (action != 'save') return;
    final prefs = await SharedPreferences.getInstance();
    _host = host.text.trim();
    _port = int.tryParse(port.text.trim()) ?? kDefaultPort;
    _ssid = ssid.text.trim();
    _password = password.text;
    await prefs.setString('host', _host);
    await prefs.setInt('port', _port);
    await prefs.setString('ssid', _ssid);
    await prefs.setString('password', _password);
    if (mounted) setState(() {});
    _connect(now: true); // asked for: try the network even if not seen yet
  }

  @override
  Widget build(BuildContext context) {
    // ponytail: the fixed landscape layout fits the S23 Ultra up to a 1.15
    // font scale; a FittedBox per column if bigger settings must apply.
    return MediaQuery.withClampedTextScaling(maxScaleFactor: 1.15, child: Scaffold(
      // Nothing to type on the dash itself: a dialog's keyboard slides over
      // it rather than squeezing the fixed layout into what is left.
      resizeToAvoidBottomInset: false,
      body: ListenableBuilder(
        listenable: Listenable.merge([_obd, _bt]),
        builder: (context, _) {
          final o = _obd;
          // Nothing moving on screen outlives the stream: a stalled link
          // blanks speed, power and pedal and drops the glows.
          final live = o.live;
          return Stack(fit: StackFit.expand, children: [
            // Edge glows sit under the dash so they never cover the buttons:
            // indicators blink green in step with the car's flasher, blind
            // spot holds a steady red, brake red at the foot.
            if (live && o.braking) const _Edge(side: _Side.bottom, color: Color(0xFFE23D3D)),
            if (live && (o.blindL || (o.indL && o.blinkLit)))
              _Edge(side: _Side.left, color: o.blindL ? const Color(0xFFE23D3D) : kRegen),
            if (live && (o.blindR || (o.indR && o.blinkLit)))
              _Edge(side: _Side.right, color: o.blindR ? const Color(0xFFE23D3D) : kRegen),
            // Beside Google Maps, or in any split, the window is about half
            // as wide: the essentials only, laid out for it.
            if (MediaQuery.sizeOf(context).width < 700)
              SafeArea(child: _Compact(obd: o, bt: _bt))
            else
              SafeArea(
                child: Stack(children: [
                // The pedal: a solid line along the top, growing from the
                // ring's centre as it goes down; no figure. Within the safe
                // area as the ring is: edge to edge, the camera's cutout
                // widens one side and the screen's centre is not the ring's.
                if (live)
                  IgnorePointer(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: AnimatedFractionallySizedBox(
                        duration: const Duration(milliseconds: 140),
                        widthFactor: (o.pedalPct ?? 0).clamp(0, 100) / 100,
                        child: Container(height: 4, color: kAccent),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                  child: Column(children: [
                    Expanded(
                      child: Row(children: [
                        _Actions(obd: o, bt: _bt, onTap: _press),
                        Expanded(child: _SideColumn(children: [
                          _Lights(obd: o),
                          // Only WiFi has the tyres; none over Bluetooth.
                          if (!o.viaBt) _Tyres(obd: o),
                          _Cabin(obd: o),
                        ])),
                        AspectRatio(
                          aspectRatio: 1,
                          child: RingGauge(
                            frontKw: live ? o.frontKw : null,
                            rearKw: live ? o.rearKw : null,
                            regenCapKw: live && o.gear != 'P' ? o.regenMaxKw : null, // no regen parked
                            // Digital speed sits in the ring, the gear under it.
                            child: _Centre(obd: o, gear: true),
                          ),
                        ),
                        // The battery dial and the pack's figures pinned top and
                        // bottom, so they stay put as cards come and go between
                        // them; the dial's top level with the first button's.
                        Expanded(child: Column(children: [
                          Padding(padding: const EdgeInsets.fromLTRB(8, 14, 8, 0), child: _Battery(obd: o)),
                          Expanded(child: _SideColumn(children: [
                            ?_autopilot(o),
                            if (o.wifiLive && o.charging) _Charge(obd: o),
                            // The g-meter once WiFi brings it, out of P (parked
                            // it only reads 0); charging, the charge card has
                            // its place.
                            if (o.wifiLive && !o.charging && o.gear != 'P' && (o.gLong != null || o.gLat != null))
                              _GBall(obd: o),
                          ])),
                          Padding(padding: const EdgeInsets.only(bottom: 4), child: _Pack(obd: o)),
                        ])),
                        _Actions(obd: o, bt: _bt, onTap: _press, right: true),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _Controls(
                        obd: o,
                        bt: _bt,
                        onWifi: _settings,
                        onBt: _btStatus,
                        onMaps: _maps,
                      ),
                    ),
                  ]),
                ),
                ]),
              ),
          ]);
        },
      ),
    ));
  }
}

/// The driver-assist state, lit while it steers; over it, the car's
/// hands-on nag: amber to look, red once it chimes, slows or locks
/// Autopilot out for the drive.
Widget? _autopilot(Panda o) {
  final nag = switch (o.live ? o.handsOn : null) {
    3 => ('HOLD WHEEL', kWarn),
    4 || 5 || 9 || 10 => ('HOLD WHEEL', kAlert),
    6 => ('SLOWING', kAlert),
    7 => ('AP LOCKED', kAlert),
    _ => null,
  };
  if (nag case (final text, final color)) return _Pill(text, live: true, color: color);
  final ap = o.autopilot;
  return ap == null
      ? null
      : _Pill(ap, live: ap.contains('AUTOPILOT') || ap.startsWith('NAV') || ap == 'FSD');
}

/// The dash in half a screen, beside Google Maps or any other split: speed
/// and power in the ring, the gear and the battery above, the assist state
/// and the route below. Lights, tyres, pack, pedal, the seat map and the
/// buttons wait for the full screen.
class _Compact extends StatelessWidget {
  const _Compact({required this.obd, required this.bt});

  final Panda obd;
  final Commander bt;

  @override
  Widget build(BuildContext context) {
    final o = obd, live = o.live;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Column(children: [
        SizedBox(
          height: 38,
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            // Just the gear it is in.
            Text(o.gear,
                style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: const {'P', 'R', 'N', 'D'}.contains(o.gear)
                        ? Colors.white
                        : Colors.white38)),
            // Between them, only what earns a look: someone unbuckled (the
            // seat, red; WiFi only), the air outside, the grip lamp while lit.
            // The grip glyph keeps its place while dark, so the temperature
            // does not jump as it comes and goes; the group shrinks to fit.
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (o.wifiLive && o.anyBeltUnbuckled)
                    const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(Icons.airline_seat_recline_normal, size: 24, color: kAlert)),
                  if (o.outsideC case final c?)
                    Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(_deg(c).replaceFirst(' °C', '°'),
                            style: TextStyle(fontSize: 18, color: c <= 3 ? kCold : Colors.white70))),
                  if (o.wifiLive)
                    Opacity(
                      opacity: o.gripLit ? 1 : 0,
                      child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: GlyphIcon(Glyph.grip,
                              size: 22, color: o.gripHeld ? kWarn : kCold)),
                    ),
                ]),
              ),
            ),
            _BatteryLine(obd: o),
          ]),
        ),
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: RingGauge(
                frontKw: live ? o.frontKw : null,
                rearKw: live ? o.rearKw : null,
                regenCapKw: live && o.gear != 'P' ? o.regenMaxKw : null, // no regen parked
                child: _Centre(obd: o),
              ),
            ),
          ),
        ),
        Row(children: [
          if (_autopilot(o) case final ap?)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: SizedBox(height: 26, child: FittedBox(child: ap)),
            ),
          Expanded(
              child: o.wifiLive && o.charging
                  ? _Charge(obd: o, oneLine: true)
                  : _Nav(obd: o, bt: bt, oneLine: true)),
        ]),
      ]),
    );
  }
}

/// The battery for the compact dash: a thin gauge over the charge and the
/// range, as wide as they are.
class _BatteryLine extends StatelessWidget {
  const _BatteryLine({required this.obd});

  final Panda obd;

  @override
  Widget build(BuildContext context) {
    final pct = obd.socPct, range = obd.range;
    return IntrinsicWidth(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
      // Painted, not a FractionallySizedBox: that one's intrinsic width is
      // its child's over the fraction, infinite at 0 % (or no reading),
      // which IntrinsicWidth cannot lay out.
      SizedBox(
        height: 5,
        child: CustomPaint(
            painter: _BarPainter(((pct ?? 0).clamp(0, 100) / 100).toDouble(),
                (pct ?? 100) < 20 ? kAlert : kRegen)),
      ),
      const SizedBox(height: 3),
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text(pct == null ? '—' : '${pct.round()}%',
            style: const TextStyle(fontSize: 16, height: 1.2, color: Colors.white)),
        // The pack too cold for full regen and power: the car's own sign.
        if ((obd.packTempC ?? 99) <= 10)
          const Padding(
              padding: EdgeInsets.only(left: 3),
              child: Icon(Icons.ac_unit, size: 14, color: kCold)),
        if (range != null)
          Text('  ${range.round()} ${obd.rangeUnit}',
              style: const TextStyle(fontSize: 13, height: 1.2, color: Colors.white70)),
      ]),
    ]));
  }
}

/// A thin rounded gauge on a faint track, filled to [fraction] of its width.
class _BarPainter extends CustomPainter {
  _BarPainter(this.fraction, this.color);

  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, r), Paint()..color = Colors.white10);
    if (fraction > 0) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(Offset.zero & Size(size.width * fraction, size.height), r),
          Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.fraction != fraction || old.color != color;
}
