import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'commander.dart';
import 'panda.dart';
import 'signals.dart';

/// Everything needed to debug the link from the passenger seat: every CAN
/// id the Commander will stream, decoded values, and the trace log.

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
String diagReport(Panda o, Commander? bt) {
    final secs = DateTime.now().difference(o.captureStart).inMilliseconds / 1000;
    final ids = o.frames.keys.toList()..sort();
    final b = StringBuffer()
      ..writeln('tesla-dash diagnostics ${DateTime.now().toIso8601String()}')
      ..writeln('build: ${diagBuild.isEmpty ? 'unknown' : diagBuild}')
      ..writeln('platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('link: ${o.status}, ${o.frameHz} frames/s, capture-all: ${o.captureAll}, '
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

// One write to the trace log at a time, in order, off the UI thread: a slow
// flash write must not cost the dash a frame, and two writers at once would
// land on each other (append seeks once, at open).
Future<void> _traceQueue = Future.value();

/// Adds [text] to the trace log, rolling it to trace.log.1 past 50 MB. A full
/// or missing folder loses the text and nothing else.
Future<void> traceWrite(File f, String text) => _traceQueue = _traceQueue.then((_) async {
      try {
        if (await f.exists() && await f.length() > 50 << 20) await f.rename('${f.path}.1');
        await f.writeAsString(text, mode: FileMode.append);
      } on FileSystemException {
        // skip it
      }
    });

/// The trace log's file; null where there is no folder for it (tests, iOS).
Future<File?> traceLog() async {
  try {
    final dir = await const MethodChannel('tesla_dash/net').invokeMethod<String>('logDir');
    return dir == null ? null : File('$dir/trace.log');
  } on Exception {
    return null;
  }
}

/// Deletes the trace log and its rolled half, after any write already queued.
/// The new log opens with the build, as its "start:" line went with the old one.
Future<bool> clearTrace() async {
  final f = await traceLog();
  if (f == null) return false;
  var ok = true;
  _traceQueue = _traceQueue.then((_) async {
    for (final x in [f, File('${f.path}.1')]) {
      try {
        if (await x.exists()) await x.delete();
      } on FileSystemException {
        ok = false;
      }
    }
  });
  await traceWrite(f, '${DateTime.now().toIso8601String()} cleared: build=$diagBuild\n');
  return ok;
}

/// The trace log with [report] added: the one file the share sheet, Copy log
/// and adb all read. Null where there is none (not Android).
Future<File?> traceExport(String report) async {
  final f = await traceLog();
  if (f == null) return null;
  await traceWrite(f, '${DateTime.now().toIso8601String()} export:\n$report\n');
  return f;
}

/// Opens the share sheet for the trace log, [report] added to its end.
Future<bool> shareTrace(String report) async {
  final f = await traceExport(report);
  if (f == null) return false;
  try {
    return await const MethodChannel('tesla_dash/net').invokeMethod<bool>('shareLog', {'path': f.path}) ?? false;
  } on PlatformException {
    return false;
  }
}

/// The end of a trace log as text, from a whole line; null if it cannot be
/// read. Android's clipboard carries about 1 MB, half a million characters.
String? traceTail(File f, {int bytes = 240000}) {
  try {
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
  } on FileSystemException {
    return null;
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
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    widget.obd.captureAll = false; // give the dash its latency back
    super.dispose();
  }

  Future<void> _clearLog() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear the trace log?'),
        content: const Text('Deletes every drive saved on this phone. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
        ],
      ),
    );
    if (yes != true) return;
    final ok = await clearTrace();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ok ? 'Trace log cleared' : 'Could not clear the trace log')));
    }
  }

  String _log() => diagReport(widget.obd, widget.bt);

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
                      .showSnackBar(const SnackBar(content: Text('Could not share the trace log')));
                }
              },
            ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy the end of the trace log',
            onPressed: () async {
              // The trace log's end, as much as the clipboard takes (240 KB
              // to start with, halved while the phone refuses); just the
              // report where there is no log.
              final report = _log(), f = await traceExport(report);
              for (var bytes = 240000; bytes >= 15000; bytes ~/= 2) {
                final tail = f == null ? null : traceTail(f, bytes: bytes), text = tail ?? report;
                try {
                  await Clipboard.setData(ClipboardData(text: text));
                } on PlatformException {
                  continue;
                }
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(tail == null
                          ? 'Copied the report: no trace log here'
                          : 'Copied the last ${(text.length / 1000).round()} KB of the trace log')));
                }
                return;
              }
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('The phone refused the copy')));
              }
            },
          ),
          if (Platform.isAndroid)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear the trace log',
              onPressed: _clearLog,
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
            value: o.captureAll,
            onChanged: (v) => setState(() => o.captureAll = v),
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
