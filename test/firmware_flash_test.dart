import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/ble/firmware_flash.dart';

class _Link implements FlashLink {
  bool canFlashV = true;
  double? batt = 80;
  int ends = 0;
  int? failOnOpcode;
  final sent = <int>[];
  @override
  bool get canFlash => canFlashV;
  @override
  double? get batteryPct => batt;
  @override
  bool begin() => true;
  @override
  void end() => ends++;
  @override
  Future<CorrelatedResponse?> command(int opcode, List<int> payload,
      {Duration timeout = const Duration(seconds: 5)}) async {
    sent.add(opcode);
    if (opcode == failOnOpcode) return null;
    return CorrelatedResponse(
        opcode: opcode, seq: 1, status: 1, fields: const {});
  }
}

void main() {
  final img = Uint8List(300);
  test('stages, verifies, then waits: commit is not sent', () async {
    final l = _Link();
    final c = FirmwareFlashController(l)..load('a.bin', img);
    await c.stage();
    expect(c.phase, FlashPhase.verified);
    expect(l.sent.first, 0x8E);
    expect(l.sent.last, 0x53);
    expect(l.sent.contains(0x90), isFalse);
    expect(l.ends, 0);
  });
  test('commit only after verified, and releases the link', () async {
    final l = _Link();
    final c = FirmwareFlashController(l)..load('a.bin', img);
    await c.commit();
    expect(l.sent, isEmpty);
    await c.stage();
    await c.commit();
    expect(l.sent.last, 0x90);
    expect(c.phase, FlashPhase.committed);
    expect(l.ends, 1);
  });
  test('a rejected chunk stops before verify and commit', () async {
    final l = _Link()..failOnOpcode = 0x8F;
    final c = FirmwareFlashController(l)..load('a.bin', img);
    await c.stage();
    expect(c.phase, FlashPhase.failed);
    expect(l.sent.contains(0x53), isFalse);
    expect(l.sent.contains(0x90), isFalse);
  });
  test('low or unknown battery blocks', () {
    final l = _Link()..batt = 30;
    final c = FirmwareFlashController(l)..load('a.bin', img);
    expect(c.blocker, isNotNull);
    l.batt = null;
    expect(c.blocker, isNotNull);
  });
}
