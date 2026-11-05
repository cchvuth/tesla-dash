import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'signals.dart';

/// Live vehicle state, read off the CAN bus through the S3XY Commander's
/// panda interface (the same one Scan My Tesla uses).
///
/// Enable it first: S3XY Buttons app -> Commander Settings -> ScanMyTesla
/// support. The Commander then raises the `S3XY_OBD` access point, password
/// `12345678`, and streams CAN over UDP on 192.168.4.1:1338.
///
/// Fields are mutated in place and listeners notified at ~30 Hz — CAN arrives
/// far faster than the screen can draw.
/// What the WiFi link is doing, for its icon (see [Panda.link]).
enum WifiLink {
  idle, // not started
  wifiOff, // the phone's WiFi is switched off
  scanning, // looking for the Commander's network
  joining, // asking Android for it (its dialog, the first time)
  hello, // socket open, waiting for the Commander's answer
  live,
  quiet, // live, but silent a few seconds: resubscribing
  away, // the network is not in range: car asleep, or ScanMyTesla off
  retrying,
}

class Panda extends ChangeNotifier {
  static const _net = MethodChannel('tesla_dash/net');

  double speed = 0; // in the car's display units
  double? frontKw;
  double? rearKw;

  /// The battery's power now, kW (draw positive): motors, climate and 12 V.
  double? packKw;

  /// What draws on the pack beside the motors, kW: the climate (heat pump
  /// compressor and cabin heater), the 12 V side, and the rest of the gap
  /// between the pack and the motors (battery heating, pumps...). WiFi only.
  double? lvKw;
  double? _compKw, _heatLKw, _heatRKw, _lvV;
  double? get climateKw => _compKw == null && _heatLKw == null && _heatRKw == null
      ? null
      : (_compKw ?? 0) + (_heatLKw ?? 0) + (_heatRKw ?? 0);
  /// The rest of what the pack feeds (battery heating, pumps...): averaged
  /// slowly, as the motor frames it comes from run behind the pack.
  double? get otherKw => _other;
  double? _packV, _frontAt, _rearAt, _other;

  /// The motor frames come about once a second and run about a second behind
  /// the pack's (~100 a second): on a drive's trace they matched the pack a
  /// second earlier best (median 1.3 kW off, against 2.2 kW now). So the
  /// motors shown are the pack now less what else it feeds (measured climate
  /// and 12 V, and the averaged rest), shared front and rear as in the last
  /// motor frame. A motor frame only resets that share and nudges the rest:
  /// putting its value up would pull the readout a second back.
  void _motorFrame() {
    final p = packKw;
    if (p == null || _rearAt == null) return; // the rear reports first on this car
    final rest = (p - (_frontAt ?? 0) - (_rearAt ?? 0) - (climateKw ?? 0) - (lvKw ?? 0)).clamp(0, 5).toDouble();
    final o = _other;
    _other = o == null ? rest : o + (rest - o) * 0.05; // about 20 frames' worth
  }

  /// The exact motor values in P, or before the pack has been heard.
  bool get _exact => packKw == null || _other == null || _gear == 'P';

  void _blend() {
    final p = packKw, other = _other, f = _frontAt, r = _rearAt;
    if (_exact || p == null || other == null || r == null) {
      frontKw = f;
      rearKw = r;
      return;
    }
    final motors = p - (climateKw ?? 0) - (lvKw ?? 0) - other;
    // Both near zero: the rear pulls away first on this car.
    final share = (f ?? 0).abs() + r.abs() > 1 ? r.abs() / ((f ?? 0).abs() + r.abs()) : 1.0;
    rearKw = motors * share;
    if (f != null) frontKw = motors * (1 - share);
  }

  double? pedalPct;
  double? socPct;
  double? rangeMi;
  double? speedLimit;
  bool braking = false;
  bool kph = true;
  String? recirc;
  String? autopilot;
  bool indL = false, indR = false; // signalling, whichever the phase

  /// The indicator strips' on half, in step with the car's flasher and so
  /// its clicks. 0x3F5 reports the phase only every 100 ms or so, and shown
  /// raw that blinks raggedly and late. So each on-edge the car reports
  /// lights the strips for half the car's own cycle, learnt from those edges.
  bool blinkLit = false;
  bool _litL = false;
  int _wasLit = 0, _edgeLit = 0; // lamps lit: 1 left, 2 right
  int _halfMs = 360; // the flasher's half cycle (a Juniper's: 361 ms); learnt
  DateTime? _edgeAt;
  Timer? _blinkOff;

  void _flasher(int lit) {
    // An on-edge: a lamp lit that was not, either side (a straight switch
    // from left to right included).
    if (lit & ~_wasLit != 0) {
      final now = DateTime.now();
      // The cycle is learnt only between edges of the same lamps.
      final gap = _edgeAt == null || lit != _edgeLit
          ? 0
          : now.difference(_edgeAt!).inMilliseconds;
      if (gap > 450 && gap < 1100) _halfMs = (_halfMs * 3 + gap ~/ 2) ~/ 4;
      _edgeAt = now;
      _edgeLit = lit;
      blinkLit = true;
      _blinkOff?.cancel();
      _blinkOff = Timer(Duration(milliseconds: _halfMs), () {
        blinkLit = false;
        notifyListeners();
      });
      notifyListeners(); // now: the on-edge must not wait for a throttled push
    }
    _wasLit = lit;
    if (!indL && !indR) {
      _blinkOff?.cancel();
      blinkLit = false;
      _edgeAt = null;
    }
  }
  bool blindL = false, blindR = false;
  double? tpFL, tpFR, tpRL, tpRR;
  final _tp219 = <String>{}; // wheels 0x219 page 5 has given: 0x25A stops writing those
  bool navRoute = false;
  double? navEnergyKwh, navMinutes;
  bool doorFL = false, doorFR = false, doorRL = false, doorRR = false;
  bool trunk = false, frunk = false, mirrorDipped = false, tiltAuto = false;
  bool chargePort = false;
  bool mapLight = false; // any overhead map light on
  bool hvacOn = false, recircOn = false; // recircOn: most of the air recirculated
  bool beltDriver = false, beltPass = false, belt2L = false, belt2C = false, belt2R = false;
  bool belt3L = false, belt3R = false;
  final buckled = <String>{}; // seats whose belt is buckled: D, P, 2L, 2C, 2R, 3L, 3R
  bool? lowBeam, highBeam, drl;
  bool _highFn = false, _highLamp = false; // 0x3F5 flash/latch, 0x3F6 lamps
  double? cellVMax, cellVMin; // V
  double? packKwh; // nominal full pack
  double? packLeftKwh, packBufferKwh; // nominal energy left; below the screen's 0 %
  double? packNewKwh; // the same, when the pack was new
  String? domeLight; // OFF / ON / AUTO

  // Weather and grip.
  double? outsideC; // filtered on speed, as the car's screen shows it
  bool washerLow = false;
  bool slippery = false; // the car judges the road slippery
  bool gripHeld = false; // traction or stability control stepped in just now
  String? tcMode; // 'SLIP' (Slip Start) or 'OFF-RD' (Off-Road Assist) left on

  // Acceleration in g, smoothed: along the car (positive speeding up) and
  // across it (positive towards the left, turning left: the yaw rate times
  // the speed). WiFi only. And this drive's peaks, since leaving P.
  double? gLong, gLat;
  double gMaxAccel = 0, gMaxBrake = 0, gMaxLat = 0;

  /// GRIP worth a look: the car stepping in or calling the road slippery,
  /// and only while moving. Stopped in D, the car was seen raising one of
  /// them with nothing slipping ([gripBits] says which).
  bool get gripLit => speed >= 1 && (gripHeld || slippery);

  /// The raw grip bits, for the Diagnostics log.
  String get gripBits => 'tc flash $_tcFlash, esc flash $_escFlash, '
      'slippery ui $_slipUi, mode ${_slipMode ? 'SLIPPERY' : tcMode ?? 'normal'}';

  // The pack's temperature and heating.
  double? packTempC; // the coldest cells
  bool packHeating = false;
  double? precondC; // the target while the nav heats the pack for a charger

  // The cabin, by row.
  int? co2ppm;
  double? cabinC1, cabinC2, cabinC3;
  // Each row's fan as the screen sets it: OFF or its speed (1-10 in front,
  // LOW, MED or HIGH in the second row), or on Auto Auto's level (LOW, MED
  // or HIGH). The third row has none.
  String? fan1, fan2;
  int? autoBlower; // Auto's raw level (UI_hvacReqAutoBlowerLevel), for Diagnostics

  // Driver assist.
  double? regenMaxKw; // the most regen the pack takes now: less cold or full
  int? handsOn; // DAS_autopilotHandsOnState: the nag's level
  double? cruiseSet; // while cruise holds a speed, in the display unit
  int? followGap; // 1..7

  // What one frame says that the next needs.
  bool _slipUi = false, _slipMode = false, _tcFlash = false, _escFlash = false;
  DateTime? _gripAt;
  bool _heatMotors = false, _heatPump = false, _heatNav = false;
  bool _cruiseOn = false, _climateOn = false;
  double _cruiseRaw = 0;

  // Charging.
  bool charging = false;
  double? chargeKw, chargeMaxKw; // going in, and the most it takes now
  String? chargeWhy; // what holds it back: COLD PACK, CHARGER, FULL...
  int? chargeLimitPct, chargeMinutes;

  /// Spread between the strongest and weakest cell group, mV.
  double? get imbalanceMv =>
      cellVMax == null || cellVMin == null ? null : (cellVMax! - cellVMin!) * 1000;

  bool get anyBeltUnbuckled =>
      beltDriver || beltPass || belt2L || belt2C || belt2R || belt3L || belt3R;

  /// Every write stamps the gear's age. 0x118 comes every 10 ms, so a P
  /// older than 2 s means the link stalled, and [parked] then fails closed:
  /// it is what lets the frunk and trunk be opened. Two clocks: the
  /// stopwatch stops while the phone sleeps, the wall clock can jump. Over
  /// Bluetooth the Commander pushes each change while its link is up, so a
  /// P of any age holds.
  String get gear => _gear;
  set gear(String g) {
    _gear = g;
    _gearAt = DateTime.now();
    _gearAge
      ..reset()
      ..start();
  }

  String _gear = '—';
  DateTime _gearAt = DateTime.fromMillisecondsSinceEpoch(0);
  final _gearAge = Stopwatch();
  bool get parked =>
      _gear == 'P' &&
      (viaBt ||
          _gearAge.elapsedMilliseconds < 2000 &&
              DateTime.now().difference(_gearAt).inMilliseconds < 2000);

  /// Frames are arriving now over WiFi.
  bool get wifiLive => status == 'live';

  /// The Commander's Bluetooth values stand in: no WiFi frames, and that
  /// link up and pushing (ScanMyTesla off). Values only WiFi has go stale
  /// then, and the dash hides them.
  // Car data, not just the route and recirculation a lean session (see
  // Commander.wifiLive) brings: else WiFi's last values would pass as live.
  bool get viaBt => !wifiLive && (_bt?.keys.any(btFields.contains) ?? false);

  /// Values are current, over either link; anything else is a connecting or
  /// stalled link.
  bool get live => wifiLive || viaBt;

  /// The Commander's vehicle data, merged: each push holds only what
  /// changed. Null while its Bluetooth link is down.
  Map<int, Object>? _bt;

  /// The pushed fields [fromBt] reads, which the Commander subscribes to.
  static const btFields = [27, 32, 34, 35, 36, 37, 42, 43, 44, 49, 51, 53, 61, 62, 63, 64,
      65, 66, 80, 81, 82, 85, 105, 106, 107, 108, 110, 111, 112, 113, 114, 115, 116,
      117, 118];

  /// A Commander push, or null when its link dropped. WiFi comes first: the
  /// values are kept, and applied only while no frames come over WiFi.
  void fromBt(Map<int, Object>? d) {
    if (d == null) {
      _bt = null;
      if (wifiLive) return;
      _forget(); // its values go with it
    } else {
      (_bt ??= {}).addAll(d);
      if (wifiLive) return;
      _applyBt(_bt!);
    }
    notifyListeners();
  }

  /// The Commander copies the car's own codes and raw counts, so these are
  /// the WiFi signals' enums and scales.
  void _applyBt(Map<int, Object> d) {
    int? at(int f) => switch (d[f]) { final int v => v, _ => null };
    // Lamps: two LightStatus nibbles, a side each; 1 is ON.
    bool? lamp(int f) => switch (at(f)) { final v? => v & 15 == 1 || v >> 4 & 15 == 1, _ => null };
    // SNA skipped, as on WiFi: latch 0, pedal 255, power -1024.
    bool? open(int f) => switch (at(f)) { final v? when v != 0 => kLatchOpen.contains(v), _ => null };
    // sint32 comes zigzagged.
    int? z(int f) => switch (at(f)) { final v? => (v >> 1) ^ -(v & 1), _ => null };
    // 0.5 kW a count, regen negative.
    double? kw(int f) => switch (z(f)) { final v? when v != -1024 => v * 0.5, _ => null };

    // The car's display unit, as on its screen; 511 is SNA. ponytail: the
    // unit is WiFi's last (km/h until it has one); keep kph if an mph car
    // ever starts without WiFi.
    if (at(61) case final v? when v < 511) speed = v.toDouble();
    if (at(62) case final v? when v != 255) pedalPct = (v * 0.4).clamp(0, 100).toDouble();
    if (at(66) case final v?) gear = kGears[v] ?? '—';
    if (at(65) case final v?) braking = v != 0 && const {'R', 'N', 'D'}.contains(_gear);
    // TurnSignalStatus: 1 signalling with the lamp dark, 2 lamp lit.
    final l = at(63) ?? 0, r = at(64) ?? 0;
    indL = l != 0;
    indR = r != 0;
    _flasher((l == 2 ? 1 : 0) | (r == 2 ? 2 : 0));
    if (at(106) case final v?) blindL = v == 1 || v == 2;
    if (at(107) case final v?) blindR = v == 1 || v == 2;
    if (kw(51) case final v?) frontKw = v;
    if (kw(53) case final v?) rearKw = v;
    if (at(111) case final v?) socPct = v.clamp(0, 100).toDouble();
    if (at(112) case final v?) rangeMi = v.toDouble(); // miles, always
    if (at(110) case final v?) speedLimit = v == 0 || v >= 155 ? null : v.toDouble();
    // The Commander's own code, not the bus's DAS_autopilotState: 1 cruise
    // (TACC), 2 and 3 steering. Lit, as on WiFi, only while it steers.
    if (at(105) case final v?) autopilot = switch (v) { 1 => 'TACC', 2 || 3 => 'AUTOPILOT', _ => null };
    if (lamp(81) case final v?) lowBeam = v;
    if (lamp(82) case final v?) highBeam = v;
    // The light bar, as on WiFi: the DRL by day, the position lamps by night.
    final day = lamp(80), night = lamp(85);
    if (day != null || night != null) drl = day == true || night == true;
    if (open(113) case final v?) doorFL = v;
    if (open(114) case final v?) doorFR = v;
    if (open(115) case final v?) doorRL = v;
    if (open(116) case final v?) doorRR = v;
    if (open(117) case final v?) frunk = v;
    if (open(118) case final v?) trunk = v;
    if (at(34) case final v? when v >= 400 && v <= 1100) packNewKwh = v * 0.1;
    if (at(35) case final v?) packKwh = v * 0.02 < 30 || v * 0.02 > 150 ? null : v * 0.02;
    if (at(36) case final v?) packLeftKwh = v * 0.02 > 150 ? null : v * 0.02;
    if (at(37) case final v?) packBufferKwh = v * 0.01 > 20 ? null : v * 0.01;
    if (at(43) case final v?) cellVMax = v * 0.002 > 5 ? null : v * 0.002;
    if (at(44) case final v?) cellVMin = v * 0.002 > 5 ? null : v * 0.002;
    if (z(27) case final v?) outsideC = v.toDouble(); // whole °C
    if (at(32) case final v?) regenMaxKw = v * 0.01;
    if (z(42) case final v?) packTempC = v * 0.5; // the coldest cells, °C
    if (at(49) case final v?) packHeating = v == 1; // BPS_Active
    if (at(108) case final v?) handsOn = v == 15 ? null : v; // as 0x399's
  }

  /// One line for the trace file (main's _traceTick): the link, what the
  /// dash shows, and the raw sources behind its power and regen readouts.
  String traceLine() {
    String raw(int id) => switch (frames[id]) {
          final f? => '${id.toRadixString(16)}[bus ${f.lastBus}, ${f.count}] ${f.recent.map(hexOf).join(' / ')}',
          _ => '${id.toRadixString(16)}[none]',
        };
    final b = _bt;
    return 'wifi "$status" ${frameHz}Hz speed ${speedHz}Hz foreign ${foreignHz}Hz resubs $resubscribes live=$wifiLive viaBt=$viaBt gear=$gear speed=$speed '
        'front=$frontKw rear=$rearKw pack=${packKw?.toStringAsFixed(1)} climate=${climateKw?.toStringAsFixed(2)} 12v=${lvKw?.toStringAsFixed(2)} other=${otherKw?.toStringAsFixed(2)} regenMax=$regenMaxKw | ${raw(0x2E5)} | ${raw(0x266)} | ${raw(0x252)} | '
        'bt 51=${b?[51]} 53=${b?[53]} 32=${b?[32]} fields=${b?.length} | '
        'now 118 ${hexOf(frames[0x118]?.data ?? const [])} 2b6 ${hexOf(frames[0x2B6]?.data ?? const [])} '
        'brake=$braking slippery=$slippery';
  }

  /// Every signal as decoded from the newest payload that carries it (a
  /// multiplexed one from its page): for the trace, to spot a firmware
  /// update moving things. The ids' payloads come with the Diagnostics report.
  String traceDump() {
    String num(double v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(3);
    final b = StringBuffer('signals:');
    for (final e in kSignals.entries) {
      double? v;
      for (final d in frames[e.value.id]?.recent.reversed ?? const <List<int>>[]) {
        if ((v = decode(e.value, d)) != null) break;
      }
      b.write(' ${e.key}=${v == null ? '-' : num(v)}');
    }
    return '$b';
  }

  double? get range =>
      rangeMi == null ? null : (kph ? rangeMi! * 1.609344 : rangeMi!);

  /// The battery at arrival on the screen's own % scale: the car's energy at
  /// destination (0x347) is nominal, and the screen's 0 % sits a buffer
  /// above empty: e.g. 58.6 % for 49.44 kWh at 60 % now.
  double? get arrivePct {
    final e = navEnergyKwh, full = packKwh, buf = packBufferKwh;
    if (e == null || full == null || buf == null || full <= buf) return null;
    return ((e - buf) / (full - buf) * 100).clamp(0, 100).toDouble();
  }

  /// The range left at arrival for a battery % at arrival ([arrivePct], or
  /// the car's own over Bluetooth): the range on screen now, scaled by the %
  /// at arrival over the % now. The % now from the kWh rather than the
  /// screen's rounded one, which would move a short trip's drop by 8 % (60.0
  /// for 60.12). In the range unit; e.g. 301 km for 309 now.
  double? rangeAt(double? pct) {
    final full = packKwh, left = packLeftKwh, buf = packBufferKwh, r = range;
    if (pct == null || full == null || left == null || buf == null || r == null) return null;
    if (left <= buf || full <= buf) return null;
    return (r * pct / ((left - buf) / (full - buf) * 100)).clamp(0, r).toDouble();
  }

  /// The energy a route takes, kWh: the pack's now less what it will hold at
  /// arrival, the bus's own figure ([navEnergyKwh]) over WiFi, else [pct],
  /// the battery % at arrival on the screen's scale. That is the range the
  /// route uses (now less [rangeAt] arrival) at the energy per unit of range
  /// now, but it keeps counting past the screen's 0 %, where the range stops.
  double? tripKwh(double? pct) {
    final full = packKwh, left = packLeftKwh, buf = packBufferKwh, e = navEnergyKwh;
    final at = wifiLive && e != null
        ? e
        : pct == null || full == null || buf == null
            ? null
            : buf + pct / 100 * (full - buf);
    return left == null || at == null ? null : max(0.0, left - at);
  }
  String get speedUnit => kph ? 'km/h' : 'mph';
  String get rangeUnit => kph ? 'km' : 'mi';

  String status = 'disconnected';
  WifiLink _link = WifiLink.idle;

  /// The link's state for its icon; [status] says it in words.
  WifiLink get link => wifiLive ? WifiLink.live : _link;

  /// WiFi is looking for the Commander, joining or saying hello: its turn,
  /// so Bluetooth is not to start a link now (see [Commander.waitFor]). Also
  /// true from the instant a try starts: its kick or retry reaches [link] a
  /// platform call later, and Bluetooth would slip in between.
  bool get trying =>
      _starting ||
      const {WifiLink.idle, WifiLink.scanning, WifiLink.joining, WifiLink.hello}.contains(link);
  bool _starting = false;

  /// What [link] counts down to (a retry, the hello's answer, a quiet
  /// link's loss), or null.
  DateTime? until;
  DateTime? _wifiOnAt; // the phone's WiFi came on: look for the car quickly
  int frameHz = 0;

  /// Speed frames (0x257) a second. The car sends about 50: well under means
  /// the Commander is dropping frames and the dash runs behind.
  int speedHz = 0;
  int _speedFrames = 0;

  /// Frames a second for ids the dash never asked for, and how often the
  /// filter was sent again because of them (both in the trace).
  int foreignHz = 0, _foreign = 0, resubscribes = 0;
  DateTime _flooded = DateTime.fromMillisecondsSinceEpoch(0);

  /// Drive 1 on 2026.38.6: the Commander streamed all ~300 ids (2150 frames/s,
  /// speed 30 of 50 a second) though the filter went out, while the next
  /// drive got 37 ids (445/s, speed 45). A flood this size means the filter
  /// did not take: send it again, at most every 5 s.
  void _floodCheck(DateTime now) {
    if (_all || _foreign < 100 || now.difference(_flooded).inSeconds < 5) return;
    _flooded = now;
    resubscribes++;
    _subscribe();
  }

  /// Everything seen per CAN id, for the Diagnostics screen.
  final Map<int, Frame> frames = {};
  DateTime captureStart = DateTime.now();

  /// When set, ask the Commander for every id instead of just [kSubscribeIds].
  /// Costs latency on the dash — diagnostics only.
  bool _all = false;
  set captureAll(bool v) {
    if (_all == v) return;
    _all = v;
    frames.clear();
    captureStart = DateTime.now();
    _subscribe();
  }

  RawDatagramSocket? _sock;
  InternetAddress? _addr;
  int _port = 0;
  Timer? _keepAlive;
  int _frameCount = 0;
  DateTime? _lastRecv; // this socket's last frame, null until it has one
  DateTime? _lastFrame; // the last frame over any socket
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastHz = DateTime.now();

  /// Routes this app's sockets over the (internet-less) OBD WiFi so the phone
  /// keeps using mobile data for everything else. No-op off Android.
  Future<bool> _bindWifi(String ssid, String password) async {
    if (!Platform.isAndroid) return true;
    try {
      return await _net.invokeMethod<bool>(
              'bindWifi', {'ssid': ssid, 'password': password}) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> _wifiOn() async {
    try {
      return await _net.invokeMethod<bool>('wifiOn') ?? true;
    } on PlatformException {
      return true;
    }
  }

  Future<bool> _wifiNearby(String ssid) async {
    try {
      return await _net.invokeMethod<bool>('wifiNearby', {'ssid': ssid, 'ms': lookMs}) ?? true;
    } on PlatformException {
      return true;
    }
  }

  ({String host, int port, String ssid, String password})? _cfg;
  Timer? _retry;
  int _attempt = 0;
  DateTime? _connectedAt;
  bool _awake = false; // asked for: request the network without seeing it first

  /// Connects and keeps connecting: a failed attempt or a dead link retries
  /// with backoff until [disconnect] is called. Sitting in the car with the
  /// app open should never need a button press. [now]: ask for the network
  /// even before the phone has seen it (a Reconnect tap).
  Future<void> connect(String host, int port,
      {String ssid = 'S3XY_OBD', String password = '12345678', bool now = false}) async {
    await disconnect();
    _cfg = (host: host, port: port, ssid: ssid, password: password);
    _attempt = 0;
    _awake = now;
    // The phone's WiFi switched on (Android tells MainActivity): look for
    // the car now, from the quick steps, rather than out the backoff.
    _net.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'wifiEnabled':
          _wifiOnAt = DateTime.now();
          _attempt = 0;
          kick();
        case 'wifiDisabled':
          // Switched off mid-wait (or mid-stream): said now, not when the
          // countdown would have run out; 'wifiEnabled' starts the next look.
          if (_cfg == null) return;
          _gen++; // an attempt under way stops at its next step
          _retry?.cancel();
          await _teardown();
          _attempt++; // no WiFi panel: the owner just switched it off
          _set(WifiLink.wifiOff, 'wifi is off — turn it on');
      }
    });
    await _attemptConnect();
  }

  int _gen = 0; // the current attempt; an older one stops at its next await

  /// Awaited before each hello, which starts the Commander's stream.
  Future<void> Function()? beforeStream;

  /// How long (ms) Android's look for the Commander's network waits for the
  /// phone's scan results before it answers from the latest ones (the dash's
  /// slider; read at each look). 0 is no limit: it waits for the network to
  /// show up in them, however long, until a new try, [relook] or the phone's
  /// WiFi going off drops it. Bluetooth starts no link while it runs.
  int lookMs = 3000;

  /// Starts the try over now when WiFi is looking or waiting between tries,
  /// so a changed [lookMs] applies at once (a look with no limit would
  /// otherwise wait on). A joining, saying hello or live link is left alone:
  /// by [link], as a stream that came back from a stall is live while the
  /// state it last set still reads retrying.
  void relook() {
    if (_cfg == null) return;
    if (const {WifiLink.scanning, WifiLink.away, WifiLink.retrying}.contains(link)) {
      _attempt = 0;
      _attemptConnect();
    }
  }

  Future<void> _attemptConnect() async {
    final c = _cfg;
    if (c == null) return;
    final gen = ++_gen;
    _retry?.cancel();
    _starting = true; // before the first await; the next [_set] says it
    await _teardown();
    if (gen != _gen) return;
    // iOS lets no app join a network: the owner joins it in Settings.
    _set(WifiLink.scanning, Platform.isAndroid && lookMs == 0
        ? 'looking for ${c.ssid} until it shows up…'
        : 'looking for ${c.ssid}…${_attempt > 0 ? ' (try ${_attempt + 1})' //
        : Platform.isAndroid ? '' : ' join it in Settings › Wi-Fi'}');
    if (Platform.isAndroid && !await _wifiOn()) {
      if (gen != _gen) return;
      // Android 10+ will not let an app switch WiFi on; the system panel is
      // the nearest thing, shown once per connect so retries do not nag.
      if (_attempt == 0) _net.invokeMethod('openWifiPanel').catchError((_) {});
      _scheduleRetry('wifi is off — turn it on', WifiLink.wifiOff);
      return;
    }
    if (gen != _gen) return;
    // Asking Android for the network puts its "Searching for devices…"
    // dialog over the dash until the network shows up. So ask only once the
    // phone has seen it, or the owner asked. Not because Bluetooth reached
    // the Commander: with ScanMyTesla off it has no WiFi to show up.
    final awake = _awake;
    _awake = false;
    final near = !Platform.isAndroid || awake || await _wifiNearby(c.ssid);
    if (gen != _gen) return;
    if (!near) {
      // A car that is away is looked for every 10 s.
      // Android starts 4 of an app's scans in 2 minutes; past that the check
      // reads the phone's own latest results, which it renews about as
      // often while not connected. Just after a dropout, or the phone's
      // WiFi coming on, the quick steps stay: the network is likely back.
      bool lately(DateTime? t) => t != null && DateTime.now().difference(t) < const Duration(minutes: 1);
      final recent = lately(_lastFrame) || lately(_wifiOnAt);
      if (!recent) _attempt = max(_attempt, 3);
      _scheduleRetry(recent ? '${c.ssid} not back yet' : '${c.ssid} not in range — car asleep?', WifiLink.away);
      return;
    }
    _set(WifiLink.joining, 'joining ${c.ssid}…${Platform.isAndroid ? ' approve the wifi dialog if asked' : ''}');
    if (!await _bindWifi(c.ssid, c.password)) {
      if (gen != _gen) return;
      _scheduleRetry('no ${c.ssid} yet — is the Commander on?');
      return;
    }
    if (gen != _gen) return; // disconnected or restarted while binding
    // The hello starts the Commander's stream: whatever must not be on it
    // then (the dash's Bluetooth link) steps aside first.
    await beforeStream?.call();
    if (gen != _gen) return;
    try {
      final addr = (await InternetAddress.lookup(c.host)).first;
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      if (gen != _gen) {
        sock.close();
        return;
      }
      _addr = addr;
      _port = c.port;
      _sock = sock;
    } catch (e) {
      if (gen != _gen) return;
      _scheduleRetry('socket failed: $e');
      return;
    }
    _sock!.listen(_onEvent);
    _lastRecv = null;
    _connectedAt = DateTime.now();
    _set(WifiLink.hello, 'saying hello to ${c.host}:${c.port}…', _connectedAt!.add(const Duration(seconds: 8)));
    _hello();
    _subscribe();
    // The Commander drops the session if we go quiet, and gives us nothing
    // if it never heard us.
    _keepAlive = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _scheduleRetry(String why, [WifiLink l = WifiLink.retrying]) {
    if (_cfg == null) return;
    _keepAlive?.cancel(); // no more ticks until the next attempt
    _keepAlive = null;
    // The phone's WiFi off: Android says when it comes back on (see
    // [connect]), which starts the next attempt; nothing to wait out.
    if (l == WifiLink.wifiOff && Platform.isAndroid) {
      _attempt++; // the WiFi panel shows once per connect, not per look
      _set(l, why);
      return;
    }
    // Straight back after a dropout, then easing off to 10 s at most;
    // [kick] cuts any wait.
    const delays = [1, 3, 6, 10];
    final secs = delays[min(_attempt, delays.length - 1)];
    _attempt++;
    _set(l, '$why — retrying in ${secs}s', DateTime.now().add(Duration(seconds: secs)));
    _retry = Timer(Duration(seconds: secs), _attemptConnect);
  }

  /// Tries now instead of at the end of the backoff. Does nothing while
  /// live or mid-attempt (a pending WiFi request already connects the
  /// moment the network shows up), except a look with no limit: it only
  /// listens, so this is the moment to ask for a fresh scan.
  void kick() {
    if (_cfg == null) return;
    if (lookMs == 0 && _link == WifiLink.scanning) {
      _attemptConnect();
      return;
    }
    // A retry pending, or the phone's WiFi off, which has no retry: the
    // word that it came on (or the app coming back) starts the next look.
    if ((_retry?.isActive ?? false) || _link == WifiLink.wifiOff) _attemptConnect();
  }

  /// Stops everything and forgets the config; no more retries.
  Future<void> disconnect() async {
    _cfg = null;
    _gen++;
    _retry?.cancel();
    await _teardown();
    _set(WifiLink.idle, 'disconnected');
  }

  Future<void> _teardown() async {
    _keepAlive?.cancel();
    _keepAlive = null;
    _sock?.close();
    _sock = null;
    frames.clear();
    captureStart = DateTime.now();
    _forget();
    if (Platform.isAndroid) {
      await _net.invokeMethod('unbind').catchError((_) {});
    }
  }

  static const _g = 9.80665; // m/s² in one g

  /// A steadier reading: the bus's 40-50 samples a second, about a tenth of
  /// a second of them at a time.
  static double _smooth(double? was, double now) => was == null ? now : was + 0.3 * (now - was);

  /// Nothing the dash shows should outlive the link: no frozen indicator,
  /// brake or blind-spot glow, pill, warning or lit button.
  void _forget() {
    gear = '—';
    frameHz = speedHz = 0;
    braking = indL = indR = blindL = blindR = false;
    // With Bluetooth carrying the lamps on, the flasher keeps its beat: a
    // reset here would read their next push as a fresh flash.
    if (_bt == null) {
      _blinkOff?.cancel();
      blinkLit = _litL = false;
      _wasLit = 0;
      _edgeAt = null;
    }
    trunk = frunk = mirrorDipped = tiltAuto = chargePort = mapLight = false;
    hvacOn = recircOn = false;
    _tp219.clear();
    doorFL = doorFR = doorRL = doorRR = false;
    beltDriver = beltPass = belt2L = belt2C = belt2R = belt3L = belt3R = false;
    buckled.clear();
    recirc = domeLight = autopilot = null;
    lowBeam = highBeam = drl = null;
    _highFn = _highLamp = false;
    navRoute = false;
    navEnergyKwh = navMinutes = speedLimit = null;
    slippery = gripHeld = packHeating = charging = washerLow = false;
    co2ppm = null;
    cabinC1 = cabinC2 = cabinC3 = null;
    fan1 = fan2 = null;
    gLong = gLat = null;
    _slipUi = _slipMode = _tcFlash = _escFlash = _heatMotors = _heatPump = _heatNav = _cruiseOn = _climateOn = false;
    autoBlower = null;
    _gripAt = null;
    tcMode = chargeWhy = null;
    handsOn = followGap = chargeMinutes = null;
    cruiseSet = precondC = chargeKw = chargeMaxKw = regenMaxKw = null;
    // Shown only while live, but the Commander's ACK alone makes a new link
    // live before the first frame: never with the last session's figures.
    speed = 0;
    frontKw = rearKw = pedalPct = packKw = _packV = _frontAt = _rearAt = _other = null;
    lvKw = _compKw = _heatLKw = _heatRKw = _lvV = null;
  }

  void _send(List<int> bytes) {
    final a = _addr;
    if (a != null) _sock?.send(bytes, a, _port);
  }

  // Yes, "ehllo" — that is the literal handshake the panda interface expects.
  void _hello() => _send(const [0x65, 0x68, 0x6C, 0x6C, 0x6F]);

  /// Asks for only the ids the dash actually decodes. Fewer frames on the
  /// wire is less latency on the speed readout. Max 43 pairs per packet.
  void _subscribe() {
    if (_all) {
      _send(const [0x0c]); // Commander: stream every id on every bus
      return;
    }
    // Clear first (0x18): 0x0f only adds, so a "send all" left on (by
    // Diagnostics, or any other client) kept every id coming: 353 ids at
    // 2100 frames/s on 2026.38.6, a third of them dropped, the rest late.
    _send(const [0x18]);
    // The full list below holds them all; the schedule trims them again.
    _sparseOn.clear();
    for (final t in _sparseTimers.values) {
      t.cancel();
    }
    _sparseTimers.clear();
    var packet = <int>[0x0f];
    for (final id in kSubscribeIds) {
      if (packet.length > 1 + 3 * 42) {
        _send(packet);
        packet = <int>[0x0f];
      }
      packet.addAll([0xff, id >> 8, id & 0xff]); // 0xff = any bus
    }
    if (packet.length > 1) _send(packet);
  }

  /// Ids whose data changes slowly, polled in a short window every N seconds
  /// rather than streamed: seat belts and their buckles every 2 s, the frunk
  /// and charge port every 5 s, and those two only while parked (neither can
  /// change in gear, and their 64 frames/s were the biggest burst). Added with
  /// 0x0f, removed with 0x0e (the wiki's pair). The values keep their last
  /// reading between polls. A drive showed the cost of a burst: speed frames
  /// fell about a quarter of the burst's size in the second it came, so the
  /// window is 0.4 s, not a second.
  static const _sparse = <int, List<int>>{
    2: [0x3C2, 0x3A1, 0x31A], // belts and their buckles, battery heating
    5: [0x2E1, 0x25D], // frunk, charge port: parked only
  };
  static const _parkedOnly = {5};
  static const _pollWindow = Duration(milliseconds: 400);
  final _sparseOn = <int, bool>{}; // per period: its ids are subscribed now
  final _sparseTimers = <int, Timer>{};
  int _sparseT = 0;

  void _sparseTick() {
    if (_all) return;
    _sparseT++;
    for (final MapEntry(key: n, value: ids) in _sparse.entries) {
      final on = _sparseOn[n] ?? true;
      final due = _sparseT % n == 0 && (!_parkedOnly.contains(n) || _gear == 'P');
      if (due) {
        if (!on) {
          _sparseOn[n] = true;
          _sendIds(0x0f, ids);
        }
        // Off again after the window.
        _sparseTimers[n]?.cancel();
        _sparseTimers[n] = Timer(_pollWindow, () {
          if (_sparseOn[n] ?? true) {
            _sparseOn[n] = false;
            _sendIds(0x0e, ids);
          }
        });
      } else if (on && !(_sparseTimers[n]?.isActive ?? false)) {
        _sparseOn[n] = false; // after a full subscribe, or the car left P
        _sendIds(0x0e, ids);
      }
    }
  }

  void _sendIds(int op, List<int> ids) =>
      _send([op, for (final id in ids) ...[0xff, id >> 8, id & 0xff]]);

  void _tick() {
    // An awake car sends hundreds of frames a second, so a few silent
    // seconds already mean the link has stalled. Checked before the hello:
    // after the app was frozen the Commander has dropped the session, and a
    // hello now would start a new stream without the step aside (see
    // [beforeStream]); the retry goes through it.
    final since = DateTime.now().difference(_lastRecv ?? _connectedAt!);
    if (since.inSeconds >= 8) {
      _scheduleRetry(_lastRecv == null ? 'Commander not answering' : 'link lost');
      return;
    }
    _sparseTick();
    _hello();
    if (since.inSeconds >= 3 && _lastRecv != null) {
      _set(WifiLink.quiet, 'link quiet — resubscribing', _lastRecv!.add(const Duration(seconds: 8)));
      _subscribe();
    }
  }

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final dg = _sock?.receive();
    if (dg == null) return;
    // Frames back while a retry for a stalled link is pending: keep this
    // link (and its keep-alive) instead of tearing it down.
    if (_keepAlive == null && _cfg != null) {
      _retry?.cancel();
      _keepAlive = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
    _lastRecv = _lastFrame = DateTime.now();
    _attempt = 0;
    _onPacket(dg.data);
    _push();
  }

  /// A packet is a run of 16-byte records: two little-endian uint32 of header
  /// then up to 8 payload bytes.
  void _onPacket(Uint8List data) {
    if (data.length % 16 != 0) return;
    final bd = ByteData.sublistView(data);
    for (var o = 0; o + 16 <= data.length; o += 16) {
      final w0 = bd.getUint32(o, Endian.little);
      final w1 = bd.getUint32(o + 4, Endian.little);
      final id = w0 >> 21;
      final len = w1 & 0x0F;
      final bus = w1 >> 4;
      if (id == 0) continue;
      if (bus == 15 && id == 6) {
        _subscribe(); // Commander ACK — it wants the id list again
        continue;
      }
      if (len < 1 || len > 8) continue;
      // An id nobody asked for: the Commander is sending everything (see
      // [_floodCheck]). Counted and dropped here, before the copy and the
      // signal scan that cost the UI thread most at 2000 frames a second.
      if (!_all && !_wanted.contains(id)) {
        _frameCount++;
        _foreign++;
        continue;
      }
      _onFrame(id, bus, data.sublist(o + 8, o + 8 + len));
    }
  }

  @visibleForTesting
  void onPacket(Uint8List data) => _onPacket(data);

  @visibleForTesting
  void onFrame(int id, int bus, List<int> data) => _onFrame(id, bus, data);

  static final _wanted = kSubscribeIds.toSet();
  static final _byId = () {
    final m = <int, List<MapEntry<String, Sig>>>{};
    for (final e in kSignals.entries) {
      (m[e.value.id] ??= []).add(e); // keeps kSignals' order, which matters
    }
    return m;
  }();

  void _onFrame(int id, int bus, List<int> data) {
    _frameCount++;
    if (id == 0x257) _speedFrames++;
    final f = frames.putIfAbsent(id, () => Frame(bus));
    f.count++;
    f.lastBus = bus;
    f.data = data;
    f.remember(data);

    for (final e in _byId[id] ?? const <MapEntry<String, Sig>>[]) {
      final v = decode(e.value, data);
      if (v == null) continue;
      switch (e.key) {
        case 'speed':
          speed = v;
        case 'speedIsKph':
          kph = v == 1;
        case 'pedal':
          pedalPct = v.clamp(0, 100);
        case 'brake':
          // Foot on the pedal while the car can move. 'gear' comes before
          // 'brake' in kSignals, so an auto-park's P clears it in the frame
          // that brings it. ponytail: no age-out; add one in _tick should
          // 0x118 ever stop while in R/N/D.
          braking = v == 1 && const {'R', 'N', 'D'}.contains(_gear);
        case 'gear':
          final g = kGears[v.round()] ?? '—';
          if (gear == 'P' && g != 'P') gMaxAccel = gMaxBrake = gMaxLat = 0; // a new drive
          gear = g;
        case 'accel':
          gLong = _smooth(gLong, v / _g);
          if (gLong! > gMaxAccel) gMaxAccel = gLong!;
          if (-gLong! > gMaxBrake) gMaxBrake = -gLong!;
        case 'yaw':
          // Turning at speed: yaw rate (rad/s) times speed (m/s).
          final ms = kph ? speed / 3.6 : speed * 0.44704;
          gLat = _smooth(gLat, v * ms / _g);
          if (gLat!.abs() > gMaxLat) gMaxLat = gLat!.abs();
        case 'recirc':
          recirc = kRecirc[v.round()];
        case 'autopilot':
          autopilot = kAutopilot[v.round()];
        case 'indL':
          indL = v != 0;
          _litL = v == 2;
        case 'indR':
          indR = v != 0;
          // After 'indL' in kSignals: this frame's lamps.
          _flasher((_litL ? 1 : 0) | (v == 2 ? 2 : 0));
        case 'blindL':
          blindL = v == 1 || v == 2;
        case 'blindR':
          blindR = v == 1 || v == 2;
        case 'sideWarn':
          // After blindL/blindR in kSignals: adds to this frame's glow.
          final w = v.round();
          blindL = blindL || w == 1 || w == 3;
          blindR = blindR || w == 2 || w == 3;
        // Only VCSEC's 7-byte frame (the chassis bus has an unrelated 3-byte
        // 0x219, as the other length guards assume no padding) and only real
        // readings are written (0 is none, 254 over range), so an
        // empty page 5 cannot blank what 0x25A wrote. Per wheel, page 5 wins
        // once it has one: two sources would flicker by a count. Last known
        // stays.
        case 'tpFL' when data.length == 7 && v > 0 && v <= 6.3:
          tpFL = v;
          _tp219.add('FL');
        case 'tpFR' when data.length == 7 && v > 0 && v <= 6.3:
          tpFR = v;
          _tp219.add('FR');
        case 'tpRL' when data.length == 7 && v > 0 && v <= 6.3:
          tpRL = v;
          _tp219.add('RL');
        case 'tpRR' when data.length == 7 && v > 0 && v <= 6.3:
          tpRR = v;
          _tp219.add('RR');
        case 'tdFL' when !_tp219.contains('FL') && v > 0 && v <= 6.3:
          tpFL = v;
        case 'tdFR' when !_tp219.contains('FR') && v > 0 && v <= 6.3:
          tpFR = v;
        case 'tdRL' when !_tp219.contains('RL') && v > 0 && v <= 6.3:
          tpRL = v;
        case 'tdRR' when !_tp219.contains('RR') && v > 0 && v <= 6.3:
          tpRR = v;
        case 'navEnergyKwh':
          navEnergyKwh = v.abs() > 300 ? null : v; // raw -32768 SNA, -32767 trip too long
        case 'navRoute':
          navRoute = v == 1;
        case 'navMinutes':
          navMinutes = v >= 1023 ? null : v; // all ones: none
        case 'doorFL':
          doorFL = kLatchOpen.contains(v.round());
        case 'doorFR':
          doorFR = kLatchOpen.contains(v.round());
        case 'doorRL':
          doorRL = kLatchOpen.contains(v.round());
        case 'doorRR':
          doorRR = kLatchOpen.contains(v.round());
        case 'trunk':
          trunk = kLatchOpen.contains(v.round());
        case 'frunk':
          frunk = kLatchOpen.contains(v.round());
        case 'mirrorDipped':
          mirrorDipped = v == 1;
        case 'tiltAuto':
          tiltAuto = v == 1;
        case 'chargePort':
          if (data.length == 8) chargePort = v == 1;
        case 'mapLights':
          if (data.length == 7) {
            final i = v.round();
            mapLight = [0, 2, 4, 6].any((s) => (i >> s) & 3 == 1);
          }
        case 'hvacPower':
          hvacOn = v != 0;
        case 'recircPct':
          // ponytail: a fixed 60/40 band, so AUTO hovering near half does
          // not flicker the chip; tune it from a Diagnostics log.
          recircOn = v >= 60 || (recircOn && v > 40);
        case 'beltDriver':
          beltDriver = v == 1;
        case 'beltPass':
          beltPass = v == 1;
        case 'belt2L':
          belt2L = v == 1;
        case 'belt2C':
          belt2C = v == 1;
        case 'belt2R':
          belt2R = v == 1;
        case 'belt3L':
          belt3L = v == 1;
        case 'belt3R':
          belt3R = v == 1;
        case final k when k.startsWith('buckle'):
          // VCLEFT's switches read 2 ON, VCRIGHT's buckles 1 LATCHED.
          final seat = k.substring(6);
          if (v == (id == 0x3C2 ? 2 : 1)) {
            buckled.add(seat);
          } else {
            buckled.remove(seat);
          }
        case 'lowBeam':
          lowBeam = v == 15 ? null : v == 4; // LOW_BEAMS; 15 SNA -> unknown
        case 'highBeam':
          _highFn = v != 0; // flash or latched, every 100 ms
          highBeam = _highFn || _highLamp;
        case 'highLamp':
          final i = v.round();
          _highLamp = (i & 3) == 1 || i >> 2 == 1; // left or right lamp ON
          highBeam = _highFn || _highLamp;
        case 'drl':
          // The front light bar: DRL by day, the position lamp with
          // headlights or parking lights (CUSTOM light shows excluded).
          drl = v == 15 ? null : v >= 1 && v <= 4;
        case 'frontKw':
          _frontAt = v;
          _motorFrame();
          _blend();
        case 'rearKw':
          _rearAt = v;
          _motorFrame();
          _blend();
        case 'compW':
          _compKw = v / 1000;
        case 'heatL':
          _heatLKw = v / 1000;
        case 'heatR':
          _heatRKw = v / 1000;
        case 'lvV':
          _lvV = v;
        case 'lvA':
          final volts = _lvV;
          if (volts != null) lvKw = volts * v / 1000;
        case 'packV':
          _packV = v;
        case 'packA':
          final volts = _packV;
          if (volts != null) {
            packKw = -volts * v / 1000;
            _blend();
          }
        case 'soc':
          socPct = v.clamp(0, 100);
        case 'rangeMi':
          rangeMi = v;
        case 'cellVMax':
          cellVMax = v > 5 ? null : v; // all-ones = SNA
        case 'cellVMin':
          cellVMin = v > 5 ? null : v;
        case 'packKwh':
          packKwh = v < 30 || v > 150 ? null : v; // SNA, or not this layout
        case 'packLeftKwh':
          packLeftKwh = v > 150 ? null : v;
        case 'packBufferKwh':
          packBufferKwh = v > 20 ? null : v;
        case 'packNewKwh':
          // Same bus as BMS_energyStatus, which no other bus reuses: 0x392
          // also names EPAS alerts on the party bus (see signals.dart).
          if (v >= 40 && v <= 110 && bus == frames[0x352]?.bus) packNewKwh = v;
        case 'domeLight':
          domeLight = kDome[v.round()];
        case 'speedLimit':
          speedLimit = v >= 155 ? null : v; // raw 31 = NONE
        case 'outside':
          outsideC = v;
        case 'washer':
          washerLow = v == 1;
        case 'slippery':
          _slipUi = v == 1;
          slippery = _slipUi || _slipMode;
        case 'tcMode':
          final m = v.round();
          tcMode = const {1: 'SLIP', 6: 'OFF-RD'}[m];
          _slipMode = m == 7;
          slippery = _slipUi || _slipMode;
        case 'tcFlash':
          _tcFlash = v == 1;
        case 'escFlash':
          // After 'tcFlash' in kSignals. Held 3 s past the last flash, so a
          // glance still catches a short slip.
          final now = DateTime.now();
          _escFlash = v == 1;
          if (_tcFlash || _escFlash) _gripAt = now;
          gripHeld = _gripAt != null && now.difference(_gripAt!) < const Duration(seconds: 3);
        case 'regenMax':
          regenMaxKw = v;
        case 'packTMin':
          packTempC = v;
        case 'motorHeat':
          _heatMotors = v == 2; // DI_POWERED_ON_FOR_STATIONARY_HEAT
          packHeating = _heatMotors || _heatPump || _heatNav;
        case 'pumpHeat':
          _heatPump = v > 0;
          packHeating = _heatMotors || _heatPump || _heatNav;
        case 'precondState':
          _heatNav = v == 1; // ACTIVE_HEAT
          packHeating = _heatMotors || _heatPump || _heatNav;
          if (!_heatNav) precondC = null;
        case 'precondTarget':
          if (_heatNav) precondC = v; // after 'precondState' in kSignals
        case 'co2':
          co2ppm = v >= 5115 ? null : v.round(); // raw 1023: SNA, no tint stuck
        case 'cabin1':
          cabinC1 = v;
        case 'cabin2':
          cabinC2 = v;
        case 'cabin3':
          cabinC3 = v;
        case 'climateOn':
          _climateOn = v != 0;
        case 'autoBlower':
          autoBlower = v.round();
        case 'fan1':
          // After 'climateOn' and 'autoBlower' in kSignals: off while the
          // climate is; on Auto, Auto's level.
          final f = v.round();
          fan1 = !_climateOn || f == 0
              ? 'OFF'
              : f == 11
                  ? kAutoBlower[autoBlower] ?? 'AUTO'
                  : f <= 10 ? '$f' : null;
        case 'fan2':
          // On Auto too, Auto's level: the one setting both rows follow.
          final f = v.round();
          fan2 = !_climateOn ? 'OFF' : f == 0 ? kAutoBlower[autoBlower] ?? 'AUTO' : kFan2[f];
        case 'handsOn':
          handsOn = v == 15 ? null : v.round(); // SNA must not hold a nag
        case 'cruiseState':
          _cruiseOn = const {2, 3, 4}.contains(v.round());
        case 'cruiseSet':
          _cruiseRaw = v;
        case 'cruiseKph':
          // After the state and the speed in kSignals: this frame's figure,
          // in the display's unit.
          final kmh = v == 1;
          cruiseSet = !_cruiseOn
              ? null
              : kmh == kph
                  ? _cruiseRaw
                  : kmh
                      ? _cruiseRaw / 1.609344
                      : _cruiseRaw * 1.609344;
        case 'followGap':
          followGap = v.round() + 1;
        case 'chargeStatus':
          charging = v == 3;
        case 'chargeKw':
          chargeKw = v;
        case 'chargeMaxKw':
          chargeMaxKw = v;
        case 'chargeWhy':
          chargeWhy = kChargeWhy[v.round()];
        case 'chargeLimit':
          chargeLimitPct = v.round();
        case 'chargeMinutes':
          chargeMinutes = v >= 2047 ? null : v.round();
      }
    }
  }

  // ~30 Hz repaint. Notifying per frame would just drop frames elsewhere.
  /// The shortest gap between two redraws, ms: 22 is about 45 a second (was
  /// 33, 30 a second). A replayed drive cost ~3% of a core more at 60.
  static const pushMs = 22;

  void _push() {
    final now = DateTime.now();
    if (now.difference(_lastHz).inSeconds >= 1) {
      frameHz = _frameCount;
      speedHz = _speedFrames;
      foreignHz = _foreign;
      _floodCheck(now);
      _frameCount = _speedFrames = _foreign = 0;
      _lastHz = now;
    }
    if (now.difference(_lastPush).inMilliseconds < pushMs) return;
    _lastPush = now;
    status = 'live';
    until = null;
    notifyListeners();
  }

  /// Puts the link in a state, for tests and screenshots.
  @visibleForTesting
  void show(WifiLink l, String s, [DateTime? t]) => _set(l, s, t);

  void _set(WifiLink l, String s, [DateTime? t]) {
    _starting = false;
    _link = l;
    until = t;
    status = s;
    // WiFi gone: the Commander's Bluetooth values take over now.
    if (_bt case final d?) _applyBt(d);
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}

class Frame {
  Frame(this.bus) : lastBus = bus;
  final int bus;
  int lastBus; // the bus of the latest one: a second bus reusing the id shows here
  int count = 0;
  List<int> data = const [];

  /// The last few distinct payloads, newest last, for the Diagnostics log:
  /// a multiplexed frame's pages, or a value changing.
  final recent = <List<int>>[];

  void remember(List<int> d) {
    recent.removeWhere((r) => listEquals(r, d));
    recent.add(d);
    if (recent.length > 8) recent.removeAt(0);
  }

  String get hex => hexOf(data);
}

String hexOf(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
