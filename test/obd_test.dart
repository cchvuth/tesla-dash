import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tesla_dash/panda.dart';
import 'package:tesla_dash/signals.dart';

/// Builds one 16-byte panda record the way the Commander sends it.
Uint8List record(int id, List<int> data, {int bus = 0}) {
  final b = ByteData(16);
  b.setUint32(0, id << 21, Endian.little);
  b.setUint32(4, (bus << 4) | data.length, Endian.little);
  for (var i = 0; i < data.length; i++) {
    b.setUint8(8 + i, data[i]);
  }
  return b.buffer.asUint8List();
}

void main() {
  test('panda records unpack into frames by id and bus', () {
    final p = Panda()
      ..onPacket(Uint8List.fromList([
        ...record(0x257, [1, 2, 3, 4, 5, 6, 7, 8], bus: 1),
        ...record(0x118, [9, 9]),
      ]));
    expect((p.frames[0x257]?.bus, p.frames[0x257]?.hex), (1, '01 02 03 04 05 06 07 08'));
    expect(p.frames[0x118]?.hex, '09 09');
  });

  test('decodes little-endian signals', () {
    // Second byte, straight through.
    expect(decode(const Sig(0, 8, 8), [0x00, 0x2A]), 42);
    // 12 bits straddling a byte boundary: 0x123 starting at bit 4.
    expect(decode(const Sig(0, 4, 12), [0x30, 0x12]), 0x123);
    // Signed wraps below zero.
    expect(decode(const Sig(0, 0, 8, signed: true), [0xFF]), -1);
    // Scale and offset applied after.
    expect(decode(const Sig(0, 0, 8, scale: 0.5, offset: -10), [0x14]), 0);
    // Too short for the signal.
    expect(decode(const Sig(0, 0, 16), [0x01]), isNull);
    // Not-available is null, never a plausible-looking number.
    expect(decode(const Sig(0, 0, 8, sna: 255), [0xFF]), isNull);
  });

  test('decodes real Tesla signals', () {
    // DI_uiSpeed 24|9: byte 3 plus one bit of byte 4.
    expect(decode(kSignals['speed']!, [0, 0, 0, 0x64, 0, 0, 0, 0]), 100);
    expect(decode(kSignals['speed']!, [0, 0, 0, 0x2C, 0x01, 0, 0, 0]), 300);
    // SNA 511 must not render as a speed.
    expect(decode(kSignals['speed']!, [0, 0, 0, 0xFF, 0x01, 0, 0, 0]), isNull);

    // 0x33A as captured from the car: 205 mi range, 59 % on the screen.
    final rangeSoc = [0xCD, 0xAC, 0xB3, 0xDB, 0xFD, 0xFF, 0xE5, 0x68];
    expect(decode(kSignals['rangeMi']!, rangeSoc), 205);
    expect(decode(kSignals['soc']!, rangeSoc), 59);

    // DI_gear 21|3 = 4 (D), DI_accelPedalPos 32|8 (0.4) = 0x64 -> 40%.
    final driving = [0, 0, 0x80, 0, 0x64, 0, 0, 0];
    expect(kGears[decode(kSignals['gear']!, driving)!.round()], 'D');
    expect(decode(kSignals['pedal']!, driving), closeTo(40, 0.001));
    // DI_brakePedalState 19|2: byte 2 = gear << 5 | brake << 3 | state.
    // INVALID must decode, not be skipped, or the last ON sticks.
    expect(decode(kSignals['brake']!, [0xA6, 0, 0x8D, 0, 0, 0, 0, 0]), 1); // D, ON
    expect(decode(kSignals['brake']!, [0x4E, 3, 0x32, 0, 0, 0, 0, 0]), 2); // P, INVALID

    // RearPower266 0|11 signed (0.5): -100 raw -> -50 kW of regen.
    final regen = [0x9C, 0x07, 0, 0, 0, 0, 0, 0]; // 11-bit two's complement
    expect(decode(kSignals['rearKw']!, regen), -50);

    // 0x332 payload 1: max brick 3.900 V (raw 1950 at bit 2), min 3.888 V
    // (raw 1944 at bit 16). Payload 0 carries temperatures instead.
    final bricks = [0x79, 0x1E, 0x98, 0x07, 0, 0];
    expect(decode(kSignals['cellVMax']!, bricks), closeTo(3.900, 1e-9));
    expect(decode(kSignals['cellVMin']!, bricks), closeTo(3.888, 1e-9));
    expect(decode(kSignals['cellVMax']!, [0x78, 0x1E, 0x98, 0x07, 0, 0]), isNull);

    // 0x352 payload 0: nominal full pack 78.5 kWh (raw 3925 at bit 16).
    final energy = [0x00, 0, 0x55, 0x0F, 0, 0, 0, 0];
    expect(decode(kSignals['packKwh']!, energy), closeTo(78.5, 1e-9));
    expect(decode(kSignals['packKwh']!, [0x01, 0, 0x55, 0x0F, 0, 0, 0, 0]), isNull);

    // 0x392 payload 1: pack new 78.8 kWh (raw 788 at bit 40). Payload 0 and
    // SNA (all ones) are not a figure.
    expect(decode(kSignals['packNewKwh']!, [0x01, 0, 0, 0, 0, 0x14, 0x03, 0]), closeTo(78.8, 1e-9));
    expect(decode(kSignals['packNewKwh']!, [0x00, 0, 0, 0, 0, 0x14, 0x03, 0]), isNull);
    expect(decode(kSignals['packNewKwh']!, [0x01, 0, 0, 0, 0, 0xFF, 0x03, 0]), isNull);

    // 0x273: dome light 59|2 ON (byte 7 = 0x08), AUTO (0x10).
    expect(kDome[decode(kSignals['domeLight']!, [0, 0, 0, 0, 0, 0, 0, 0x08])!.round()], 'ON');
    expect(kDome[decode(kSignals['domeLight']!, [0, 0, 0, 0, 0, 0, 0, 0x10])!.round()], 'AUTO');
  });

  test('button states: air, charge port, mirror tilt', () {
    // 0x243 page 0: byte 6 = power ON (1 << 3) | RECIRC (1); page 1: door
    // 63 * 1.6 %.
    expect(kRecirc[decode(kSignals['recirc']!, [0, 0, 0, 0, 0, 0, 0x09, 0])!.round()], 'RECIRC');
    expect(decode(kSignals['hvacPower']!, [0, 0, 0, 0, 0, 0, 0x09, 0]), 1);
    expect(kRecirc[decode(kSignals['recirc']!, [0, 0, 0, 0, 0, 0, 0x02, 0])!.round()], 'FRESH');
    expect(decode(kSignals['recircPct']!, [0x01, 0xFC, 0, 0, 0, 0, 0, 0]), closeTo(100.8, 1e-9));
    expect(decode(kSignals['recirc']!, [0x01, 0xFC, 0, 0, 0, 0, 0, 0]), isNull);
    // 0x25D: a real Juniper's static shut payload, and the same with the
    // door open (bit 6).
    expect(decode(kSignals['chargePort']!, [0x37, 0x41, 0x01, 0x06, 0x04, 0xF0, 0xCA, 0x03]), 0);
    expect(decode(kSignals['chargePort']!, [0x77, 0x44, 0x01, 0x86, 0x04, 0xF0, 0xCA, 0x03]), 1);
    // 0x273 byte 6: 0x20 is Mirror Auto Tilt; 0x1F is only its neighbours.
    expect(decode(kSignals['tiltAuto']!, [0, 0, 0, 0, 0, 0, 0x20, 0]), 1);
    expect(decode(kSignals['tiltAuto']!, [0, 0, 0, 0, 0, 0, 0x1F, 0]), 0);
  });

  test('Panda holds nothing stale and picks the right source', () {
    final p = Panda();
    // Stopped in D on the brake, then the auto-park's P with INVALID.
    p.onFrame(0x118, 0, [0xA6, 0, 0x8D, 0, 0, 0, 0, 0]);
    expect(p.braking, isTrue);
    p.onFrame(0x118, 0, [0x4E, 3, 0x32, 0, 0, 0, 0, 0]);
    expect(p.braking, isFalse);
    // INVALID in D clears it too; a press in P never lights it.
    p.onFrame(0x118, 0, [0, 0, 0x88, 0, 0, 0, 0, 0]);
    expect(p.braking, isTrue);
    p.onFrame(0x118, 0, [0, 0, 0x90, 0, 0, 0, 0, 0]);
    expect(p.braking, isFalse);
    p.onFrame(0x118, 0, [0, 0, 0x28, 0, 0, 0, 0, 0]);
    expect(p.braking, isFalse);

    // Tyres: 0x25A until 0x219 page 5 has a reading; an empty page 5 never
    // blanks a value, and page 5 wins once it has one.
    p.onFrame(0x25A, 0, [0x74, 0x72, 0x70, 0x71, 0, 0]);
    expect(p.tpFL, closeTo(2.9, 1e-9));
    p.onFrame(0x219, 0, [0x05, 0, 0, 0, 0, 0, 0]);
    expect(p.tpFL, closeTo(2.9, 1e-9));
    p.onFrame(0x219, 0, [0x05, 0, 0x6F, 0x6E, 0x72, 0x70, 0]);
    expect(p.tpFL, closeTo(2.775, 1e-9));
    p.onFrame(0x25A, 0, [0x74, 0x72, 0x70, 0x71, 0, 0]);
    expect(p.tpFL, closeTo(2.775, 1e-9));
    // The chassis bus's 3-byte 0x219 (counter, checksum) is not page 5.
    final c = Panda();
    c.onFrame(0x219, 1, [0x9D, 0x79, 0x31]);
    c.onFrame(0x25A, 0, [0x70, 0x70, 0x6F, 0x6E, 0, 0]);
    expect(c.tpFL, closeTo(2.8, 1e-9));
    // Per wheel: a page 5 with only FL leaves the others to 0x25A.
    final q = Panda();
    q.onFrame(0x219, 0, [0x05, 0, 0x6F, 0, 0, 0, 0]);
    q.onFrame(0x25A, 0, [0x74, 0x72, 0x70, 0x71, 0, 0]);
    expect(q.tpFL, closeTo(2.775, 1e-9));
    expect(q.tpFR, closeTo(2.85, 1e-9));

    // Recirculation lights above 60 % and goes out below 40 %.
    p.onFrame(0x243, 0, [0x01, 0xFC, 0, 0, 0, 0, 0, 0]);
    expect(p.recircOn, isTrue);
    p.onFrame(0x243, 0, [0x01, 0x7C, 0, 0, 0, 0, 0, 0]); // 49.6 %
    expect(p.recircOn, isTrue);
    p.onFrame(0x243, 0, [0x01, 0x40, 0, 0, 0, 0, 0, 0]); // 25.6 %
    expect(p.recircOn, isFalse);

    // Charge port: only 8-byte frames count.
    p.onFrame(0x25D, 0, [0x77, 0x44, 0x01, 0x86, 0x04, 0xF0, 0xCA, 0x03]);
    expect(p.chargePort, isTrue);
    p.onFrame(0x25D, 1, [0x37, 0, 0, 0, 0, 0]);
    expect(p.chargePort, isTrue);
    p.onFrame(0x25D, 0, [0x37, 0x41, 0x01, 0x06, 0x04, 0xF0, 0xCA, 0x03]);
    expect(p.chargePort, isFalse);

    // Lights: headlights on keeps the light bar (DRL) lit; the high-beam
    // lamps light HIGH without the stalk bits.
    p.onFrame(0x3F5, 0, [0, 0, 0, 0, 0x04, 0, 0, 0]);
    expect((p.lowBeam, p.drl, p.highBeam), (true, true, false));
    p.onFrame(0x3F6, 0, [0x50, 0, 0, 0, 0, 0, 0, 0]);
    expect(p.highBeam, isTrue);
    p.onFrame(0x3F6, 0, [0x00, 0, 0, 0, 0, 0, 0, 0]);
    p.onFrame(0x3F5, 0, [0, 0, 0, 0, 0x02, 0, 0, 0]); // daylight
    expect((p.lowBeam, p.drl, p.highBeam), (false, true, false));
    p.onFrame(0x3F5, 0, [0, 0, 0, 0, 0x0F, 0, 0, 0]); // SNA
    expect((p.lowBeam, p.drl), (null, null));

    // Map lights: 7-byte vehicle-bus frames only; any of the four lights it.
    p.onFrame(0x3E2, 0, [0x40, 0x15, 0, 0, 0, 0, 0]);
    expect(p.mapLight, isTrue);
    p.onFrame(0x3E2, 1, [0x00, 0x00, 0, 0, 0, 0, 0, 0]);
    expect(p.mapLight, isTrue);
    p.onFrame(0x3E2, 0, [0x00, 0x10, 0, 0, 0, 0, 0]); // RR on
    expect(p.mapLight, isTrue);
    p.onFrame(0x3E2, 0, [0x00, 0x00, 0, 0, 0, 0, 0]);
    expect(p.mapLight, isFalse);

    // Third-row belts arrive in payload 1; SNA clears a seat.
    p.onFrame(0x3A1, 0, [0x05, 0, 0, 0, 0, 0, 0, 0]);
    expect((p.belt3L, p.belt3R), (true, false));
    p.onFrame(0x3A1, 0, [0x09, 0, 0, 0, 0, 0, 0, 0]);
    expect(p.belt3L, isFalse);
  });

  test('driver-assist and lighting signals from a real capture', () {
    // 0x399 parked: autopilot UNAVAILABLE (1), no blind-spot warnings, limit 50.
    final das = [0x01, 0x0A, 0xDF, 0xE0, 0xB0, 0x08, 0x51, 0x6F];
    expect(kAutopilot[decode(kSignals['autopilot']!, das)!.round()], isNull);
    expect(decode(kSignals['blindL']!, das), 0);
    expect(decode(kSignals['blindR']!, das), 0);
    expect(decode(kSignals['speedLimit']!, das), 50);
    // Autopilot engaged + left blind-spot warning.
    expect(kAutopilot[decode(kSignals['autopilot']!, [0x13])!.round()], 'AUTOPILOT');
    expect(decode(kSignals['blindL']!, [0x13]), 1);
    expect(decode(kSignals['blindL']!, [0x33]), 3); // SNA, read as no warning
    // 0x102 bit 63, VCLEFT_mirrorDipped.
    expect(decode(kSignals['mirrorDipped']!, [0x22, 0, 0, 0, 0, 0, 0, 0x80]), 1);
    expect(decode(kSignals['mirrorDipped']!, [0x22, 0, 0, 0, 0, 0, 0, 0x7F]), 0);
    // 0x3F5: left indicator lit (2), right off.
    expect(decode(kSignals['indL']!, [0x02]), 2);
    expect(decode(kSignals['indR']!, [0x02]), 0);
    // 0x219 payload 5: 116 * 0.025 = 2.9 bar front-left, 2.8 rear-right;
    // other payloads are per sensor, and 255 is not available.
    final tyres = [0x05, 0, 116, 0, 0, 112, 0];
    expect(decode(kSignals['tpFL']!, tyres), closeTo(2.9, 0.001));
    expect(decode(kSignals['tpRR']!, tyres), closeTo(2.8, 0.001));
    expect(decode(kSignals['tpFL']!, [0x00, 0, 116, 0, 0, 112, 0]), isNull);
    expect(decode(kSignals['tpFL']!, [0x05, 0, 0xFF, 0, 0, 0, 0]), isNull);
    // 0x3A1 live, belted: payload 0 (1-bit mux) with the windscreen camera
    // heater on in the bits above it. Payload 1 is PCS current, not belts.
    final vs4 = [0xE4, 0x42, 0x00, 0xCA, 0x00, 0x44, 0x22, 0x6A];
    expect(decode(kSignals['beltDriver']!, vs4), 0);
    expect(decode(kSignals['beltPass']!, vs4), 0);
    expect(decode(kSignals['beltDriver']!, [0xE0, 0x42, 0x00, 0xCA, 0x01, 0x44, 0x22, 0x6A]), 1);
    expect(decode(kSignals['beltDriver']!, [0xE5, 0x42, 0x00, 0xCA, 0x01, 0x44, 0x22, 0x6A]), isNull);
    // Payload 1: byte 0 = 1 | 3L << 2 | 3R << 4. SNA now decodes, to clear.
    expect(decode(kSignals['belt3L']!, [0x05, 0, 0, 0, 0, 0, 0, 0]), 1);
    expect(decode(kSignals['belt3R']!, [0x11, 0, 0, 0, 0, 0, 0, 0]), 1);
    expect(decode(kSignals['belt3L']!, vs4), isNull);
    expect(decode(kSignals['belt2L']!, [0, 0, 0, 0, 0x20, 0, 0, 0]), 2);
    // 0x3F6: high-beam lamps 4|4, left | right << 2.
    expect(decode(kSignals['highLamp']!, [0x50, 0, 0, 0, 0, 0, 0, 0]), 5);
    // 0x3E2: map lights FL/FR/RL/RR at 6|2, 8|2, 10|2, 12|2, all ON.
    expect(decode(kSignals['mapLights']!, [0x40, 0x15, 0, 0, 0, 0, 0]), 85);
    // 0x25A: the tyre screen's pressures, 0.025 bar.
    expect(decode(kSignals['tdFL']!, [0x74, 0x72, 0x70, 0x71, 0, 0]), closeTo(2.9, 1e-9));
    expect(decode(kSignals['tdRR']!, [0x74, 0x72, 0x70, 0x71, 0, 0]), closeTo(2.825, 1e-9));
    // 0x3F5 lightingCoreState 32|4: 4 LOW_BEAMS, 2 DRL; 36|2 high-beam flash/latch.
    expect(decode(kSignals['lowBeam']!, [0, 0, 0, 0, 0x04]), 4);
    expect(decode(kSignals['drl']!, [0, 0, 0, 0, 0x02]), 2);
    expect(decode(kSignals['highBeam']!, [0, 0, 0, 0, 0x20]), 2);
    // Inverter power SNA (raw 1024) is no value, not -512 kW.
    expect(decode(kSignals['frontKw']!, [0x00, 0x04]), isNull);
    // 0x238 parked, no route (country SNA): UI_navRouteActive (bit 29) clear.
    final map = [0xB0, 0x27, 0xFF, 0xDB, 0x1F, 0x00, 0x16, 0x20];
    expect(decode(kSignals['navRoute']!, map), 0);
    expect(decode(kSignals['navRoute']!, [0, 0, 0, 0x20, 0, 0, 0, 0]), 1);
    // 0x347 idle on 2026 firmware (dashkit's capture): no route, energy SNA.
    final trip = [0x00, 0x7F, 0xFF, 0x80, 0xFF, 0x03, 0x00, 0x80];
    expect(decode(kSignals['navEnergyKwh']!, trip), closeTo(-327.68, 1e-9));
    expect(decode(kSignals['navEnergyKwh']!, [1, 0, 0, 0, 0, 0, 0x44, 0x0C]), closeTo(31.4, 1e-9));
    // 0x3FD page 2: UI_navMinutesToArrival 17|10 = 16 min; other pages none.
    expect(decode(kSignals['navMinutes']!, [0x02, 0x00, 0x20, 0, 0, 0, 0, 0x80]), 16);
    expect(decode(kSignals['navMinutes']!, [0x00, 0x00, 0x20, 0, 0, 0, 0, 0x80]), isNull);
  });

  testWidgets('indicator strips keep step with the car\'s flasher', (t) async {
    final p = Panda();
    p.onFrame(0x3F5, 0, [0x02, 0, 0, 0, 0, 0, 0, 0]); // left lamp lit
    expect((p.indL, p.blinkLit), (true, true));
    await t.pump(const Duration(milliseconds: 200));
    p.onFrame(0x3F5, 0, [0x01, 0, 0, 0, 0, 0, 0, 0]); // dark half reported
    expect(p.blinkLit, isTrue); // the local half cycle decides, smoothly
    await t.pump(const Duration(milliseconds: 200));
    expect(p.blinkLit, isFalse);
    p.onFrame(0x3F5, 0, [0x0A, 0, 0, 0, 0, 0, 0, 0]); // hazards: both lit
    expect((p.indL, p.indR, p.blinkLit), (true, true, true));
    p.onFrame(0x3F5, 0, [0x00, 0, 0, 0, 0, 0, 0, 0]); // stopped
    expect((p.indL, p.indR, p.blinkLit), (false, false, false));
    // Straight from left to right: the right lamp's first flash still lights.
    p.onFrame(0x3F5, 0, [0x02, 0, 0, 0, 0, 0, 0, 0]);
    await t.pump(const Duration(milliseconds: 400));
    expect(p.blinkLit, isFalse);
    p.onFrame(0x3F5, 0, [0x08, 0, 0, 0, 0, 0, 0, 0]);
    expect((p.indL, p.indR, p.blinkLit), (false, true, true));
    p.onFrame(0x3F5, 0, [0x00, 0, 0, 0, 0, 0, 0, 0]);
    await t.pump(const Duration(seconds: 1)); // no timer left behind
  });

  // Parked with a route set, a capture from the car: the screen
  // said 60 %, 309 km and 8 min to a 4.4 km destination.
  test('arrival % and route length from the battery frames', () {
    final p = Panda()..kph = true;
    p.onFrame(0x352, 0, [0x00, 0x80, 0xF8, 0x0F, 0xE3, 0x09, 0xD1, 0x09]); // full, left
    p.onFrame(0x352, 0, [0x01, 0x80, 0x70, 0x01, 0xD1, 0x09, 0x00, 0x00]); // buffer
    p.onFrame(0x347, 0, [0x01, 0x7F, 0xFF, 0x0D, 0xFF, 0x03, 0x50, 0x13]); // at arrival
    p.onFrame(0x33A, 0, [0xC0, 0xF8, 0xC3, 0xE3, 0xFD, 0xFF, 0xE5, 0x68]); // 192 mi
    expect(p.packKwh, closeTo(81.76, 0.001));
    expect(p.packLeftKwh, closeTo(50.62, 0.001));
    expect(p.packBufferKwh, closeTo(3.68, 0.001));
    expect(p.navEnergyKwh, closeTo(49.44, 0.001));
    expect(p.arrivePct, closeTo(58.61, 0.01));
    expect(p.rangeAt(p.arrivePct), closeTo(301.22, 0.01)); // km, 309 now
    // The 8 km of range the route uses, at the energy per km now: the
    // pack's energy now less the car's at arrival.
    expect(p.tripKwh(p.arrivePct), closeTo(50.62 - 49.44, 0.001));
    expect(p.tripKwh(null), isNull);
  });

  test('Bluetooth stands in for WiFi, WiFi first', () async {
    final p = Panda()..kph = true;
    expect(p.live, isFalse);
    // A lean session's route and recirculation are no car data: not live.
    p.fromBt({7: 31.1, 101: 1});
    expect(p.live, isFalse);
    // A Commander push as the parser hands it over: the car's raw codes,
    // sint32 zigzagged (62 is +31, 399 is -200).
    p.fromBt({61: 87, 62: 125, 66: 4, 65: 1, 63: 2, 51: 62, 53: 399, 111: 60, 112: 192, 105: 1,
        110: 90, 81: 0x11, 82: 0x33, 85: 0x10, 113: 1, 118: 2, 34: 800, 35: 4088,
        36: 2531, 37: 368, 43: 1950, 44: 1948});
    expect((p.viaBt, p.live, p.wifiLive), (true, true, false));
    expect((p.speed, p.pedalPct, p.gear, p.braking), (87, 50, 'D', true));
    expect((p.indL, p.indR, p.blinkLit), (true, false, true));
    expect((p.frontKw, p.rearKw, p.socPct, p.rangeMi, p.speedLimit), (15.5, -100, 60, 192, 90));
    expect((p.lowBeam, p.highBeam, p.drl), (true, false, true)); // 0x33: SNA, off
    expect((p.doorFL, p.trunk, p.parked, p.autopilot), (true, false, false, 'TACC'));
    expect(p.packKwh, closeTo(81.76, 1e-9));
    expect(p.packNewKwh, closeTo(80, 1e-9));
    expect(p.imbalanceMv, closeTo(4, 1e-6));
    // The car's own 58.61 % at arrival gives the range the bus would.
    expect(p.rangeAt(58.61), closeTo(301.2, 0.1));

    // Pushes carry what changed; the rest holds, as it does through SNA.
    p.fromBt({66: 1, 113: 0, 62: 255, 51: 2047});
    expect((p.gear, p.speed, p.parked), ('P', 87, true));
    expect((p.doorFL, p.pedalPct, p.frontKw), (true, 50, 15.5));

    // WiFi live: pushes wait. WiFi gone: they take over at once.
    p.status = 'live';
    p.fromBt({61: 10});
    expect(p.speed, 87);
    await p.disconnect();
    expect((p.speed, p.gear, p.viaBt), (10, 'P', true));

    // The Bluetooth link gone too: nothing it showed stays.
    p.fromBt(null);
    expect((p.live, p.gear, p.doorFL, p.frontKw), (false, '—', false, null));
  });

  test('the newer stats decode a capture from the car as the catalog says', () {
    final p = Panda()..kph = true;
    // One frame of each as the car sent them: parked, plugged
    // in with charging complete, climate on, a route set.
    p.onFrame(0x321, 0, [0x76, 0xF9, 0x25, 0x5F, 0x02, 0x5F, 0xC0, 0x38]);
    p.onFrame(0x2B6, 0, [0x88, 0x0D, 0x02]);
    p.onFrame(0x252, 0, [0x18, 0x18, 0x25, 0x06, 0x3A, 0x51, 0x18, 0x00]);
    p.onFrame(0x2B3, 0, [0xE9, 0x5D, 0xF0, 0x4F, 0x63, 0x00, 0x06, 0x03]);
    p.onFrame(0x212, 0, [0x19, 0x24, 0x00, 0x40, 0x13, 0x2D, 0x60, 0x86]);
    p.onFrame(0x472, 0, [0x71, 0x00, 0x00, 0x00, 0x48, 0x7F, 0xFF, 0x07]);
    p.onFrame(0x333, 0, [0x00, 0x10, 0x58, 0x06, 0x00]);
    p.onFrame(0x33B, 0, [0x34, 0x00, 0x00, 0x00, 0xFF, 0x07]);
    p.onFrame(0x286, 0, [0xAE, 0x04, 0x00, 0x61, 0xC0, 0x01, 0x00, 0x00]);
    p.onFrame(0x3F8, 0, [0x03, 0x08, 0x08, 0x00, 0x59, 0x3D, 0x94, 0x20]);
    p.onFrame(0x2F3, 0, [0x09, 0x09, 0x2B, 0x24, 0x00, 0x60, 0x00, 0x42]);
    p.onFrame(0x332, 0, [0x04, 0x05, 0x60, 0x5F, 0x60, 0x00]);
    p.onFrame(0x3A1, 0, [0xE4, 0x42, 0x00, 0x8A, 0x01, 0x44, 0x62, 0xFB]);
    p.onFrame(0x347, 0, [0x01, 0x7F, 0xFF, 0x0D, 0xFF, 0x03, 0x50, 0x13]);
    p.onFrame(0x399, 0, [0x00, 0x0A, 0xFF, 0xE0, 0xB0, 0xC8, 0x87, 0x84]);
    p.onFrame(0x118, 0, [0xAF, 0x8D, 0x31, 0x10, 0x00, 0x48, 0x00, 0x80]);
    expect((p.outsideC, p.washerLow), (7.5, false));
    expect((p.slippery, p.gripHeld, p.tcMode), (false, false, null));
    expect(p.regenMaxKw, closeTo(61.68, 1e-9));
    expect(p.co2ppm, 935);
    expect((p.charging, p.chargeKw, p.chargeMaxKw, p.chargeWhy), (false, 0, 11.25, null));
    expect((p.chargeLimitPct, p.chargeMinutes), (60, 0));
    // Climate on, the front fan on Auto at Auto's lowest level (raw 0,
    // VERY_LOW) and the second row's off.
    expect((p.cruiseSet, p.followGap, p.fan1, p.fan2), (null, 2, 'LOW', 'OFF'));
    expect((p.packTempC, p.packHeating, p.precondC), (7.5, false, null));
    expect(p.handsOn, 2);

    // The buckles, from the car's logs: the driver in the seat
    // unbuckled (the chime) with every other buckle open; then buckled.
    p.onFrame(0x3C2, 0, [0x00, 0x55, 0x55, 0x55, 0x00, 0x00, 0x59, 0x41]);
    p.onFrame(0x31A, 0, [0x60, 0x00, 0x70, 0x18, 0x00, 0x00, 0xD0, 0xD5]);
    expect(p.beltDriver, isTrue);
    expect(p.buckled, isEmpty);
    p.onFrame(0x3C2, 0, [0x00, 0x55, 0x55, 0x55, 0x00, 0x00, 0x5A, 0x41]);
    expect(p.buckled, {'D'});
  });

  test('buckles and fans', () async {
    final p = Panda();
    // Every belt buckled: the left controller's switches ON (page 0), the
    // right one's buckles LATCHED, its second-row centre NOT_CONFIGURED.
    p.onFrame(0x3C2, 0, [0x00, 0x55, 0x55, 0x55, 0x00, 0x00, 0x6A, 0x81]);
    p.onFrame(0x31A, 0, [0x68, 0x51, 0x70, 0x18, 0x00, 0x00, 0x00, 0x00]);
    expect(p.buckled, {'D', 'P', '2L', '2C', '2R', '3L', '3R'});
    // Page 1 carries none the dash reads (its third-row left switch is SNA
    // on this car): nothing changes.
    p.onFrame(0x3C2, 0, [0x01, 0, 0, 0, 0, 0, 0, 0]);
    expect(p.buckled, hasLength(7));
    // One seat of each pair, so a seat swapped for its neighbour shows: 2L
    // in, 2C out; 2R in, P out; 3R in, 3L out.
    p.onFrame(0x3C2, 0, [0x00, 0x55, 0x55, 0x55, 0x00, 0x00, 0x6A, 0x41]);
    p.onFrame(0x31A, 0, [0x60, 0x41, 0x70, 0x18, 0x00, 0x00, 0x00, 0x00]);
    expect(p.buckled, {'D', '2L', '2R', '3R'});
    p.onFrame(0x3C2, 0, [0x00, 0x55, 0x55, 0x55, 0x00, 0x00, 0x6A, 0x81]);
    p.onFrame(0x31A, 0, [0x68, 0x51, 0x70, 0x18, 0x00, 0x00, 0x00, 0x00]);
    // The passenger unbuckles; a faulted buckle is not a buckled one.
    p.onFrame(0x31A, 0, [0x60, 0x52, 0x70, 0x18, 0x00, 0x00, 0x00, 0x00]);
    expect(p.buckled, {'D', '2L', '2C', '3L', '3R'});

    // The front fan at 4 and the second row's on HIGH; then climate off,
    // which stops both whatever they are set to.
    p.onFrame(0x2F3, 0, [0x09, 0x09, 0x24, 0x84, 0x00, 0x60, 0x00, 0x42]);
    expect((p.fan1, p.fan2), ('4', 'HIGH'));
    // On Auto, Auto's level (5|3): MEDIUM reads MED, VERY_HIGH reads HIGH.
    p.onFrame(0x2F3, 0, [0x49, 0x09, 0x2B, 0x24, 0x00, 0x60, 0x00, 0x42]);
    expect((p.fan1, p.autoBlower), ('MED', 2));
    p.onFrame(0x2F3, 0, [0x89, 0x09, 0x2B, 0x24, 0x00, 0x60, 0x00, 0x42]);
    expect((p.fan1, p.autoBlower), ('HIGH', 4));
    // The second row on Auto (29|3 = 0) follows the same level.
    p.onFrame(0x2F3, 0, [0x49, 0x09, 0x2B, 0x04, 0x00, 0x60, 0x00, 0x42]);
    expect((p.fan1, p.fan2), ('MED', 'MED'));
    p.onFrame(0x2F3, 0, [0x09, 0x09, 0x2B, 0x00, 0x00, 0x60, 0x00, 0x42]);
    expect((p.fan1, p.fan2), ('OFF', 'OFF'));

    // The link gone: no seat stays green, no fan shown.
    await p.disconnect();
    expect((p.buckled.isEmpty, p.fan1, p.fan2), (true, null, null));
  });

  test('g-forces: along from the drive unit, across from yaw rate and speed', () {
    final p = Panda()..kph = true;
    void along(List<int> b, [int n = 40]) {
      for (var i = 0; i < n; i++) {
        p.onFrame(0x118, 0, [0, 0, 0, 0, 0, 0, b[0], b[1]]);
      }
    }
    // 52|12 signed, 0.01 m/s²: +2.00 (raw 200), then -3.00 (raw 0xED4).
    along([0x80, 0x0C]);
    expect(p.gLong, closeTo(2.00 / 9.80665, 1e-3));
    along([0x40, 0xED]);
    expect(p.gLong, closeTo(-3.00 / 9.80665, 1e-3));
    expect(p.gMaxAccel, closeTo(0.204, 1e-3));
    expect(p.gMaxBrake, closeTo(0.306, 1e-3));
    // SNA (raw 2048) changes nothing.
    along([0x00, 0x80], 1);
    expect(p.gLong, closeTo(-0.306, 1e-3));
    // 0.1 rad/s left at 72 km/h (20 m/s): 2 m/s² across.
    p.speed = 72;
    for (var i = 0; i < 40; i++) {
      p.onFrame(0x101, 0, [0xE8, 0x03, 0, 0, 0, 0, 0, 0]);
    }
    expect(p.gLat, closeTo(2.0 / 9.80665, 1e-3));
    expect(p.gMaxLat, closeTo(0.204, 1e-3));
    // Leaving P starts a new drive: the peaks go. (Parked, the car sends
    // no acceleration: SNA.)
    p.onFrame(0x118, 0, [0, 0, 0x20, 0, 0, 0, 0x00, 0x80]); // P
    p.onFrame(0x118, 0, [0, 0, 0x80, 0, 0, 0, 0x00, 0x80]); // D
    expect([p.gMaxAccel, p.gMaxBrake, p.gMaxLat], [0, 0, 0]);
  });

  test('the newer stats: held, combined, over Bluetooth, gone with the link', () async {
    final p = Panda()..kph = true;
    // Stability control flashes once: GRIP holds it for a glance.
    p.onFrame(0x2B6, 0, [0x01, 0x00, 0x00]);
    expect(p.gripHeld, isTrue);
    p.onFrame(0x2B6, 0, [0x00, 0x00, 0x00]);
    expect(p.gripHeld, isTrue);
    // Lit only while moving: stopped in D the car raises it with nothing
    // slipping.
    expect(p.gripLit, isFalse);
    p.speed = 30;
    expect(p.gripLit, isTrue);
    p.speed = 0;
    // Traction mode 7 is the car's slippery verdict too; Slip Start is named.
    p.onFrame(0x118, 0, [0, 0, 0, 0, 0, 0x07, 0, 0]);
    expect((p.slippery, p.tcMode), (true, null));
    p.onFrame(0x118, 0, [0, 0, 0, 0, 0, 0x01, 0, 0]);
    expect((p.slippery, p.tcMode), (false, 'SLIP'));
    // Cruise enabled at 110 km/h, in km/h.
    p.onFrame(0x286, 0, [0x00, 0x20, 0x6E, 0x01, 0, 0, 0, 0]);
    expect(p.cruiseSet, 110);
    // Charging at 48 kW of 62, held back by a cold pack, 35 minutes to go.
    p.onFrame(0x212, 0, [0x00, 0x18, 0xF0, 0x00, 0x00, 0xF8, 0x00, 0x00]);
    p.onFrame(0x472, 0, [0, 0, 0, 0, 0x02, 0, 0, 0]);
    p.onFrame(0x33B, 0, [0, 0, 35, 0, 0, 0]);
    expect((p.charging, p.chargeKw, p.chargeMaxKw, p.chargeWhy, p.chargeMinutes),
        (true, 48, 62, 'COLD PACK', 35));
    // Heating the pack for a charger on the route, to 45 °C.
    p.onFrame(0x347, 0, [0x20, 0x00, 0xB4, 0x00, 0x00, 0x00, 0x50, 0x13]);
    expect((p.packHeating, p.precondC), (true, 45));
    // The nag's SNA clears it rather than holding the last level.
    p.onFrame(0x399, 0, [0, 0, 0, 0, 0, 0x10, 0, 0]);
    expect(p.handsOn, 4);
    p.onFrame(0x399, 0, [0, 0, 0, 0, 0, 0x3C, 0, 0]);
    expect(p.handsOn, isNull);

    // Without WiFi, the Commander's: -3 °C out, 24 kW regen, the coldest
    // cells at 3.5 °C and heating, the nag chiming (sint32 zigzagged).
    final b = Panda()..fromBt({27: 5, 32: 2400, 42: 14, 49: 1, 108: 4});
    expect((b.outsideC, b.regenMaxKw, b.packTempC, b.packHeating, b.handsOn),
        (-3, 24, 3.5, true, 4));

    // The link gone: nothing passing stays.
    await p.disconnect();
    expect((p.gripHeld, p.slippery, p.charging, p.cruiseSet, p.precondC, p.regenMaxKw),
        (false, false, false, null, null, null));
  });

  test('every signal is subscribed', () {
    for (final s in kSignals.values) {
      expect(kSubscribeIds, contains(s.id));
    }
  });
}
