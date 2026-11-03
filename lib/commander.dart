import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'panda.dart' show Panda;

/// S3XY functions the dash can press: the action's number (niklaswa's
/// TeslaAction) and the state TryAction sends with it.
enum S3xyAction {
  frunk(2, 0, 'Frunk'),
  trunk(3, 0, 'Trunk'),
  interiorLights(12, 0, 'Light'),
  // Overrides the car's auto-tilt for the moment; acts in Reverse only.
  mirrorTilt(17, 0, 'Mirror tilt'),
  recircOn(48, 2, 'Recirculation'),
  recircOff(48, 3, 'Fresh air'),
  recircToggle(48, 4, 'Recirculation'),
  doorFrontLeft(40, 1, 'Front left door'),
  doorFrontRight(40, 2, 'Front right door'),
  doorRearLeft(40, 3, 'Rear left door'),
  doorRearRight(40, 4, 'Rear right door'),
  unlock(53, 1, 'Unlock'),
  lock(53, 2, 'Lock'),
  chargePort(8, 0, 'Charge port'),
  honk(15, 1, 'Honk'), // short
  flash(33, 6, 'Flash'), // high beam flash
  // Toggles climate on and off; needs the Commander's own link to the car,
  // which ScanMyTesla mode drops.
  climate(70, 0, 'Climate');

  /// Opens a closure: only in P, wherever it is pressed from.
  bool get opens => id == 2 || id == 3 || id == 40;

  const S3xyAction(this.id, this.state, this.label);
  final int id, state;
  final String label;
}

/// Bluetooth link to the S3XY Commander, for only what its WiFi stream
/// cannot carry: pressing S3XY functions, and the trip figures the Commander
/// gets as a paired key from the car rather than off the bus.
/// Everything the bus has stays on WiFi.
///
/// Protocol per github.com/niklaswa/S3XYCommander (MIT): ESP-IDF protocomm
/// over GATT, each request a write then a read on one characteristic. Unofficial — a Commander update can break it.
///
/// The Commander takes one phone app at a time, so the S3XY app must be
/// closed. A new phone is approved once, in the car, by double-pressing the
/// right scroll wheel.
class Commander extends ChangeNotifier {
  static final service = Guid('5857a678-87c6-11eb-8dcd-0242ac130003');

  /// What the link is doing, in words: tooltips, snackbars, Diagnostics.
  /// [link] says it for the icon.
  String status = 'off';
  BtLink _link = BtLink.idle;
  DateTime? _until, _giveBackAt;

  /// When a link stepped aside comes back (the dash's timer).
  DateTime? resumeAt;

  /// The link's state for its icon; while ready, what the session carries.
  BtLink get link => !ready
      ? _link
      : dash || _borrowed
          ? BtLink.borrowed
          : switch (_level) { _none => BtLink.buttons, _lean => BtLink.lean, _ => BtLink.full };

  /// What [link] counts down to, or null.
  DateTime? get until => switch (link) {
        BtLink.paused => resumeAt,
        BtLink.borrowed => _giveBackAt,
        BtLink.buttons => dataAt,
        BtLink.lean => _wifiLive ? null : _refitAt,
        BtLink.full || BtLink.off => null,
        _ => _until,
      };
  bool ready = false;
  bool busy = false;

  /// Waiting for the in-car double-press that approves this phone.
  bool approving = false;

  /// The S3XY Dash is on this Commander too (ReqGetDashBasicInfo at connect,
  /// PushDeviceConnectionState after). The
  /// Commander feeds one client at a time and the Dash never backs off, so
  /// the dash does: Bluetooth then connects only when asked (a press, the
  /// Bluetooth icon) and hands the Commander back [_lend] after the last
  /// press.
  bool dash = false;
  String dashInfoRaw = ''; // the ReqGetDashBasicInfo reply, for the log

  /// Trip figures from the car's API, through the Commander paired with the
  /// car as a key: what the S3XY Dash shows. Null until pushed.
  String? navDest;
  double? navMiles, navMinutes;
  double? navArrivePct; // battery % at arrival (field 9; no unit given)

  /// What the push path and the Commander's link to the car did, in words:
  /// shown on the Bluetooth icon and in the Diagnostics log, so a missing
  /// route on the dash can be told apart from a quiet one.
  String pushInfo = 'not connected';
  String carLink = 'unknown';
  String carLinkRaw = ''; // the reply's body as sent, to check [apiWords] against
  final pushFields = <int>{}; // every vehicle-data field pushed this connection
  int pushCount = 0;
  String lastPush = '';

  /// Each push's vehicle data (PushVehicleDataHolder fields), and null when
  /// the link drops: [Panda.fromBt], the dash's data without WiFi.
  void Function(Map<int, Object>? data)? onData;

  /// The Commander's own recirculation reading (field 101, DashRecirc), off
  /// the bus, no key needed: the low bits 0 AUTO, 1 RECIRC, 2 FRESH, and
  /// 0x80 on top after its own press (129 seen in RECIRC while the screen's
  /// request, 0x2F3, still said FRESH: the press bypasses the screen). Used
  /// only where the WiFi stream lacks the HVAC's frame (0x243, absent on the
  /// test car even with climate on).
  int? recircMode;

  BluetoothDevice? _dev;
  BluetoothCharacteristic? _cmd;
  Sec1? _sec;
  StreamSubscription? _watch, _adapter, _pushes;
  bool _borrowed = false; // this session is a borrow: no car data subscribed
  bool _on = false;
  Timer? _retry, _giveBack;
  int _attempt = 0;
  bool _dialing = false; // an attempt is running
  bool _asked = false; // the owner asked for the link: a refusal may ask for the double-press
  int _asks = 0; // retries left of an owner's ask, should it stumble before the Commander answers
  bool _parked = false; // refused, or not approved: only the owner tries again
  static const _lend = Duration(seconds: 30);
  DateTime _lastScan = DateTime.fromMillisecondsSinceEpoch(0);

  static const _net = MethodChannel('tesla_dash/net');

  /// Connects and keeps reconnecting, like the WiFi link.
  void connect() {
    _on = true;
    _attempt = 0;
    // Bluetooth coming on is the moment to look, not the next backoff step;
    // going off, the moment to say so, not when a countdown runs out.
    _adapter ??= FlutterBluePlus.adapterState.listen((s) {
      final was = _adapterWas;
      _adapterWas = s;
      if (was == null || s == was) return; // the state at listening: the dial sees it
      if (s == BluetoothAdapterState.on) {
        // Off has no retry of its own (see [_scheduleRetry]): the look is ours.
        if (_on && _link == BtLink.off && !ready && !_dialing) {
          _attemptConnect();
        } else {
          kick();
        }
      } else if (s == BluetoothAdapterState.off) {
        _adapterOff();
      }
    });
    _attemptConnect();
  }

  BluetoothAdapterState? _adapterWas;

  /// The phone's Bluetooth went off: no link, no retries, said now. It
  /// coming back on starts the next look.
  void _adapterOff() {
    if (!_on) return; // stepped aside or stopped: [resume] or [connect] dials
    _gen++; // an attempt under way stops at its next step
    _dialing = false;
    _retry?.cancel();
    _teardown();
    _set(BtLink.off, 'bluetooth is off');
  }

  /// Tries now instead of at the end of the backoff: Bluetooth came on, the
  /// WiFi link just found the Commander awake, the app came to the front,
  /// or a button was pressed ([ask]: then also offer to switch Bluetooth
  /// on). Does nothing while connected or mid-attempt. Refused, not
  /// approved, or left to the S3XY Dash, only [ask] tries again.
  void kick({bool ask = false}) {
    if (ask &&
        Platform.isAndroid &&
        FlutterBluePlus.adapterStateNow == BluetoothAdapterState.off) {
      FlutterBluePlus.turnOn().catchError((_) {});
    }
    if (!_on || ready) return;
    if (ask) {
      _asked = true; // an attempt already running counts as asked too
      _asks = 1;
      _parked = false;
      _attempt = 0;
    }
    final waiting = _retry?.isActive ?? false;
    if (_dialing || !(waiting || ask)) return;
    _attemptConnect(); // cancels the retry first, so the notify re-kicks nothing
    _set(
        dash ? BtLink.linking : BtLink.scanning,
        waiting
            ? status.replaceFirst(RegExp(r'retrying in \d+s$'), 'retrying now')
            : dash ? 'borrowing it from the S3XY Dash…' : 'connecting…');
  }

  /// Unpins the approved Commander so another (a replacement) can be found:
  /// the next connect takes the strongest one advertising.
  Future<void> forget() async {
    await (await SharedPreferences.getInstance()).remove('commanderId');
    // Mid-scan, that scan still looks for the old one: retry fast after it.
    _attempt = 0;
    dash = false; // nothing known yet about the next one
    if (ready) {
      await _lost('looking for another Commander');
    } else {
      kick(ask: true);
    }
  }

  /// Presses [a] once (TryAction).
  Future<void> tryAction(S3xyAction a) async {
    if (!ready) throw CommanderError(status);
    if (busy) throw CommanderError('busy with the last press');
    busy = true;
    notifyListeners();
    final int s;
    try {
      s = await _request(tryActionRequest(a));
    } catch (e) {
      // The session is spent either way. A reply out of step means the
      // Commander read garbage; a lost link may have come after it acted,
      // as it acts on the write, before answering.
      _lost('$e');
      throw e is CommanderError ? e : CommanderError('no answer — it may have gone through');
    } finally {
      busy = false;
      if ((dash || _borrowed) && ready) _giveBackIn(_lend);
      notifyListeners();
    }
    if (s != 0) {
      throw CommanderError('refused (${s < _statuses.length ? _statuses[s] : s})');
    }
  }

  int _gen = 0; // the current attempt; an older one stops at its next step

  Future<void> _attemptConnect() async {
    final gen = ++_gen;
    _retry?.cancel();
    _dialing = true;
    if (!_asked && _asks > 0) {
      _asked = true; // the retry of an owner's ask is asked too
      _asks--;
    }
    try {
      await _teardown();
      if (!_on || gen != _gen) return;
      await _open(gen);
      _attempt = 0;
      _asks = 0;
    } catch (e) {
      if (gen != _gen) return; // superseded: the link is the newer attempt's
      await _teardown();
      _scheduleRetry('$e', e is CommanderError ? e.link : BtLink.retrying);
    } finally {
      if (gen == _gen) {
        _dialing = false;
        _asked = false;
      }
    }
  }

  bool _paused = false, _redial = false;

  /// Steps aside while the WiFi stream starts. The Commander drops its
  /// Bluetooth devices in that switch: a link already up then took it down,
  /// both links lost and again soon after, every time, while a link made
  /// once the stream ran never did (seen in the car). No link and no
  /// retries until [resume]. Says whether a link was up or on its way.
  Future<bool> pause() async {
    if (!_on) return false;
    final was = ready || _dialing;
    // Left idle on purpose (handed back to the S3XY Dash, or parked after a
    // refusal) stays idle: only a link that was up or retrying comes back.
    _redial = was || (_retry?.isActive ?? false);
    _on = false;
    _paused = true;
    _gen++; // an attempt under way stops at its next step
    _dialing = _asked = false;
    _retry?.cancel();
    _refitTimer?.cancel();
    await _teardown();
    if (_redial) _set(BtLink.paused, 'waiting for the WiFi stream to start');
    return was;
  }

  /// Back after [pause]: dials again if it had a link to come back to.
  /// Not through [connect], which would start the backoff (and the
  /// Bluetooth-on prompt) afresh. Nothing if not paused.
  void resume() {
    if (!_paused) return;
    _paused = false;
    _on = true;
    if (_redial) _attemptConnect();
  }

  /// Hands the Commander back to the S3XY Dash [after] the last press.
  void _giveBackIn(Duration after) {
    _giveBack?.cancel();
    _giveBackAt = DateTime.now().add(after);
    _giveBack = Timer(after, () async {
      if (!(dash || _borrowed) || !ready || busy) return; // a press in flight re-arms it
      if (!dash) {
        // The Dash left meanwhile: a full session, car data and all, instead.
        await _teardown();
        if (!_dialing && !ready) _scheduleRetry('the S3XY Dash left');
        return;
      }
      _teardown(); // no retry follows
      // Said now, not after the disconnect: a borrow a press starts
      // meanwhile keeps its own status.
      _set(BtLink.dash, 'handed back to the S3XY Dash — a press or the Bluetooth icon borrows it');
    });
  }

  Future<void> _open(int gen) async {
    // Said first: the adapter wait can take seconds.
    _set(BtLink.scanning, 'looking for the Commander…');
    // Still switching on counts as not yet known: scanning then fails.
    final state = await FlutterBluePlus.adapterState
        .firstWhere((s) =>
            s != BluetoothAdapterState.unknown && s != BluetoothAdapterState.turningOn)
        .timeout(const Duration(seconds: 5),
            onTimeout: () => BluetoothAdapterState.unknown);
    if (state == BluetoothAdapterState.off) {
      // Asked once per connect, so the retries do not nag.
      if (Platform.isAndroid && _attempt == 0) {
        FlutterBluePlus.turnOn().catchError((_) {});
      }
      throw CommanderError('bluetooth is off', BtLink.off);
    }
    final dev = await _find();
    // Paused or redialled during the scan: not this attempt's to connect.
    if (gen != _gen || !_on) throw CommanderError('stepped aside');
    _set(BtLink.linking, 'connecting…');
    // Held before connecting: FBP's MTU request can throw with the link up,
    // and a link nobody closes keeps the Commander from advertising.
    _dev = dev;
    await dev.connect(timeout: const Duration(seconds: 15));

    // Endpoints are named by their 0x2901 user descriptions.
    final ep = <String, BluetoothCharacteristic>{};
    for (final s in await dev.discoverServices()) {
      if (s.uuid != service) continue;
      for (final c in s.characteristics) {
        for (final d in c.descriptors) {
          if (d.uuid != Guid('2901')) continue;
          ep[String.fromCharCodes((await d.read()).where((b) => b >= 0x20))] = c;
        }
      }
    }
    final session = ep['prov-session'], cmd = ep['enhapi'];
    if (session == null || cmd == null) {
      throw CommanderError('unknown Commander firmware (${ep.keys.join(', ')})');
    }

    _set(BtLink.linking, 'handshake…');
    final sec = Sec1();
    sec.check(await _rpc(session, sec.answer(await _rpc(session, sec.hello()))));
    _sec = sec;
    _cmd = cmd;

    final prefs = await SharedPreferences.getInstance();
    final id = await _phoneId(prefs);
    var s = await _request(sendUuidRequest(id));
    String said(int s) => s < _statuses.length ? _statuses[s] : 'status $s';
    // Any refusal means not approved now: every non-zero code counts
    // alike (an unknown phone gets 4). The Dash, refused, asks
    // for the same double-press, so prompting on every automatic reconnect
    // has the two take turns for it. Only a first approval (unpinned, 4)
    // or the owner asking prompts, and a refusal is never retried on its own.
    if (s != 0 && !_asked && (prefs.getString('commanderId') != null || s != 4)) {
      _parked = true;
      throw CommanderError('not approved now (${said(s)})');
    }
    final by = DateTime.now().add(const Duration(minutes: 1));
    for (; s != 0; s = await _request(sendUuidRequest(id))) {
      if (DateTime.now().isAfter(by) || !_on) {
        _parked = true; // asked for a minute; again only when the owner asks
        throw CommanderError('this phone was not approved (${said(s)})');
      }
      approving = true;
      _set(BtLink.approving, 'approve this phone: in the car, double-press the right scroll wheel (${said(s)})', by);
      await Future.delayed(const Duration(seconds: 2));
    }
    approving = false;
    // Approved: from now on this is the Commander the dash looks for.
    await prefs.setString('commanderId', dev.remoteId.str);

    // Is the S3XY Dash on it too? ReqGetDashBasicInfo, read-only;
    // field 4 says so on current Commander firmware. Unanswered, the last belief stands.
    final info = sec.crypt(await _rpc(cmd, sec.crypt(const [0x08, 0x82, 0x01, 0xea, 0x08, 0x00])));
    dashInfoRaw = info.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    if (dashConnected(info) case final bool on) dash = on;
    if (dash && !_asked) throw CommanderError('left to the S3XY Dash');

    // Car data and trip figures. Pushes come in the clear (asked for in
    // [Sec1.hello]), so they leave the shared cipher stream alone.
    final push = ep['push-enhapi'];
    pushCount = 0;
    if (push == null) {
      pushInfo = 'no push channel (${ep.keys.join(', ')})';
    } else if (!sec.pushesClear) {
      pushInfo = 'Commander wants encrypted pushes: not subscribed';
    } else if (dash) {
      // Borrowed for a press: its connection pushes only; the Dash keeps
      // the data subscription.
      _borrowed = true;
      dev.cancelWhenDisconnected(_pushes = push.onValueReceived.listen(onPush));
      await push.setNotifyValue(true);
      pushInfo = 'not subscribed: borrowed from the S3XY Dash';
    } else {
      dev.cancelWhenDisconnected(_pushes = push.onValueReceived.listen(onPush));
      await push.setNotifyValue(true);
      await _subscribe(sec, cmd, _dialLevel);
    }
    // The Commander's own link to the car, which the nav fields come over
    // (ReqGetTeslaAPIStatus, read-only).
    final api = _fields(sec.crypt(await _rpc(cmd, sec.crypt(const [0x08, 0x52, 0xea, 0x05, 0x00]))));
    carLink = api[1] == 83 && api[94] is List<int> ? apiWords(api[94] as List<int>) : 'no answer';
    carLinkRaw = api[94] is List<int>
        ? (api[94] as List<int>).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')
        : '';

    ready = true;
    _set(_link, 'ready'); // [link] says what the session carries
    // Borrowed: back to the Dash after the last press. Unasked (the Dash
    // came during the setup, by push): right away.
    if (dash) _giveBackIn(_asked ? _lend : Duration.zero);
    // Emits the current state first, so a link that dropped already still
    // lands here.
    _watch = dev.connectionState
        .where((s) => s == BluetoothConnectionState.disconnected)
        .listen((_) => _lost('link lost'));
  }

  /// Finds the approved Commander by scan, or before any approval the
  /// strongest one advertising: the one in this car. Only advertising ones
  /// count, so a link the phone already holds is never borrowed: that is the
  /// S3XY app's, and a second session on it would break both.
  Future<BluetoothDevice> _find() async {
    // The manifest has no neverForLocation, so Android hides every scan
    // result while Location is off.
    if (Platform.isAndroid &&
        !(await _net.invokeMethod<bool>('locationOn') ?? true)) {
      throw CommanderError('turn on Location — Android hides the Commander without it', BtLink.noLocation);
    }
    // Android silently drops results for an app that starts more than 5 scans
    // in 30 s, which retries and kicks could otherwise run into.
    const gap = Duration(milliseconds: 6500);
    final wait = gap - DateTime.now().difference(_lastScan);
    if (wait > Duration.zero) await Future.delayed(wait > gap ? gap : wait); // clock set back
    // Diagnostics may be scanning; starting ours would end it.
    if (FlutterBluePlus.isScanningNow) throw CommanderError('bluetooth busy');
    final pin = (await SharedPreferences.getInstance()).getString('commanderId');
    var seen = <ScanResult>[];
    final hit = Completer<void>();
    final sub = FlutterBluePlus.onScanResults.listen((rs) {
      // Other scans feed this stream too. Once approved, ours only: a
      // neighbour's would wait for an approval that never comes, and lock
      // their phone out meanwhile.
      seen = [
        for (final r in rs)
          if (r.advertisementData.serviceUuids.contains(service) &&
              (pin == null || r.device.remoteId.str == pin))
            r
      ];
      if (pin != null && seen.isNotEmpty && !hit.isCompleted) hit.complete();
    });
    try {
      await FlutterBluePlus.startScan(
          withServices: [service],
          timeout: const Duration(seconds: 5),
          androidUsesFineLocation: true);
      _lastScan = DateTime.now(); // only scans that started count
      // Ours showing up, or the scan running out. Never stopScan: it would
      // also end a scan Diagnostics started meanwhile.
      await Future.any<Object?>([
        hit.future,
        FlutterBluePlus.isScanning.where((s) => !s).first,
      ]).timeout(const Duration(seconds: 8), onTimeout: () => null);
    } finally {
      await sub.cancel();
    }
    if (seen.isEmpty) {
      // Silent but linked to this phone: another app holds it. (Android lists
      // every GATT link here whatever the service, so match by id or name.)
      final held = await FlutterBluePlus.systemDevices([service]);
      if (held.any((d) => d.remoteId.str == pin || d.platformName.startsWith('ENH'))) {
        throw CommanderError('close the S3XY app — it is holding the Commander', BtLink.held);
      }
      throw CommanderError('${pin == null ? 'no Commander' : "this car's Commander not"} '
          'advertising (car asleep? S3XY app open?)', BtLink.away);
    }
    return (seen..sort((a, b) => b.rssi.compareTo(a.rssi))).first.device;
  }

  /// What WiFi lacks: destination, miles, minutes and battery % at arrival
  /// (the S3XY Dash's nav card, none of it on the bus as such) and
  /// recirculation; then what the dash shows when WiFi is off.
  static const _wifiLacks = [6, 7, 8, 9, 101];
  static const _allFields = [..._wifiLacks, ...Panda.btFields];

  /// How much car data a session subscribes to: none (the buttons only),
  /// what WiFi lacks, or all of it. A subscription only adds, so a session
  /// takes more on the way and less only by dialling again.
  static const _none = 0, _lean = 1, _full = 2;
  int _level = _none;

  /// Subscribes this session to [level] (see [wifiLive], [dataHold]). Best
  /// effort: the reply is decrypted to keep the stream in step and only
  /// reported.
  Future<void> _subscribe(Sec1 sec, BluetoothCharacteristic cmd, int level) async {
    _level = level;
    _subscribedAt = DateTime.now();
    // Short of all of it in the spell after WiFi went: all of it once out.
    if (level < _full && !_wifiLive) _refitIn(_leanFor - _subscribedAt.difference(_wifiAt) + const Duration(seconds: 1));
    if (level == _none) {
      pushInfo = 'buttons only: car data once the WiFi stream has settled';
      return;
    }
    final (_, st) = replyStatus(sec.crypt(await _rpc(
        cmd, sec.crypt(subscribeRequest(level == _lean ? _wifiLacks : _allFields)))));
    pushInfo = 'subscribed${level == _full ? '' : _wifiLive ? ' to the route and recirculation only (WiFi is live)' : ' to the route and recirculation only (WiFi was, just now)'}, '
        '${st < _statuses.length ? _statuses[st] : 'status $st'}';
    // The Commander pushes a field when it changes: a route set before we
    // connected, parked, might never come. This asks it to push what it
    // has now (ReqDashTriggerAllDataPush, 48; read-only).
    sec.crypt(await _rpc(cmd, sec.crypt(const [0x08, 0x30, 0xda, 0x03, 0x00])));
  }

  /// Set by the dash as the WiFi stream comes and goes. While it is live the
  /// Commander streams the bus in ScanMyTesla mode, short of memory (its
  /// own app says it drops its Bluetooth devices then), so this link asks
  /// only for what WiFi lacks. With both links pushing the same car data,
  /// both dropped for 15 s in the car, and again soon after.
  set wifiLive(bool v) {
    if (v) _wifiAt = DateTime.now();
    if (v == _wifiLive) return;
    _wifiLive = v;
    // Once the change has held, so a stall that clears changes nothing:
    // less soon, all of it only once WiFi has stayed away (a stall is when
    // a struggling Commander can least take more).
    _refitIn(Duration(seconds: v ? 3 : 10));
  }

  /// Set by the dash while a WiFi stream starts and settles: no car data
  /// over Bluetooth then, the buttons only (the buttons at once, the rest
  /// after a wait). Lifted, the session takes what WiFi lacks on the same
  /// link.
  bool get dataHold => _dataHold;
  set dataHold(bool v) {
    if (v == _dataHold) return;
    _dataHold = v;
    // WiFi down meanwhile: the timer already set (the wait after a drop, or
    // the spell's end) decides, with the hold lifted.
    if (!v && _wifiLive) _refitIn(Duration.zero);
  }

  /// When the dash lifts [dataHold], for the Bluetooth icon's countdown.
  DateTime? dataAt;

  bool _wifiLive = false, _dataHold = false;
  DateTime _wifiAt = DateTime.fromMillisecondsSinceEpoch(0), _subscribedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _refitAt;
  Timer? _refitTimer;
  static const _leanFor = Duration(seconds: 30);

  void _refitIn(Duration d) {
    _refitTimer?.cancel();
    _refitAt = DateTime.now().add(d);
    _refitTimer = Timer(d, _refit);
  }

  /// What WiFi leaves to this link: nothing while a stream settles
  /// ([dataHold]), then what WiFi lacks.
  int get _wifiShare => _dataHold ? _none : _lean;

  /// What a session dialled now asks for: WiFi's share while WiFi is live
  /// and for a spell after, as a Commander that has just restarted brings
  /// Bluetooth back before WiFi; all of it otherwise.
  int get _dialLevel =>
      _wifiLive || DateTime.now().difference(_wifiAt) < _leanFor ? _wifiShare : _full;
  @visibleForTesting
  int get dialLevelNow => _dialLevel;

  /// What the running session should have. One that outlived WiFi knows
  /// the Commander did not restart: all the car data, straight away. One
  /// dialled in the spell waits it out.
  int get _sessionLevel => _wifiLive ||
          (_subscribedAt.isAfter(_wifiAt) && DateTime.now().difference(_wifiAt) < _leanFor)
      ? _wifiShare
      : _full;

  /// Brings the session's subscription in line: more fields on the same
  /// session, so the car data has no gap; fewer only by dialling again.
  Future<void> _refit() async {
    if (busy || _dialing) {
      _refitIn(const Duration(seconds: 3)); // after the press or the dial
      return;
    }
    if (!ready || _borrowed || dash) return;
    final want = _sessionLevel;
    if (want == _level) {
      // Short of all of it in the spell after WiFi went: look again once out.
      if (_level < _full && !_wifiLive) {
        _refitIn(_leanFor - DateTime.now().difference(_wifiAt) + const Duration(seconds: 1));
      }
      return;
    }
    if (want < _level) {
      _attemptConnect();
      return;
    }
    busy = true;
    try {
      await _subscribe(_sec!, _cmd!, want);
    } catch (e) {
      _lost('$e');
    } finally {
      busy = false;
      // The S3XY Dash came meanwhile: its turn, as after a press.
      if (dash && ready) _giveBackIn(Duration.zero);
      notifyListeners();
    }
  }

  Future<List<int>> _rpc(BluetoothCharacteristic c, List<int> data) async {
    await c.write(data, allowLongWrite: true);
    return c.read();
  }

  /// One encrypted EnhAPI exchange. Returns the reply's status, 0 = OK.
  Future<int> _request(List<int> req) async {
    final sec = _sec!;
    final (type, status) = replyStatus(sec.crypt(await _rpc(_cmd!, sec.crypt(req))));
    // Anything but the matching reply means the cipher streams have parted.
    if (type != (_fields(req)[1] as int) + 1) {
      throw CommanderError('Commander out of step');
    }
    return status;
  }

  @visibleForTesting
  void onPush(List<int> v) {
    pushCount++;
    lastPush = v.take(40).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    try {
      final f = _fields(v);
      // PushDeviceConnectionState (push type 8) about the S3XY Dash (64):
      // connected (0, left out, or 8 already connected) or gone
      // (disconnected, failed, removed, timed out, no session);
      // connecting or updating changes nothing. Never a request from here:
      // one cipher stream, in order.
      if (f[10] case final List<int> p when f[1] == 8) {
        final d = _fields(p);
        final on = switch (d[2] ?? 0) { 0 || 8 => true, 2 || 3 || 4 || 5 || 7 => false, _ => null };
        if (d[6] == 64 && on != null && on != dash) {
          dash = on;
          if (dash) _giveBackIn(Duration.zero); // it came while we held the Commander
          notifyListeners();
        }
        return;
      }
      final data = f[25]; // PushVehicleDataHolder, push type 16
      if (f[1] != 16 || data is! List<int>) return;
      final d = _fields(data);
      pushFields.addAll(d.keys);
      // Each field is proto3 optional: an explicit "" means no destination.
      if (d[6] case final List<int> s) {
        navDest = s.isEmpty ? null : utf8.decode(s, allowMalformed: true);
      }
      if (d[7] case final double m) navMiles = m;
      if (d[8] case final double m) navMinutes = m;
      if (d[9] case final double p) navArrivePct = p;
      if (d[101] case final int r) recircMode = r;
      onData?.call(d);
      notifyListeners();
    } catch (_) {
      // A push we cannot read costs one update, not the link.
    }
  }

  Future<void> _lost(String why) async {
    if (!ready) return;
    await _teardown();
    if (!_dialing && !ready) _scheduleRetry(why); // an owner's ask may have started one meanwhile
  }

  Future<void> _teardown() async {
    // First: a push still in flight must not bring the car data back.
    _pushes?.cancel();
    _pushes = null;
    _borrowed = false;
    ready = false;
    approving = false;
    _giveBack?.cancel();
    _sec = null;
    _cmd = null;
    navDest = null;
    navMiles = navMinutes = navArrivePct = null;
    recircMode = null;
    onData?.call(null);
    pushInfo = 'not connected';
    carLink = 'unknown';
    carLinkRaw = '';
    pushFields.clear();
    await _watch?.cancel();
    _watch = null;
    final d = _dev;
    _dev = null;
    // Not queued: it also cancels a connect still in progress.
    if (d != null) await d.disconnect(queue: false).catchError((_) {});
  }

  void _scheduleRetry(String why, [BtLink l = BtLink.retrying]) {
    if (!_on) return;
    _retry?.cancel();
    // Bluetooth off: its coming back on starts the next look (see
    // [connect]); nothing to count down.
    if (l == BtLink.off) {
      _attempt++; // the turn-on prompt once per connect, not per look
      _set(l, why);
      return;
    }
    // Retrying a refusal, or the Dash's Commander, is the fight: wait for
    // the owner. An owner's ask still gets its one retry.
    if (_parked) {
      _asks = 0;
      _set(BtLink.refused, '$why — tap the Bluetooth icon to approve this phone');
      return;
    }
    if (dash && _asks == 0) {
      _set(BtLink.dash, '$why — a press or the Bluetooth icon borrows it');
      return;
    }
    // Quick after a dropout, then easing off while the car sleeps; [kick]
    // cuts any wait short.
    const delays = [2, 5, 10, 20, 30];
    final secs = delays[min(_attempt, delays.length - 1)];
    _attempt++;
    _set(l, '$why — retrying in ${secs}s', DateTime.now().add(Duration(seconds: secs)));
    _retry = Timer(Duration(seconds: secs), _attemptConnect);
  }

  /// This phone's name on the Commander's allowlist, made once. Same shape
  /// as niklaswa's captures: a lowercase UUID in braces.
  static Future<String> _phoneId(SharedPreferences prefs) async {
    final saved = prefs.getString('commanderPhoneId');
    if (saved != null) return saved;
    final b = _random(16);
    b[6] = b[6] & 0x0f | 0x40; // version 4
    b[8] = b[8] & 0x3f | 0x80; // RFC 4122 variant
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    final id = '{${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}}';
    await prefs.setString('commanderPhoneId', id);
    return id;
  }

  /// Puts the link in a state, for tests and screenshots.
  @visibleForTesting
  void show(BtLink l, String s, [DateTime? until]) => _set(l, s, until);

  void _set(BtLink l, String s, [DateTime? until]) {
    _link = l;
    _until = until;
    status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _on = false;
    _paused = false;
    _retry?.cancel();
    _refitTimer?.cancel();
    _adapter?.cancel();
    _teardown();
    super.dispose();
  }
}

/// What the Bluetooth link is doing, for its icon (see [Commander.link]).
enum BtLink {
  idle, // not started
  off, // the phone's Bluetooth is off
  noLocation, // Location off: Android hides the Commander
  scanning,
  linking, // connecting, handshake
  approving, // waiting for the in-car double-press
  refused, // not approved: only a tap tries again
  dash, // left to the S3XY Dash on purpose
  paused, // stepped aside while the WiFi stream starts
  away, // no Commander advertising: car asleep, or the S3XY app has it
  held, // the S3XY app holds the Commander's link
  retrying,
  borrowed, // ready, borrowed from the S3XY Dash for a press
  buttons, // ready, no car data yet (the WiFi stream settling)
  lean, // ready, with what WiFi lacks
  full, // ready, with all the car data
}

class CommanderError implements Exception {
  CommanderError(this.message, [this.link = BtLink.retrying]);
  final String message;
  final BtLink link; // what the link waits in, should this end an attempt
  @override
  String toString() => message;
}

const _statuses = [
  'ok', 'invalid security scheme', 'invalid proto', 'too many sessions',
  'invalid argument', 'internal error', 'crypto error', 'invalid session',
  'not supported',
];

/// ESP-IDF protocomm "Security1" as Enhauto runs it: X25519, then the shared
/// secret XOR SHA-256 of the proof of possession is an AES-256-CTR key with
/// the Commander's random as IV. One counter stream runs through both
/// directions, so every message must be processed once, in order.
class Sec1 {
  Sec1([List<int>? secret]) : _secret = secret ?? _random(32);

  final List<int> _secret;
  late final Uint8List publicKey = x25519(_secret, _basePoint);
  CTRStreamCipher? _ctr;

  /// False if the Commander turned down clear pushes: they would then share
  /// the cipher stream, so the dash must not ask for any.
  bool pushesClear = true;

  /// SessionCmd0. Security flag 1 asks for pushes in the clear, which keeps
  /// them out of the shared counter stream.
  List<int> hello() => _session(0, 20, [..._b(1, publicKey), ..._u(2, 1)]);

  /// Takes SessionResp0, returns SessionCmd1.
  List<int> answer(List<int> resp0) {
    final r = _sessionReply(resp0, 1, 21);
    // Known firmware grants flag 1 without echoing it; only a refusal counts.
    if (r[4] case final int f when f & 1 == 0) pushesClear = false;
    final devKey = r[2], iv = r[3];
    if (devKey is! List<int> || devKey.length != 32 ||
        iv is! List<int> || iv.length != 16) {
      throw CommanderError('bad handshake reply');
    }
    final shared = x25519(_secret, devKey);
    if (shared.every((b) => b == 0)) throw CommanderError('bad Commander key');
    // The proof of possession is the same in every Commander's firmware.
    final pop = SHA256Digest().process(Uint8List.fromList(utf8.encode('s3xy_enh')));
    final key = Uint8List.fromList([for (var i = 0; i < 32; i++) shared[i] ^ pop[i]]);
    _ctr = CTRStreamCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), Uint8List.fromList(iv)));
    return _session(2, 22, [..._b(2, crypt(devKey)), ..._u(3, 1)]); // 1 = phone
  }

  /// Takes SessionResp1: the Commander sends our key back encrypted, which
  /// confirms the session key. The PoP is public, so it does not prove the
  /// device is genuine; pinning in [Commander._find] keeps it to ours.
  void check(List<int> resp1) {
    final v = _sessionReply(resp1, 3, 23)[3];
    if (v is! List<int> || !listEquals(crypt(v), publicKey)) {
      throw CommanderError('handshake failed — Commander firmware changed?');
    }
  }

  Uint8List crypt(List<int> data) => _ctr!.process(Uint8List.fromList(data));
}

/// SessionData{sec_ver: 1, sec1: Sec1Payload{msg, `field`: body}}.
List<int> _session(int msg, int field, List<int> body) =>
    [..._u(2, 1), ..._b(11, [..._u(1, msg), ..._b(field, body)])];

Map<int, Object> _sessionReply(List<int> data, int msg, int field) {
  final p = _fields(_fields(data)[11] as List<int>? ?? const []);
  final body = p[field];
  if (p[1] != msg || body is! List<int>) throw CommanderError('bad handshake reply');
  final r = _fields(body);
  if ((r[1] ?? 0) != 0) throw CommanderError('handshake refused (status ${r[1]})');
  return r;
}

/// EnhApiPayloadHolder requests: SendUUID (32), TryAction (28),
/// SubscribeVehicleData (124).
List<int> sendUuidRequest(String id) =>
    [..._u(1, 32), ..._b(43, _b(1, utf8.encode(id)))];

/// ReqTryAction{PressActionConfig{action, switch type 1 (on/off), [state]}}.
/// (niklaswa's Swift default, type 0 with state 1, is no recirculation
/// function at all.)
List<int> tryActionRequest(S3xyAction a) => [
      ..._u(1, 28),
      ..._b(39, _b(1, [..._u(1, a.id), ..._u(2, 1), ..._b(3, _varint(a.state))])),
    ];

List<int> subscribeRequest(List<int> fields) =>
    [..._u(1, 124), ..._b(135, _b(13, [for (final f in fields) ..._varint(f)]))];

/// TeslaAPI.RespGetApiStatus in words: the link, the infotainment session
/// (the one the nav fields need) and the pairing.
String apiWords(List<int> body) {
  const link = ['initial', 'partly configured', 'configured', 'connected', 'disconnected', 'error'];
  const errors = ['', 'unknown error', 'not fully configured', 'failed to configure',
      'car not found', 'failed to connect'];
  const session = ['initial', 'waiting', 'ok', 'error'];
  const ui = ['not paired', 'awaiting connection', 'paired', 'not available'];
  String name(List<String> names, Object? v) =>
      v is int && v < names.length ? names[v] : '${v ?? '—'}';
  final f = _fields(body);
  // Session statuses repeat as field 3: keep the infotainment one (domain 4).
  Object? info;
  var i = 0;
  while (i < body.length) {
    final tag = body[i++];
    if (tag & 7 == 0) {
      while (body[i++] & 0x80 != 0) {}
    } else if (tag & 7 == 2) {
      final n = body[i++];
      final d = _fields(body.sublist(i, i + n));
      if (tag >> 3 == 3 && d[1] == 4) info = d[2] ?? 0; // proto3 leaves 0 (initial) out
      i += n;
    } else {
      break;
    }
  }
  final e = f[2];
  final err = e is int && e > 0 ? ' (${name(errors, e)})' : '';
  return 'car link ${name(link, f[1] ?? 0)}$err, infotainment ${name(session, info)}, '
      '${name(ui, f[6] ?? 0)}';
}

/// RespGetDashBasicInfo (131, payload 142): field 4, whether the Dash is
/// connected, or null when the reply is something else or an error.
bool? dashConnected(List<int> reply) {
  final f = _fields(reply);
  if (f[142] case final List<int> b when f[1] == 131) {
    final r = _fields(b);
    if ((r[1] ?? 0) == 0) return r[4] == 1;
  }
  return null;
}

/// msgType and status of an EnhAPI reply. The status is field 1 of its one
/// payload message, left out when 0 (OK).
(int, int) replyStatus(List<int> reply) {
  final f = _fields(reply);
  final body = f.values.whereType<List<int>>().firstOrNull;
  return (f[1] as int? ?? 0, body == null ? 0 : (_fields(body)[1] as int? ?? 0));
}

// Protobuf wire format, just the shapes these messages use.

List<int> _varint(int v) {
  final out = <int>[];
  for (; v >= 0x80; v >>= 7) {
    out.add(v & 0x7f | 0x80);
  }
  return out..add(v);
}

List<int> _u(int field, int v) => [..._varint(field << 3), ..._varint(v)];

List<int> _b(int field, List<int> v) =>
    [..._varint(field << 3 | 2), ..._varint(v.length), ...v];

/// Top-level fields of one message: varints as int, length-delimited as
/// bytes, fixed32 as float (the only fixed32s here are). Last one wins.
Map<int, Object> _fields(List<int> b) {
  final out = <int, Object>{};
  var i = 0;
  int varint() {
    var v = 0;
    for (var s = 0;; s += 7) {
      final x = b[i++];
      v |= (x & 0x7f) << s;
      if (x < 0x80) return v;
    }
  }

  while (i < b.length) {
    final tag = varint();
    switch (tag & 7) {
      case 0:
        out[tag >> 3] = varint();
      case 2:
        final n = varint();
        out[tag >> 3] = b.sublist(i, i += n);
      case 5:
        out[tag >> 3] = ByteData.sublistView(Uint8List.fromList(b.sublist(i, i += 4)))
            .getFloat32(0, Endian.little);
      case 1:
        i += 8;
      default:
        throw const FormatException('unsupported protobuf wire type');
    }
  }
  return out;
}

List<int> _random(int n) {
  final r = Random.secure();
  return List.generate(n, (_) => r.nextInt(256));
}

final _p = (BigInt.one << 255) - BigInt.from(19);
final _a24 = BigInt.from(121665);
final _basePoint = [9, ...List.filled(31, 0)];

/// X25519 (RFC 7748 §5), checked against its test vectors. BigInt is not
/// constant-time, which is fine for one throwaway key per session.
Uint8List x25519(List<int> scalar, List<int> u) {
  final k = List<int>.of(scalar);
  k[0] &= 248;
  k[31] &= 127;
  k[31] |= 64;
  BigInt le(List<int> b) =>
      b.reversed.fold(BigInt.zero, (a, x) => (a << 8) | BigInt.from(x));
  final x1 = le([...u.sublist(0, 31), u[31] & 127]) % _p;

  var x2 = BigInt.one, z2 = BigInt.zero, x3 = x1, z3 = BigInt.one;
  var swap = 0;
  for (var t = 254; t >= 0; t--) {
    final bit = (k[t >> 3] >> (t & 7)) & 1;
    if ((swap ^ bit) == 1) {
      (x2, x3) = (x3, x2);
      (z2, z3) = (z3, z2);
    }
    swap = bit;
    final a = x2 + z2, aa = a * a % _p, b = x2 - z2, bb = b * b % _p;
    final e = aa - bb;
    final da = (x3 - z3) * a % _p, cb = (x3 + z3) * b % _p;
    x3 = (da + cb) * (da + cb) % _p;
    z3 = x1 * ((da - cb) * (da - cb) % _p) % _p;
    x2 = aa * bb % _p;
    z2 = e * (aa + _a24 * e) % _p;
  }
  if (swap == 1) {
    (x2, x3) = (x3, x2);
    (z2, z3) = (z3, z2);
  }
  var r = x2 * z2.modPow(_p - BigInt.two, _p) % _p;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++, r >>= 8) {
    out[i] = (r & BigInt.from(0xff)).toInt();
  }
  return out;
}
