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
/// Fields are mutated in place and listeners notified at a capped rate (see
/// [Panda.pushMs]): CAN arrives far faster than the screen can draw.
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
  bool _compOk = false;
  double? get climateKw => _compKw == null && _heatLKw == null && _heatRKw == null
      ? null
      : (_compKw ?? 0) + (_heatLKw ?? 0) + (_heatRKw ?? 0);
  /// The rest of what the pack feeds (battery heating, pumps...), averaged
  /// slowly over the motor frames.
  double? get otherKw => _other;
  double? _packV, _frontAt, _rearAt, _other;

  /// The motor frames come about once a second, the pack's about 90 times.
  /// So the motors shown are the pack now less what else it feeds (measured
  /// climate and 12 V, and the averaged rest), shared front and rear as in
  /// the last motor frame. A motor frame only resets that share and nudges
  /// the rest: putting its value up would make the readout step once a second.
  void _motorFrame() {
    final p = packKw;
    if (p == null || _rearAt == null || _frontAt == null) return; // a whole reading
    final rest = (p - (_frontAt ?? 0) - (_rearAt ?? 0) - (climateKw ?? 0) - (lvKw ?? 0)).clamp(0, 5).toDouble();
    final o = _other;
    _other = o == null ? rest : o + (rest - o) * 0.05; // about 20 frames' worth
  }

  bool get _stopped => speed == 0 && (pedalPct ?? 0) == 0;

  /// The exact motor values in P, at a standstill (the climate's held
  /// reading would otherwise show its changes as drive or regen), or before
  /// the pack has been heard.
  bool get _exact => packKw == null || _other == null || _gear == 'P' || _stopped;

  void _blend() {
    final p = packKw, other = _other, f = _frontAt, r = _rearAt;
    if (_exact || p == null || other == null || r == null) {
      // Stopped there is no regen: the frame can be a second old, from the
      // last of the braking.
      frontKw = _stopped && f != null ? max(0.0, f) : f;
      rearKw = _stopped && r != null ? max(0.0, r) : r;
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

  /// Subscribed too, for the trace alone: the pack's and the 12 V side's volts
  /// and amps, to see whether they could stand in for motor power over
  /// Bluetooth. Nothing reads them, so they say nothing of [viaBt].
  static const btTraceFields = [28, 29, 77, 78];

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
    // 1 is ON; 2 INVALID (all that 0x118's old brake bits read since 2026.38,
    // which the Commander may still pass on) is not braking.
    if (at(65) case final v?) braking = v == 1 && const {'R', 'N', 'D'}.contains(_gear);
    // TurnSignalStatus: 1 signalling with the lamp dark, 2 lamp lit.
    final l = at(63) ?? 0, r = at(64) ?? 0;
    indL = l != 0;
    indR = r != 0;
    _flasher((l == 2 ? 1 : 0) | (r == 2 ? 2 : 0));
    if (at(106) case final v?) blindL = v == 1 || v == 2;
    if (at(107) case final v?) blindR = v == 1 || v == 2;
    _btMotors(kw(51), kw(53));
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
    return 'wifi "$status" ${frameHz}Hz speed ${speedHz}Hz gap ${speedGapMs}ms foreign ${foreignHz}Hz resubs $resubscribes subs $subscribes acks $acks sparse ${_sparseWanted ? '' : 'off '}$sparseOps/$sparseFixes live=$wifiLive viaBt=$viaBt gear=$gear speed=$speed '
        'front=$frontKw rear=$rearKw pack=${packKw?.toStringAsFixed(1)} climate=${climateKw?.toStringAsFixed(2)} 12v=${lvKw?.toStringAsFixed(2)} other=${otherKw?.toStringAsFixed(2)} regenMax=$regenMaxKw | ${raw(0x2E5)} | ${raw(0x266)} | ${raw(0x252)} | '
        'bt ${b == null ? '-' : (b.keys.where((k) => b[k] is num).toList()..sort()).map((k) => '$k=${b[k]}').join(' ')} | '
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

  DateTime? _btMotorBadAt;

  /// The Commander's own motor power (fields 51, 53) is its decode of 0x2E5
  /// and 0x266, which 2026.38 repacked (power 0|11 -> 41|11). Until its
  /// firmware follows, a parked car reads -382.5 kW front and a jumping rear
  /// (the same garbage WiFi showed before the dash moved to bit 41). Values
  /// past what the motors can do (the car's own limits: 208 kW front, 392
  /// rear) mark the readout bad for 30 s: no number rather than a wrong one.
  /// Regen stops at the pack's limit (92 kW seen) with room to spare; the
  /// garbage seen sits well past it. Right values pass. Parked, a reading of
  /// real output is dropped but not
  /// held against it: pushes come on a change, so the last one can be the
  /// drive's.
  void _btMotors(double? f, double? r) {
    if (f == null && r == null) return;
    bool off(double? v, double max) => v != null && (v < -200 || v > max);
    bool moving(double? v) => v != null && v.abs() > 3;
    final now = DateTime.now();
    if (off(f, 210) || off(r, 400)) _btMotorBadAt = now;
    final at = _btMotorBadAt;
    if ((at != null && now.difference(at) < const Duration(seconds: 30)) ||
        (_gear == 'P' && (moving(f) || moving(r)))) {
      frontKw = rearKw = null;
      return;
    }
    if (f != null) frontKw = f;
    if (r != null) rearKw = r;
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

  /// A full second of this stream has been counted: until then [speedHz]
  /// says nothing, and its 0 is no alarm. After, a 0 is a real stall.
  bool speedKnown = false;

  /// The longest wait between two speed frames in the last second, ms: a
  /// healthy rate can still hide a stall, and it is the stall that reads as
  /// lag. Frames in one packet count as one arrival.
  int speedGapMs = 0;
  int _speedGap = 0;
  DateTime? _speedAt;

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
  bool get captureAll => _all;
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
    _streaming = false;
    _ackSubAt = DateTime.fromMillisecondsSinceEpoch(0); // the last socket's
    _beatAt = DateTime.now();
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
    frameHz = speedHz = speedGapMs = _speedGap = 0;
    speedKnown = false;
    _speedAt = null; // an outage is no gap in the stream
    braking = indL = indR = blindL = blindR = false;
    // With Bluetooth carrying the lamps on, the flasher keeps its beat: a
    // reset here would read their next push as a fresh flash.
    if (_bt == null) {
      _btMotorBadAt = null; // else a WiFi retry would lift it every few seconds
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
    _compOk = false;
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
    subscribes++;
    _send(const [0x18]);
    // The full list below holds them all; the schedule trims them again.
    _sparseOn.clear();
    _sparseStray.clear();
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

  /// How the ids the dash subscribes to are polled. Every one is in exactly
  /// one place (a test holds this): [alwaysOn], or a group of [_sparse].
  ///
  /// The Commander can only filter by id, so thinning means switching an id
  /// on for a moment now and then (0x0f adds, 0x0e removes: the wiki's pair);
  /// the values keep their last reading between. A burst costs speed frames
  /// in the second it arrives (a drive: about a quarter of its size), so
  /// [_wheel] turns one group at a time through half-second slots: the load
  /// stays small and even rather than spiking. An id must send at least once
  /// a slot to be caught, so under about 3 frames a second it stays on. Every
  /// group is on after a subscribe, until the next slot, so a new stream
  /// reads everything once ([_wheelOn]). Rates are from a drive's report.
  ///
  /// On the stream, every frame: what moves what the driver sees (speed,
  /// pedal and gear, yaw, the pack's power for the ring), the lamps, the
  /// grip and cruise state, driver-assist warnings; the ids the car itself
  /// sends slowly (energy, nav route and energy, tyre pressures, cells,
  /// outside, follow gap, charging limit, time and reason, motor power, soc
  /// and range, climate switches, mirror tilt); and nav time, as only one
  /// page of its frame holds it and nothing else gives it on this car. Two are never on this car's stream (tyre
  /// pressure 0x219, recirculation 0x243): the Commander stands in for them.
  static const alwaysOn = <int>{
    0x257, 0x118, 0x101, 0x132, // speed, gear/pedal/brake, yaw, pack V and A
    0x3F5, 0x2B6, 0x286, 0x399, 0x3F6, 0x3F8, // lamps, grip, cruise, assist
    0x2E5, 0x266, 0x33A, 0x332, 0x352, 0x392, // motor power, soc, cells, energy
    0x347, 0x238, 0x3FD, 0x321, 0x2F3, 0x25A, 0x273, // nav, outside, climate, tyres, tilt
    0x472, 0x333, 0x33B, // charging: reason, limit, time
    0x219, 0x243, // not on this car's stream
  };

  /// Polled, in frames a second as streamed. Their slots are in [_wheel].
  static const _sparse = <({bool parked, List<int> ids})>[
    (parked: false, ids: [0x3A1]), // belts' chime, battery heating: 17
    (parked: false, ids: [0x3C2, 0x31A]), // buckles: 22
    (parked: false, ids: [0x102, 0x103, 0x3E2]), // doors, trunk, map lights: 22
    (parked: false, ids: [0x252, 0x2A7, 0x2B4]), // regen limit, draws: 26
    (parked: false, ids: [0x2B3]), // cabin temperatures, CO2, heater: 14
    // In any gear, or a charge ended just before driving off would read as
    // charging all the way; and on throughout a charge, for its live power.
    (parked: false, ids: [0x25D, 0x212]), // charge port, charging: 16
    // In P alone, as a burst this size costs the most, plus one slot on the
    // way out of P to leave with its last state. A frunk that opens on the
    // move does not show until P: the car's own screen says so.
    (parked: true, ids: [0x2E1]), // frunk: 53
  ];
  static const _chargeGroup = 5;
  static const _chipGroups = {2, 5, 6}; // what the buttons light from

  /// The groups on in each half-second slot, an 8 s round: seat belts, doors
  /// and lights every 2 s, the slow readouts every 4 s, charging and the frunk
  /// every 8 s. The cabin's frame turns through 17 pages in about a
  /// second, so it gets a full second every 8 s: a short window at a steady
  /// spacing would stay on the same pages, and in a simulation never saw
  /// CO2's. Its second slot shares with the lightest group.
  static const _wheel = <List<int>>[
    [0], [1], [2], [3],
    [0], [1], [2], [4],
    [0, 4], [1], [2], [3],
    [0], [1], [2], [5, 6],
  ];
  final _sparseOn = <int, bool>{}; // per group: its ids are subscribed now
  final _sparseOffAt = <int, DateTime>{}; // when each group's remove went out
  final _sparseStray = <int, int>{}; // frames of a group that should be off
  static final _sparseOf = {
    for (var i = 0; i < _sparse.length; i++)
      for (final id in _sparse[i].ids) id: i,
  };
  int _slot = 0;
  bool _wasParked = false;
  bool _streaming = false; // CAN frames have come on this socket
  DateTime _streamAt = DateTime.fromMillisecondsSinceEpoch(0); // the first of them

  /// The wheel turns while the stream runs. Not in a stall: everything stays
  /// on for the stream's return, to read what went blank meanwhile. Nor in
  /// its first 2 s, which read everything once: else a tick just after the
  /// first frame trims what has not come yet, and a car on charge shows no
  /// charge for up to a round.
  bool get _wheelOn {
    final now = DateTime.now();
    return _streaming && now.difference(_canAt).inSeconds < 3 && now.difference(_streamAt).inSeconds >= 2;
  }

  /// The last frame of the stream proper. Not an ACK, nor a polled id: the
  /// wheel keeps those coming from a filter that has lost everything else,
  /// which would pass for a live link with speed and gear frozen.
  DateTime _canAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _ackSubAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The last keep-alive tick. A long gap means the app was frozen: the
  /// Commander has dropped the session and what waits in the socket is old.
  DateTime _beatAt = DateTime.now();
  DateTime _hotUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// A button was pressed: its chip should answer in a moment, not at the
  /// group's next slot. A press seen as doing nothing gets pressed twice.
  void pressed() => _hotUntil = DateTime.now().add(const Duration(seconds: 3));

  /// For the trace: full subscribes sent, the Commander's own ACK frames
  /// (they trigger one), sparse add/remove commands, and removes sent again
  /// because a trimmed id kept arriving. A drive where the trimming did not
  /// hold (a run at full rate for 20 minutes) did not say which of these it was.
  int subscribes = 0, acks = 0, sparseOps = 0, sparseFixes = 0;

  static Set<int> get polledIds => {for (final g in _sparse) ...g.ids};

  /// Polling on (the dialog's switch). Off, every id streams all the time:
  /// live doors and belts, and about 540 frames a second instead of 370. Takes
  /// effect at the next tick.
  bool get sparse => _sparseWanted;
  set sparse(bool v) {
    if (v == _sparseWanted) return;
    _sparseWanted = v;
    if (!v) _sparseAll = true;
  }

  bool _sparseWanted = true, _sparseAll = false;

  @visibleForTesting
  void sparseTick() => _sparseTick();

  @visibleForTesting
  bool groupOn(int group) => _sparseOn[group] ?? true;

  /// Slots of the round a group is on in.
  @visibleForTesting
  int onSlots(int group) => _wheel.where((s) => s.contains(group)).length;

  @visibleForTesting
  int get maxGroupsInASlot => _wheel.map((s) => s.length).reduce(max);

  /// The next slot: each group on or off as the wheel says, whatever it was.
  void _sparseTick() {
    if (_all) return;
    if (!_sparseWanted) {
      // Everything on, and said again each round: this is UDP, and with the
      // wheel stopped a lost add would leave a group dark for the drive.
      if (_sparseAll || _slot++ % _wheel.length == 0) {
        _sparseAll = false;
        _sparseOn.clear();
        sparseOps++;
        _sendIds(0x0f, polledIds.toList());
      }
      return;
    }
    final slot = _wheel[_slot++ % _wheel.length];
    final parked = _gear == 'P', left = _wasParked && !parked;
    final hot = DateTime.now().isBefore(_hotUntil);
    _wasParked = parked;
    for (var i = 0; i < _sparse.length; i++) {
      final g = _sparse[i], due = slot.contains(i);
      final want = (hot && _chipGroups.contains(i) && (!g.parked || parked)) ||
          (g.parked ? (due && parked) || left : due || (i == _chargeGroup && charging));
      // A group that should be off, whose frames still come: the remove was
      // lost or ignored, so send it again.
      if (!want && (_sparseStray[i] ?? 0) >= 3) {
        sparseFixes++;
        _sparseOffAt[i] = DateTime.now();
        _sendIds(0x0e, g.ids);
      }
      _sparseStray[i] = 0;
      if (want == (_sparseOn[i] ?? true)) continue;
      _sparseOn[i] = want;
      if (!want) _sparseOffAt[i] = DateTime.now();
      sparseOps++;
      _sendIds(want ? 0x0f : 0x0e, g.ids);
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
    final frozen = DateTime.now().difference(_beatAt).inSeconds >= 8;
    _beatAt = DateTime.now();
    if (frozen) {
      _attemptConnect(); // through the step aside, as a new stream must
      return;
    }
    final base = _streaming ? _canAt : _connectedAt!;
    final since = DateTime.now().difference(base);
    if (since.inSeconds >= 8) {
      _scheduleRetry(_lastRecv == null ? 'Commander not answering' : 'link lost');
      return;
    }
    if (_wheelOn) {
      _sparseTick();
      // A slot is half a second. Looked at again: the link may be gone by then.
      Timer(const Duration(milliseconds: 500), () {
        if (_wheelOn) _sparseTick();
      });
    }
    _hello();
    if (since.inSeconds >= 3 && _lastRecv != null) {
      _set(WifiLink.quiet, 'link quiet — resubscribing', base.add(const Duration(seconds: 8)));
      _subscribe();
    }
  }

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final dg = _sock?.receive();
    if (dg == null) return;
    if (_keepAlive != null && DateTime.now().difference(_beatAt).inSeconds >= 8) {
      _beatAt = DateTime.now();
      _attemptConnect(); // frozen: see [_tick]
      return;
    }
    _lastRecv = _lastFrame = DateTime.now();
    final was = _canAt;
    _onPacket(dg.data);
    // The stream eases the backoff, not an ACK: a sleeping car's Commander
    // answers hellos, and each retry takes Bluetooth off it.
    if (_canAt != was) _attempt = 0;
    // The stream back while a retry for a stalled link is pending: keep this
    // link (and its keep-alive) instead of tearing it down. The stream, not
    // any packet: an ACK or a polled id would cancel the retry for nothing.
    if (_canAt != was && _keepAlive == null && _cfg != null) {
      _retry?.cancel();
      _beatAt = DateTime.now();
      _keepAlive = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
    // An ACK alone answers a hello; after that only the stream says live.
    if (_canAt != was || _link == WifiLink.hello) _push();
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
        acks++;
        // The Commander's ACK: it wants the id list. Not while frames flow:
        // the list sent again would undo the polling. But an ACK refreshes
        // the link's clock, so a stream gone silent behind ACKs would never
        // read as quiet in [_tick]: they are what brings it back.
        // At most every 2 s: a Commander that ACKs commands would otherwise
        // answer each subscribe with another.
        final now = DateTime.now();
        if ((!_streaming || now.difference(_canAt).inSeconds >= 2) &&
            now.difference(_ackSubAt).inSeconds >= 2) {
          _ackSubAt = now;
          _subscribe();
        }
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
    if (!_streaming || !_sparseOf.containsKey(id)) _canAt = DateTime.now();
    if (!_streaming) {
      // A stream's first frame: its first second counts from here.
      _streaming = true;
      _streamAt = _canAt;
      _startCount(_canAt);
    }
    _frameCount++;
    if (_sparseOf[id] case final n?) {
      final off = _sparseOffAt[n];
      if (_sparseOn[n] == false && off != null && DateTime.now().difference(off).inMilliseconds > 300) {
        _sparseStray[n] = (_sparseStray[n] ?? 0) + 1;
      }
    }
    if (id == 0x257) {
      _speedFrames++;
      final now = DateTime.now(), at = _speedAt;
      if (at != null) _speedGap = max(_speedGap, now.difference(at).inMilliseconds);
      _speedAt = now;
    }
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
          // The car's regen-brake lamp (see kSignals) while it can move.
          // 'gear' comes before 'brake', so an auto-park's P clears it in the frame
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
        case 'compV':
          _compOk = v >= 200 && v <= 600 && (v - (_packV ?? v)).abs() < 40;
        case 'compW':
          // A shorter frame has no voltage, so no say in _compOk: the last
          // frame's would pass the chassis bus's curvature off as power.
          if (_compOk && data.length >= 7) _compKw = v / 1000;
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

  // Notifying per frame would just drop frames elsewhere.
  /// The shortest gap between two redraws of what moves, ms: 22 is about 45
  /// a second (was 33, 30 a second). A replayed drive cost ~3% of a core more
  /// at 60. Parked nothing moves, so [pageMs] there too.
  static const pushMs = 22;

  /// The shortest gap between two redraws of the whole dash while frames
  /// come: the cards change every few seconds at most. Any other change
  /// (a link's state, a lamp's flash) notifies at once.
  static const pageMs = 200;

  /// Ticks at the redraw rate, for what moves with the car: speed, the ring,
  /// the pedal line, the g-ball, the edge glows. The rest listen to the Panda
  /// itself, as they change every few seconds at most: in a replay on the
  /// emulator this took about a quarter off the main thread (6.3% to 4.8%),
  /// and slowing the fast tick in P about a third off the whole app.
  Listenable get fast => _fast;
  final _fast = _Tick();
  DateTime _lastPage = DateTime.fromMillisecondsSinceEpoch(0);
  String? _shownGear;

  @visibleForTesting
  void fastTick() => _fast.fire();

  @visibleForTesting
  void push() => _push();

  void _startCount(DateTime now) {
    _lastHz = now;
    _frameCount = _speedFrames = _foreign = 0;
    speedKnown = false;
  }

  void _push() {
    final now = DateTime.now();
    if (status != 'live') _startCount(now); // back from a stall: likewise
    if (now.difference(_lastHz).inSeconds >= 1) {
      frameHz = _frameCount;
      speedHz = _speedFrames;
      speedKnown = true;
      speedGapMs = _speedGap;
      _speedGap = 0;
      foreignHz = _foreign;
      _floodCheck(now);
      _frameCount = _speedFrames = _foreign = 0;
      _lastHz = now;
    }
    // A new gear shows at once, whatever the rate: into P as out of it.
    final shifted = _gear != _shownGear;
    if (!shifted && now.difference(_lastPush).inMilliseconds < (_gear == 'P' ? pageMs : pushMs)) return;
    _lastPush = now;
    _shownGear = _gear;
    final back = shifted || status != 'live'; // the links act on this at once
    status = 'live';
    until = null;
    _fast.fire();
    if (back || now.difference(_lastPage).inMilliseconds >= pageMs) {
      _lastPage = now;
      notifyListeners();
    }
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
    _fast.dispose();
    super.dispose();
  }
}

/// A plain tick to listen to.
class _Tick extends ChangeNotifier {
  void fire() => notifyListeners();
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
