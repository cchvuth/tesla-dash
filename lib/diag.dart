import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'commander.dart';
import 'finder.dart';
import 'panda.dart';
import 'signals.dart';

/// Everything needed to debug the link from the passenger seat: every CAN
/// id the Commander will stream, decoded values, TCP port probes, and a
/// one-tap log to paste back.
/// The version this app is: name, commit, a "+" if built from uncommitted
/// changes, and build time. Set at startup ([loadBuild]); empty off Android.
String diagBuild = '';

Future<void> loadBuild() async {
  try {
    diagBuild = await const MethodChannel('tesla_dash/net').invokeMethod<String>('buildInfo') ?? '';
  } on MissingPluginException {
    // no native side (tests, iOS): unknown
  }
}

/// The Diagnostics report: what the dash decoded, the Commander, and every
/// CAN id with its rate and recent payloads. One text for the Copy log button,
/// the trace file's export and its half-minute block.
String diagReport(Panda o, Commander? bt, {bool captureAll = false, String extra = ''}) {
    final secs = DateTime.now().difference(o.captureStart).inMilliseconds / 1000;
    final ids = o.frames.keys.toList()..sort();
    final b = StringBuffer()
      ..writeln('tesla-dash diagnostics ${DateTime.now().toIso8601String()}')
      ..writeln('build: ${diagBuild.isEmpty ? 'unknown' : diagBuild}')
      ..writeln('platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('link: ${o.status}, ${o.frameHz} frames/s, capture-all: $captureAll, '
          '${secs.toStringAsFixed(0)} s, ${ids.length} ids')
      ..writeln()
      ..writeln('decoded:')
      ..writeln('  speed ${o.speed} ${o.speedUnit}  gear ${o.gear}  '
          'pedal ${o.pedalPct}  brake ${o.braking}')
      ..writeln('  front ${o.frontKw} kW  rear ${o.rearKw} kW')
      ..writeln('  soc ${o.socPct} %  range ${o.rangeMi} mi  limit ${o.speedLimit}')
      ..writeln('  lights low ${o.lowBeam} high ${o.highBeam} drl ${o.drl}')
      ..writeln('  tyres bar ${o.tpFL} ${o.tpFR} ${o.tpRL} ${o.tpRR}')
      ..writeln('  belts ${o.beltDriver} ${o.beltPass} / ${o.belt2L} ${o.belt2C} '
          '${o.belt2R} / ${o.belt3L} ${o.belt3R}  buckled ${o.buckled.join(' ')}  '
          'fans ${o.fan1} ${o.fan2} (auto ${o.autoBlower})')
      ..writeln('  grip ${o.gripBits}')
      ..writeln('  g along ${o.gLong?.toStringAsFixed(2)} across ${o.gLat?.toStringAsFixed(2)}  '
          'peaks accel ${o.gMaxAccel.toStringAsFixed(2)} brake ${o.gMaxBrake.toStringAsFixed(2)} '
          'lat ${o.gMaxLat.toStringAsFixed(2)}')
      ..writeln('  map lights ${o.mapLight} dome ${o.domeLight}')
      ..writeln('  port ${o.chargePort}  tilt auto ${o.tiltAuto} dipped ${o.mirrorDipped}  '
          'air ${o.recirc} hvac ${o.hvacOn} recirculating ${o.recircOn}')
      ..writeln('  nav route ${o.navRoute} ${o.navMinutes} min ${o.navEnergyKwh} kWh')
      ..writeln('commander: ${bt?.pushInfo}, ${bt?.pushCount} pushes, '
          '${bt?.carLink} [${bt?.carLinkRaw}]; last push ${bt?.lastPush}')
      ..writeln('commander fields pushed: '
          '${(bt?.pushFields.toList() ?? [])..sort()}')
      ..writeln('commander dash ${bt?.dash} [${bt?.dashInfoRaw}]')
      ..writeln('commander: ${bt?.status}  recirc ${bt?.recircMode}  '
          'nav ${bt?.navMinutes} min ${bt?.navMiles} mi '
          '${bt?.navArrivePct} % ${bt?.navDest}')
      ..writeln()
      ..write(extra)
      ..writeln('subscribed ids: ${kSubscribeIds.map(_idHex).join(' ')}')
      ..writeln()
      ..writeln('id     bus  hz     data');
    for (final id in ids) {
      final f = o.frames[id]!;
      b.writeln('${_idHex(id)}  ${(f.bus == f.lastBus ? '${f.bus}' : '${f.bus}/${f.lastBus}').padLeft(3)}  '
          '${(f.count / secs).toStringAsFixed(1).padLeft(5)}  ${f.hex}');
      // The dash's own ids also list their other recent payloads, newest
      // first: a multiplexed frame's pages.
      if (kSubscribeIds.contains(id)) {
        for (final r in f.recent.reversed.skip(1)) {
          b.writeln('${' ' * 19}${hexOf(r)}');
        }
      }
    }
    return b.toString();
  }

String _idHex(int id) => '0x${id.toRadixString(16).toUpperCase().padLeft(3, '0')}';

/// The trace log with [report] appended: the one file the share sheet, Copy
/// log and adb all read. Null where there is none (not Android).
Future<File?> _traceWith(String report) async {
  const ch = MethodChannel('tesla_dash/net');
  final String? dir;
  try {
    dir = await ch.invokeMethod<String>('logDir');
  } on MissingPluginException {
    return null;
  }
  if (dir == null) return null;
  final f = File('$dir/trace.log');
  f.writeAsStringSync('${DateTime.now().toIso8601String()} export:\n$report\n', mode: FileMode.append);
  return f;
}

/// Opens the share sheet for the trace log, [report] added to its end.
Future<bool> shareTrace(String report) async {
  final f = await _traceWith(report);
  if (f == null) return false;
  return await const MethodChannel('tesla_dash/net').invokeMethod<bool>('shareLog', {'path': f.path}) ?? false;
}

/// The end of the same trace log as text, as much as the clipboard takes:
/// Android's carries about 1 MB, half a million characters, so 240 KB to
/// start with, halved while the phone refuses. Just [report] where there is
/// no log. Starts on a line, never mid-way.
Future<String> traceTail(String report, {int bytes = 240000}) async {
  final f = await _traceWith(report);
  if (f == null) return report;
  final len = f.lengthSync();
  final n = len < bytes ? len : bytes;
  final raf = f.openSync();
  try {
    raf.setPositionSync(len - n);
    final text = utf8.decode(raf.readSync(n), allowMalformed: true);
    return len > n ? text.substring(text.indexOf('\n') + 1) : text;
  } finally {
    raf.closeSync();
  }
}

class DiagPage extends StatefulWidget {
  const DiagPage({super.key, required this.obd, this.bt});

  final Panda obd;
  final Commander? bt;

  @override
  State<DiagPage> createState() => _DiagPageState();
}

class _DiagPageState extends State<DiagPage> {
  bool _all = false;
  final _probes = <String>[];
  bool _probing = false;
  final _ble = <String, String>{}; // remoteId -> description
  bool _scanning = false;
  Timer? _tick, _hunt, _route;
  String _pressure = ''; // the last tyre-pressure search, for the log
  String _nav = ''; // the last route search, for the log
  RouteSearch? _routeSearch;
  double _kmDriven = 0, _minutesGone = 0;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _hunt?.cancel();
    _route?.cancel();
    widget.obd.captureAll = false; // give the dash its latency back
    super.dispose();
  }

  /// The `nc -zv host port` equivalent: does anything accept a TCP connect?
  /// Read-only — nothing is written to the port.
  Future<void> _probe() async {
    setState(() {
      _probing = true;
      _probes.clear();
    });
    const host = '192.168.4.1';
    for (final port in [1337, 35000, 1338]) {
      String result;
      try {
        final s = await Socket.connect(host, port,
            timeout: const Duration(seconds: 3));
        s.setOption(SocketOption.tcpNoDelay, true);
        // Some services send a banner; wait briefly for one.
        final banner = <int>[];
        final sub = s.listen(banner.addAll);
        await Future.delayed(const Duration(seconds: 2));
        await sub.cancel();
        s.destroy();
        result = 'tcp $port OPEN'
            '${banner.isEmpty ? ', silent' : ', banner: ${_hex(banner)}'}';
      } on SocketException catch (e) {
        result = 'tcp $port closed (${e.osError?.message ?? e.message})';
      } on TimeoutException {
        result = 'tcp $port no answer (filtered/timeout)';
      }
      setState(() => _probes.add(result));
    }
    setState(() => _probing = false);
  }

  /// 10 s unfiltered BLE scan. A Tesla shows up as S<16 hex>C; if it does
  /// not, the dump shows what the phone sees instead.
  Future<void> _scanBle() async {
    setState(() {
      _scanning = true;
      _ble.clear();
    });
    try {
      if (Platform.isAndroid) await FlutterBluePlus.turnOn();
      // Already-connected and paired devices do not advertise to us; a car
      // held by the Tesla app's key lives here rather than in the scan.
      for (final d in [
        ...await FlutterBluePlus.systemDevices([Guid('1800')]),
        if (Platform.isAndroid) ...await FlutterBluePlus.bondedDevices,
      ]) {
        _ble[d.remoteId.str] = '${d.remoteId.str} system/bonded plat="${d.platformName}"';
      }
      final sub = FlutterBluePlus.onScanResults.listen((rs) {
        for (final r in rs) {
          final a = r.advertisementData;
          final mfg = a.manufacturerData.entries
              .map((e) => '${e.key.toRadixString(16)}:${_hex(e.value)}')
              .join(' ');
          _ble[r.device.remoteId.str] =
              '${r.device.remoteId.str} rssi ${r.rssi} '
              'adv="${a.advName}" plat="${r.device.platformName}" '
              'svc=[${a.serviceUuids.map((u) => u.str).join(',')}] mfg=[$mfg]';
        }
        if (mounted) setState(() {});
      });
      await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 10), androidUsesFineLocation: true);
      await Future.delayed(const Duration(seconds: 10));
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    } catch (e) {
      _ble['error'] = 'scan failed: $e';
    }
    if (mounted) setState(() => _scanning = false);
  }

  /// Looks for the tyres by their value: every CAN id is captured for 20 s
  /// and searched once a second for fields reading the given pressure, in
  /// any common encoding. The best few are shown and kept for the log.
  Future<void> _findPressure() async {
    final range = TextEditingController(text: '41-42');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // the keyboard leaves little of the landscape screen
        title: const Text('Find tyre pressure'),
        content: TextField(
          controller: range,
          keyboardType: TextInputType.text,
          decoration: const InputDecoration(
              labelText: "Tyre pressure on the car's screen, psi", hintText: '41-42'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Search')),
        ],
      ),
    );
    final v = RegExp(r'[\d.]+').allMatches(range.text).map((m) => double.parse(m[0]!)).toList();
    if (ok != true || v.isEmpty || !mounted) return;
    // Half a psi either side: the car's screen rounds.
    final search = PressureSearch(v.reduce(min) - 0.5, v.reduce(max) + 0.5);
    setState(() {
      _all = true;
      widget.obd.captureAll = true;
      _pressure = 'searching…';
    });
    _hunt?.cancel();
    _hunt = Timer.periodic(const Duration(seconds: 1), (t) {
      search.scan(widget.obd.frames);
      if (search.scans < 20) {
        if (mounted) setState(() => _pressure = 'searching… ${20 - search.scans} s');
        return;
      }
      t.cancel();
      final top = search.ranked.take(5).toList();
      _pressure = top.isEmpty
          ? 'nothing reads ${range.text} psi: the tyre data does not reach the WiFi stream'
          : [
              for (final (i, (h, seen)) in top.indexed)
                '${i + 1}. $h, in $seen of ${search.scans} scans',
            ].join('\n');
      if (!mounted) return;
      setState(() {});
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Fields reading ${range.text} psi'),
          content: SingleChildScrollView(child: SelectableText(_pressure)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    });
  }

  /// Finds where the car puts the route: started with a route set, it notes
  /// every field reading the route's distance or minutes to go, then, as
  /// the car drives, keeps the ones that count down with it. Tap again to
  /// stop; stops itself after 20 minutes.
  Future<void> _findNav() async {
    if (_route?.isActive ?? false) return _stopNav();
    final km = TextEditingController(text: '4.4'), mins = TextEditingController(text: '8');
    final dest = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // One row of fields fits the landscape screen; scrolls under the keyboard.
        scrollable: true,
        title: const Text('Find nav data'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Set the route on the car first, start here while still parked, '
              'then drive with this screen open. Tap Stop nav search on arrival.'),
          Row(children: [
            Expanded(
                child: TextField(
                    controller: km, decoration: const InputDecoration(labelText: 'Distance to go, km'))),
            const SizedBox(width: 16),
            Expanded(
                child: TextField(
                    controller: mins, decoration: const InputDecoration(labelText: 'Minutes to go'))),
            const SizedBox(width: 16),
            Expanded(
                child: TextField(
                    controller: dest, decoration: const InputDecoration(labelText: 'Destination'))),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start')),
        ],
      ),
    );
    final k = double.tryParse(km.text.replaceAll(',', '.')), m = double.tryParse(mins.text.replaceAll(',', '.'));
    if (ok != true || k == null || m == null || !mounted) return;
    final search = _routeSearch = RouteSearch(km: k, minutes: m, name: dest.text);
    _kmDriven = _minutesGone = 0;
    setState(() {
      _all = true;
      widget.obd.captureAll = true;
      _nav = 'tracking…';
    });
    _route = Timer.periodic(const Duration(seconds: 2), (t) {
      final o = widget.obd;
      search.scan(o.frames, _kmDriven, _minutesGone);
      // The drive since the last scan, from the car's own speed.
      _kmDriven += (o.live ? o.speed : 0) * (o.kph ? 1 : 1.609344) * 2 / 3600;
      _minutesGone += 2 / 60;
      if (_minutesGone >= 20) return _stopNav();
      if (mounted) {
        setState(() => _nav = 'tracking: ${_kmDriven.toStringAsFixed(2)} km driven, '
            '${_minutesGone.toStringAsFixed(1)} min, ${search.ranked.length} fields still fit');
      }
    });
  }

  void _stopNav() {
    _route?.cancel();
    final s = _routeSearch;
    if (s == null) return;
    final top = s.ranked.take(8).toList();
    _nav = [
      'after ${_kmDriven.toStringAsFixed(2)} km and ${_minutesGone.toStringAsFixed(1)} min:',
      if (top.isEmpty) 'no field counted down with the route',
      for (final (i, f) in top.indexed) '${i + 1}. $f',
      if (s.names.isNotEmpty) 'name found in: ${s.names.take(6).join('; ')}' else 'name not found as text',
    ].join('\n');
    if (!mounted) return;
    setState(() {});
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Where the route is'),
        content: SingleChildScrollView(child: SelectableText(_nav)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  String _hex(List<int> b) => b
      .take(64)
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join(' ');

  String _log() => diagReport(widget.obd, widget.bt,
      captureAll: _all,
      extra: 'tyre pressure search:\n${_pressure.isEmpty ? '  (not run)' : _pressure}\n'
          'nav search:\n${_nav.isEmpty ? '  (not run)' : _nav}\n\n'
          'probes:\n${_probes.isEmpty ? '  (not run)' : _probes.map((p) => '  $p').join('\n')}\n\n'
          'ble scan (${_ble.length} devices):\n'
          '${_ble.isEmpty ? '  (not run)' : _ble.values.map((d) => '  $d').join('\n')}\n\n');

  String _id(int id) => _idHex(id);

  @override
  Widget build(BuildContext context) {
    final o = widget.obd;
    final ids = o.frames.keys.toList()..sort();
    final secs = DateTime.now().difference(o.captureStart).inMilliseconds / 1000;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          if (Platform.isAndroid)
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: 'Share the trace log (every second, all drives)',
              onPressed: () async {
                final ok = await shareTrace(_log());
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('No trace log to share')));
                }
              },
            ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy the end of the trace log',
            onPressed: () async {
              // The trace log's end, as much as the clipboard takes.
              var bytes = 240000;
              String text;
              while (true) {
                text = await traceTail(_log(), bytes: bytes);
                try {
                  await Clipboard.setData(ClipboardData(text: text));
                  break;
                } on PlatformException {
                  if (bytes <= 20000) rethrow;
                  bytes ~/= 2;
                }
              }
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Copied the last ${(text.length / 1000).round()} KB of the trace log')));
              }
            },
          ),
        ],
      ),
      // One scroll for the tools and the frames: the tools alone are taller
      // than the landscape screen.
      body: CustomScrollView(slivers: [
        SliverList.list(children: [
          SwitchListTile(
            title: const Text('Capture every CAN id'),
            subtitle: Text('${ids.length} ids, ${o.frameHz} frames/s, '
                '${secs.toStringAsFixed(0)} s'),
            value: _all,
            onChanged: (v) => setState(() {
              _all = v;
              o.captureAll = v;
            }),
          ),
          ListTile(
            title: const Text('Find tyre pressure'),
            subtitle: Text(_pressure.isEmpty
                ? 'Searches every CAN id for the pressure the car shows'
                : _pressure.split('\n').first),
            trailing: _hunt?.isActive ?? false
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.tire_repair),
            onTap: _hunt?.isActive ?? false ? null : _findPressure,
          ),
          ListTile(
            title: Text(_route?.isActive ?? false ? 'Stop nav search' : 'Find nav data'),
            subtitle: Text(_nav.isEmpty
                ? 'Set a route, start here parked, then drive: finds what counts down'
                : _nav.split('\n').first),
            trailing: Icon(_route?.isActive ?? false ? Icons.stop_circle_outlined : Icons.route),
            onTap: _findNav,
          ),
          ListTile(
            title: const Text('Probe Commander ports (1337, 35000, 1338)'),
            subtitle: Text(_probes.isEmpty
                ? 'TCP connect only — like nc -zv. Nothing is sent.'
                : _probes.join('\n')),
            trailing: _probing
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.radar),
            onTap: _probing ? null : _probe,
          ),
          ListTile(
            title: const Text('Scan Bluetooth (10 s)'),
            subtitle: Text(_ble.isEmpty
                ? 'Lists every advertiser; a Tesla is S…C'
                : '${_ble.length} devices, '
                    '${_ble.values.where((d) => RegExp(r'adv="S[0-9a-f]{16}C"').hasMatch(d)).length} Tesla'),
            trailing: _scanning
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.bluetooth_searching),
            onTap: _scanning ? null : _scanBle,
          ),
          const Divider(height: 1),
        ]),
        ids.isEmpty
            ? SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                    child: Text(o.status,
                        style: const TextStyle(color: Colors.white38))))
            : SliverList.builder(
                itemCount: ids.length,
                itemBuilder: (context, i) {
                  final f = o.frames[ids[i]]!;
                  return ListTile(
                    dense: true,
                    leading: Text(_id(ids[i]),
                        style: const TextStyle(
                            fontFamily: 'monospace', color: Colors.white70)),
                    title: Text(f.hex,
                        style: const TextStyle(
                            fontFamily: 'monospace', color: Colors.white38)),
                    trailing: Text(
                        'b${f.bus} ${(f.count / secs).toStringAsFixed(0)} Hz',
                        style: const TextStyle(color: Colors.white30, fontSize: 11)),
                  );
                },
              ),
      ]),
    );
  }
}
