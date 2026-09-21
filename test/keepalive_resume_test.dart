// The keep-alive fuse on a process that was suspended. An iOS app woken by a
// band prompt after 15 quiet minutes must NOT bounce the link on its first
// (overdue) tick — it must probe. A tick that arrived on cadence with the
// same silence still bounces.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

class _Rig {
  final logs = <String>[];
  final opcodes = <int>[];
  late final BleEngine engine;

  _Rig() {
    engine = BleEngine(
      onRecord: (_, _) async {},
      onState: (_) {},
      log: logs.add,
    );
    engine.debugInstallFakeLink(
      band: BandProfile.gen4,
      listening: true,
      onWrite: (Uint8List frame) async {
        final p = parseFrame(frame, profile: BandProfile.gen4);
        if (p != null && p.valid) opcodes.add(p.inner[2]);
        return true;
      },
    );
  }

  bool get bounced => logs.any((l) => l.contains('bouncing the link'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  test('overdue tick after 15 min of suspension: no bounce, battery probe sent',
      () async {
    final rig = _Rig();
    final ago = DateTime.now().subtract(const Duration(minutes: 15));
    rig.engine.debugSetLiveness(lastRx: ago, lastKeepAliveTick: ago);

    rig.engine.debugFireKeepAlive();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(rig.bounced, isFalse,
        reason: 'silence while suspended is not evidence of a dead link');
    expect(rig.opcodes, contains(Cmd.getBatteryLevel),
        reason: 'the resumed tick must ask the band instead of guessing');
    expect(rig.logs.any((l) => l.contains('resumed after')), isTrue);
  });

  test('tick on cadence with the same silence still bounces', () async {
    final rig = _Rig();
    final now = DateTime.now();
    rig.engine.debugSetLiveness(
      lastRx: now.subtract(const Duration(seconds: kLivenessFuseSeconds + 5)),
      lastKeepAliveTick:
          now.subtract(const Duration(seconds: kKeepAliveIntervalSeconds)),
    );

    rig.engine.debugFireKeepAlive();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(rig.bounced, isTrue);
  });

  test('first tick of a session judges the raw rx gap', () async {
    final rig = _Rig();
    rig.engine.debugSetLiveness(
      lastRx: DateTime.now()
          .subtract(const Duration(seconds: kLivenessFuseSeconds + 5)),
      lastKeepAliveTick: null,
    );

    rig.engine.debugFireKeepAlive();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(rig.bounced, isTrue);
  });
}
