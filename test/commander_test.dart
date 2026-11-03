import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:tesla_dash/commander.dart';

Uint8List hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)
    ]);

/// Protobuf length-delimited field with a pre-encoded tag, written out by
/// hand so the Commander side below does not share the code under test.
List<int> ld(List<int> tag, List<int> v) => [...tag, v.length, ...v];

void main() {
  final nine = [9, ...List.filled(31, 0)];

  test('X25519 matches RFC 7748', () {
    expect(
        x25519(hex('a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4'),
            hex('e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c')),
        hex('c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552'));
    // Top bit of u set: must be masked off.
    expect(
        x25519(hex('4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d'),
            hex('e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493')),
        hex('95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957'));
    final alice = hex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
    final bob = hex('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb');
    expect(x25519(alice, nine),
        hex('8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a'));
    expect(x25519(alice, x25519(bob, nine)),
        hex('4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742'));
  });

  test('AES-256-CTR is one stream across calls (NIST SP 800-38A F.5.5)', () {
    final c = CTRStreamCipher(AESEngine())
      ..init(true, ParametersWithIV(
          KeyParameter(hex('603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4')),
          hex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff')));
    final pt = hex('6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51');
    // Odd splits, and the counter carries ...feff -> ...ff00 between blocks.
    expect([...c.process(pt.sublist(0, 5)), ...c.process(pt.sublist(5))],
        hex('601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c5'));
  });

  test('requests match the Commander protocol', () {
    // TryAction: switch type 1, state 0, or 2/3/4 for recirculation
    // on/fresh/toggle.
    expect(tryActionRequest(S3xyAction.frunk), hex('081cba02090a07080210011a0100'));
    expect(tryActionRequest(S3xyAction.mirrorTilt), hex('081cba02090a07081110011a0100'));
    expect(tryActionRequest(S3xyAction.recircOn), hex('081cba02090a07083010011a0102'));
    expect(tryActionRequest(S3xyAction.recircOff), hex('081cba02090a07083010011a0103'));
    expect(tryActionRequest(S3xyAction.recircToggle), hex('081cba02090a07083010011a0104'));
    expect(tryActionRequest(S3xyAction.climate), hex('081cba02090a07084610011a0100')); // 70, toggle
    // Car panel: open door 40 with 1-4 = FL/FR/RL/RR, unlock 53/1, flash 33/6.
    expect(tryActionRequest(S3xyAction.doorFrontLeft), hex('081cba02090a07082810011a0101'));
    expect(tryActionRequest(S3xyAction.doorRearRight), hex('081cba02090a07082810011a0104'));
    expect(tryActionRequest(S3xyAction.unlock), hex('081cba02090a07083510011a0101'));
    expect(tryActionRequest(S3xyAction.flash), hex('081cba02090a07082110011a0106'));
    // Live captures (niklaswa/S3XYCommander tests) from here on.
    // SendUUID: "08 20 da02 28 0a26" then the 38-character id.
    final id = '{260ac2ce-a519-4f4f-b299-215c5c4b217a}';
    expect(sendUuidRequest(id), [...hex('0820da02280a26'), ...utf8.encode(id)]);
    // ReqSubscribeVehicleData{fields: [61]}, as niklaswa's tag test builds it.
    expect(subscribeRequest([61]), hex('087cba08036a013d'));
    // RespSendUUID refusing an unknown phone (status 4).
    expect(replyStatus(hex('0821e202080804100818062003')), (33, 4));
    expect(replyStatus(hex('081d')), (29, 0));
  });

  test('Bluetooth asks only for what WiFi lacks while WiFi is live', () {
    final c = Commander();
    expect(c.dialLevelNow, 2); // no WiFi yet: all the car data
    c.wifiLive = true;
    expect(c.dialLevelNow, 1); // what WiFi lacks
    c.dataHold = true;
    expect(c.dialLevelNow, 0); // a WiFi stream settling: the buttons only
    c.dataHold = false;
    // A Commander restarting brings Bluetooth back first: still lean.
    c.wifiLive = false;
    expect(c.dialLevelNow, 1);
    c.dispose();
  });

  test('trip figures from vehicle-data pushes', () {
    expect(subscribeRequest([6, 7, 8, 9]), hex('087cba08066a0406070809'));
    final c = Commander();
    c.onPush(hex('0810ca0123321245696666656c20546f7765722050617269733d00004841450000be424d00009842'));
    expect((c.navDest, c.navMiles, c.navMinutes, c.navArrivePct), ('Eiffel Tower Paris', 12.5, 95.0, 76.0));
    // A delta with an explicit empty name and zeros; 9 not sent, so kept.
    c.onPush(hex('0810ca010c32003d000000004500000000'));
    expect((c.navDest, c.navMiles, c.navMinutes, c.navArrivePct), (null, 0.0, 0.0, 76.0));
    // RespGetTeslaAPIStatus body: connected, infotainment session ok, paired.
    expect(apiWords(hex('08031a04080410023002')),
        'car link connected, infotainment ok, paired');
    expect(apiWords(const []), 'car link initial, infotainment —, not paired');
    // A Commander with ScanMyTesla on: no key, sessions
    // listed but never started (status 0 is left out of each entry).
    expect(apiWords(hex('080110021a0208031a0208042805')),
        'car link partly configured (not fully configured), infotainment initial, not paired');
    // Field 101, the Commander's recirculation reading (DashRecirc RECIRC).
    c.onPush(hex('0810ca0103a80601'));
    expect(c.recircMode, 1);
  });

  test('the S3XY Dash on the Commander', () {
    // RespGetDashBasicInfo: 08 8301 (131), f208 (payload 142), field 4.
    expect(dashConnected(hex('088301f208022001')), isTrue);
    expect(dashConnected(hex('088301f208021802')), isFalse); // field 3 alone does not count
    expect(dashConnected(hex('088301f20800')), isFalse); // nothing set: not connected
    expect(dashConnected(hex('0853')), isNull); // another reply: unknown, belief kept
    expect(dashConnected(hex('088301f208020808')), isNull); // an error (8): unknown too
    // PushDeviceConnectionState (push 8, payload 10), device type 64: the Dash.
    final c = Commander();
    c.onPush(hex('0808520a0a06aabbccddeeff3040')); // connected: state 0 left out
    expect(c.dash, isTrue);
    c.onPush(hex('0808520a0a06aabbccddeeff3001')); // a phone (1): not the Dash
    expect(c.dash, isTrue);
    c.onPush(hex('0808520c0a06aabbccddeeff10023040')); // disconnected (2)
    expect(c.dash, isFalse);
    c.onPush(hex('0808520c0a06aabbccddeeff10013040')); // connecting (1): no change
    expect(c.dash, isFalse);
    c.onPush(hex('0808520c0a06aabbccddeeff10083040')); // already connected (8)
    expect(c.dash, isTrue);
  });

  test('handshake and an action against a simulated Commander', () {
    final phone = Sec1(List.generate(32, (i) => i + 1));
    final devSecret = List.generate(32, (i) => 200 - i);
    final devPub = x25519(devSecret, nine);
    final devRandom = List.generate(16, (i) => 0xf0 + i);
    final pop = SHA256Digest().process(Uint8List.fromList(utf8.encode('s3xy_enh')));
    final shared = x25519(devSecret, phone.publicKey);
    final dev = CTRStreamCipher(AESEngine())
      ..init(true, ParametersWithIV(
          KeyParameter(Uint8List.fromList([for (var i = 0; i < 32; i++) shared[i] ^ pop[i]])),
          Uint8List.fromList(devRandom)));
    Uint8List devCrypt(List<int> d) => dev.process(Uint8List.fromList(d));

    // SessionCmd0: sec_ver 1, sec1{msg 0, sc0{client_pubkey, flags 1}}.
    expect(phone.hello(),
        [0x10, 0x01, ...ld([0x5a], [0x08, 0x00, ...ld([0xa2, 0x01], [...ld([0x0a], phone.publicKey), 0x10, 0x01])])]);

    // SessionResp0: sec1{msg 1, sr0{status 0, device_pubkey, device_random}}.
    final resp0 = [0x10, 0x01, ...ld([0x5a], [0x08, 0x01, ...ld([0xaa, 0x01], [0x08, 0x00, ...ld([0x12], devPub), ...ld([0x1a], devRandom)])])];
    final cmd1 = phone.answer(resp0);
    // SessionCmd1: sec1{msg 2, sc1{client_verify_data = our stream over devPub, device_type 1}}.
    expect(cmd1, [0x10, 0x01, ...ld([0x5a], [0x08, 0x02, ...ld([0xb2, 0x01], [...ld([0x12], devCrypt(devPub)), 0x18, 0x01])])]);

    // SessionResp1: the Commander continues the same stream over our key.
    phone.check([0x10, 0x01, ...ld([0x5a], [0x08, 0x03, ...ld([0xba, 0x01], [...ld([0x1a], devCrypt(phone.publicKey))])])]);

    // Then requests and replies keep sharing that one stream.
    expect(devCrypt(phone.crypt(tryActionRequest(S3xyAction.frunk))),
        hex('081cba02090a07080210011a0100'));
    expect(replyStatus(phone.crypt(devCrypt([0x08, 0x1d, 0xc2, 0x02, 0x02, 0x08, 0x00]))), (29, 0));

    expect(phone.pushesClear, isTrue); // flag granted without an echo

    // A Commander that cannot prove the key is refused.
    final liar = Sec1(List.generate(32, (i) => i + 1));
    liar.answer(resp0);
    expect(() => liar.check([0x10, 0x01, ...ld([0x5a], [0x08, 0x03, ...ld([0xba, 0x01], [...ld([0x1a], List.filled(32, 7))])])]),
        throwsA(isA<CommanderError>()));

    // One that refuses clear pushes (confirm_security_flags 0) gets none
    // asked of it, as they would share the cipher stream.
    final strict = Sec1(List.generate(32, (i) => i + 1));
    strict.answer([0x10, 0x01, ...ld([0x5a], [0x08, 0x01, ...ld([0xaa, 0x01], [0x08, 0x00, ...ld([0x12], devPub), ...ld([0x1a], devRandom), 0x20, 0x00])])]);
    expect(strict.pushesClear, isFalse);
  });
}
