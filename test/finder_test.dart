import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tesla_dash/finder.dart';
import 'package:tesla_dash/panda.dart';

void main() {
  test('finds the four tyres among other frames', () {
    final frames = <int, Frame>{};
    void add(int id, List<int> data) =>
        (frames[id] ??= Frame(0)).remember(data);
    // 0x25A: FL 2.900, FR 2.850, RL 2.800, RR 2.825 bar = 42, 41, 41, 41 psi.
    add(0x25A, [0x74, 0x72, 0x70, 0x71, 0x00, 0x00]);
    // Unrelated frames, some with a stray 41 or 42 in them.
    add(0x118, [0xA6, 0x29, 0x8D, 0x00, 0x64, 0x2A, 0x00, 0x00]);
    add(0x3F5, [0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00]);
    add(0x33A, [0xCD, 0xAC, 0xB3, 0xDB, 0xFD, 0xFF, 0xE5, 0x68]);
    final hits = findPressure(frames, 40.5, 42.5);
    final top = hits.first;
    expect((top.id, top.code, top.len, top.evidence), (0x25A, '0.025 bar', 8, ('run 0/8', 4)));
    expect(top.toString(), contains('0|8 42.1'));
  });

  test('a page per sensor counts too', () {
    final f = Frame(0);
    // 0x219 pages 0-3: TPMSPressureN 15|9 at 0.025 bar = 116, 114, 112, 113.
    for (final (page, raw) in [(0, 116), (1, 114), (2, 112), (3, 113)]) {
      final word = page | (raw << 15);
      f.remember([for (var i = 0; i < 7; i++) (word >> (8 * i)) & 0xFF]);
    }
    final top = findPressure({0x219: f}, 40.5, 42.5)
        .firstWhere((h) => h.code == '0.025 bar' && h.len == 9);
    expect(top.evidence, ('field 15', 4));
  });

  test('over time the real tyre frame wins, whatever the noise', () {
    for (var seed = 1; seed <= 20; seed++) {
      final rnd = Random(seed);
      final search = PressureSearch(40.5, 42.5);
      final tyres = Frame(0)..remember([0x74, 0x72, 0x70, 0x71, 0x00, 0x00]);
      for (var scan = 0; scan < 10; scan++) {
        // Fresh noise every second, as moving frames give; the tyres hold.
        final frames = <int, Frame>{0x25A: tyres};
        for (var id = 0x100; id < 0x100 + 150; id++) {
          final f = frames[id] = Frame(0);
          for (var k = 0; k < 8; k++) {
            f.remember([for (var i = 0; i < 8; i++) rnd.nextInt(256)]);
          }
        }
        search.scan(frames);
      }
      final (top, seen) = search.ranked.first;
      expect((top.id, top.strength, seen), (0x25A, 4, 10), reason: 'seed $seed');
    }
  });

  test('a drive finds the route fields and the name', () {
    final rnd = Random(3);
    final search = RouteSearch(km: 4.4, minutes: 8, name: 'Sample Destination');
    var km = 0.0, min = 0.0;
    for (var t = 0; t < 120; t++) {
      // 2 s steps at 50 km/h: 0.028 km and 0.033 min a step.
      final frames = <int, Frame>{};
      for (var id = 0x100; id < 0x100 + 60; id++) {
        final f = frames[id] = Frame(0);
        for (var k = 0; k < 4; k++) {
          f.remember([for (var i = 0; i < 8; i++) rnd.nextInt(256)]);
        }
      }
      // 0x3FD page 2: minutes to go 17|10; 0x123: metres to go, 16|16.
      final mins = (8 - min).round(), metres = ((4.4 - km) * 1000).round();
      final w = 2 | (mins << 17);
      frames[0x3FD] = Frame(0)..remember([for (var i = 0; i < 8; i++) (w >> (8 * i)) & 0xFF]);
      frames[0x123] = Frame(1)..remember([0x00, 0x00, metres & 0xFF, metres >> 8, 0, 0, 0, 0]);
      frames[0x400] = Frame(1)..remember('SAMPLE D'.codeUnits);
      search.scan(frames, km, min);
      km += 50 / 3600 * 2;
      min += 2 / 60;
    }
    final top = search.ranked.take(4).toList();
    expect(top.map((f) => f.id), containsAll([0x3FD, 0x123]));
    // Each read the clean way: whole minutes from bit 17, metres from 16.
    // (Small values cannot show a field's full width; its start is enough.)
    final mins = top.firstWhere((f) => f.id == 0x3FD), metres = top.firstWhere((f) => f.id == 0x123);
    expect((mins.page, mins.start, mins.code), (2, 17, 'min'));
    expect((metres.start, metres.code), (16, 'm'));
    expect(search.names.any((n) => n.startsWith('0x400')), isTrue);
  });
}
