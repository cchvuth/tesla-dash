import 'package:flutter/material.dart';

import 'commander.dart';

/// Car controls the dash's own buttons lack, pressed through the Commander
/// over Bluetooth like the dash's own.
class CarPanel extends StatefulWidget {
  const CarPanel({super.key, this.bt});

  final Commander? bt;

  @override
  State<CarPanel> createState() => _CarPanelState();
}

class _CarPanelState extends State<CarPanel> {
  String _msg = '';
  bool _busy = false;

  Future<void> _press(S3xyAction a) async {
    if (_busy) return;
    final bt = widget.bt;
    if (bt == null || !bt.ready) {
      bt?.kick(ask: true); // look now, and offer to switch Bluetooth on
      setState(() => _msg = 'Commander Bluetooth: ${bt?.status ?? 'off'}');
      return;
    }
    setState(() {
      _busy = true;
      _msg = '${a.label}…';
    });
    try {
      await bt.tryAction(a);
      // The Commander's 0 only means it took the press.
      if (mounted) {
        setState(() => _msg = switch (a) {
              S3xyAction.unlock => '${a.label} sent: unlocks with the driver inside',
              _ => '${a.label} sent',
            });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _msg = a == S3xyAction.climate
            ? '${a.label} failed: $e (needs the Commander linked to the car: ScanMyTesla off)'
            : '${a.label} failed: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('More actions')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _group('Locks', [
              _btn(S3xyAction.unlock, Icons.lock_open),
              _btn(S3xyAction.lock, Icons.lock),
            ]),
            _group('Climate & misc', [
              _btn(S3xyAction.climate, Icons.ac_unit),
              _btn(S3xyAction.flash, Icons.flashlight_on),
              _btn(S3xyAction.honk, Icons.campaign),
            ]),
            Text(_msg, style: const TextStyle(color: Colors.white)),
          ],
        ),
      );

  Widget _group(String title, List<Widget> buttons) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 12, letterSpacing: 2, color: Colors.white70)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: buttons),
        ]),
      );

  Widget _btn(S3xyAction a, IconData icon) => OutlinedButton.icon(
        onPressed: _busy ? null : () => _press(a),
        // White whether or not it can be pressed right now, as on the dash.
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white,
          side: const BorderSide(color: Colors.white70),
        ),
        icon: Icon(icon, size: 18),
        label: Text(a.label),
      );
}
