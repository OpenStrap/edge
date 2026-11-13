import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/ble/firmware_flash.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart' show currentBandFamily;
import 'package:openstrap_protocol/openstrap_protocol.dart';

class _Link implements FlashLink {
  bool canFlashV = true;
  double? batt = 80;
  int ends = 0;
  int? failOnOpcode;
  bool beginOk = true;
  bool unresolved = false;
  @override
  bool get commitUnresolved => unresolved;
  @override
  void markCommitUnresolved() => unresolved = true;
  @override
  void acknowledgeCommit() => unresolved = false;
  int? rejectOpcode;

  /// When set, the next command to this opcode waits on it.
  int? holdOpcode;
  Completer<void>? hold;
  final sent = <int>[];
  final payloads = <List<int>>[];
  @override
  bool get canFlash => canFlashV;
  @override
  double? get batteryPct => batt;
  @override
  bool begin() => beginOk;
  @override
  void end() => ends++;
  @override
  Future<CorrelatedResponse?> command(int opcode, List<int> payload,
      {Duration timeout = const Duration(seconds: 5)}) async {
    sent.add(opcode);
    payloads.add(payload);
    if (opcode == holdOpcode) await (hold = Completer<void>()).future;
    if (opcode == failOnOpcode) return null;
    return CorrelatedResponse(
        opcode: opcode,
        seq: 1,
        status: opcode == rejectOpcode ? 0 : 1,
        fields: const {});
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
  test('every chunk goes out, in order, with its own bytes', () async {
    final big = Uint8List.fromList(List.generate(FwUpdate.chunk * 3 + 7, (i) => i % 251));
    final l = _Link();
    final c = FirmwareFlashController(l)..load('a.bin', big);
    await c.stage();
    final data = <int>[];
    for (var i = 0; i < l.sent.length; i++) {
      if (l.sent[i] == FwUpdate.loadData) data.add(i);
    }
    expect(data.length, 4);
    for (var k = 0; k < data.length; k++) {
      final off = k * FwUpdate.chunk;
      final end = (off + FwUpdate.chunk).clamp(0, big.length);
      expect(l.payloads[data[k]],
          FwUpdate.loadDataPayload(off, big.sublist(off, end)));
    }
    expect(c.chunksDone, 4);
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
  test('an oversize file is blocked', () {
    final c = FirmwareFlashController(_Link())
      ..load('a.bin', Uint8List(FirmwareFlashController.maxImageBytes + 1));
    expect(c.blocker, isNotNull);
  });
  test('abandon after verify releases the link and never commits', () async {
    final l = _Link();
    final c = FirmwareFlashController(l)..load('a.bin', img);
    await c.stage();
    c.abandon();
    expect(l.ends, 1);
    expect(l.sent.contains(0x90), isFalse);
  });
  test('cancel mid-stage stops before verify and releases the link', () async {
    final l = _Link();
    final c = FirmwareFlashController(l)..load('a.bin', img);
    final f = c.stage();
    c.cancel();
    await f;
    expect(l.sent.contains(0x53), isFalse);
    expect(l.sent.contains(0x90), isFalse);
    expect(l.ends, 1);
  });

  test('an unanswered commit is unknown, releases the link, offers no retry',
      () async {
    final l = _Link()..failOnOpcode = 0x90;
    final c = FirmwareFlashController(l)..load('a.bin', img);
    await c.stage();
    await c.commit();
    expect(c.phase, FlashPhase.commitUnknown);
    expect(c.failure, FlashFailure.commitUnknown);
    expect(l.ends, 1);
    final before = l.sent.length;
    await c.stage();
    c.load('b.bin', img);
    expect(l.sent.length, before);
    expect(c.fileName, 'a.bin');
  });
  test('an explicit rejection of the commit may be restaged', () async {
    final l = _Link()..rejectOpcode = 0x90;
    final c = FirmwareFlashController(l)..load('a.bin', img);
    await c.stage();
    await c.commit();
    expect(c.phase, FlashPhase.failed);
    expect(c.failure, FlashFailure.commitRejected);
  });
  test('stop while the last chunk is in flight never reaches verify', () async {
    final l = _Link()..holdOpcode = 0x8F;
    final c = FirmwareFlashController(l)..load('a.bin', img);
    final f = c.stage();
    await Future<void>.delayed(Duration.zero);
    c.cancel();
    l.hold!.complete();
    await f;
    expect(c.phase, FlashPhase.failed);
    expect(c.failure, FlashFailure.cancelled);
    expect(l.sent.contains(0x53), isFalse);
    expect(l.ends, 1);
  });
  test('stop while verify is in flight does not offer the commit', () async {
    final l = _Link()..holdOpcode = 0x53;
    final c = FirmwareFlashController(l)..load('a.bin', img);
    final f = c.stage();
    await Future<void>.delayed(Duration.zero);
    c.cancel();
    l.hold!.complete();
    await f;
    expect(c.phase, FlashPhase.failed);
    expect(l.ends, 1);
  });
  test('dispose mid-command keeps the claim until the command returns',
      () async {
    final l = _Link()..holdOpcode = 0x8F;
    final c = FirmwareFlashController(l)..load('a.bin', img);
    final f = c.stage();
    await Future<void>.delayed(Duration.zero);
    c.dispose();
    expect(l.ends, 0);
    l.hold!.complete();
    await f;
    expect(l.ends, 1);
    expect(l.sent.contains(0x53), isFalse);
  });
  test('dispose with nothing in flight releases at once', () async {
    final l = _Link();
    final c = FirmwareFlashController(l)..load('a.bin', img);
    await c.stage();
    c.dispose();
    expect(l.ends, 1);
  });
  test('a controller that never claimed does not release anything', () {
    final l = _Link();
    FirmwareFlashController(l).dispose();
    expect(l.ends, 0);
  });
  test('an empty file is a blocker, not a throw', () {
    final c = FirmwareFlashController(_Link());
    expect(() => c.load('empty.bin', Uint8List(0)), returnsNormally);
    expect(c.blocker, FlashBlock.noImage);
  });
  test('choosing another file after verify releases the claim', () async {
    final l = _Link();
    final c = FirmwareFlashController(l)..load('a.bin', img);
    await c.stage();
    c.load('b.bin', img);
    expect(l.ends, 1);
    expect(c.phase, FlashPhase.idle);
    expect(c.fileName, 'b.bin');
  });
  test('a refused takeover fails without releasing', () async {
    final l = _Link()..beginOk = false;
    final c = FirmwareFlashController(l)..load('a.bin', img);
    await c.stage();
    expect(c.failure, FlashFailure.takeover);
    expect(l.sent, isEmpty);
    expect(l.ends, 0);
  });

  test('an unresolved commit survives the screen: a new controller is locked',
      () async {
    final l = _Link()..failOnOpcode = 0x90;
    final c = FirmwareFlashController(l)..load('a.bin', img);
    await c.stage();
    await c.commit();
    expect(l.unresolved, isTrue);
    c.dispose();
    final again = FirmwareFlashController(l);
    expect(again.phase, FlashPhase.commitUnknown);
    final before = l.sent.length;
    again.load('b.bin', img);
    await again.stage();
    expect(l.sent.length, before);
    expect(again.fileName, isNull);
  });
  test('acknowledging the unresolved commit is the only way back', () async {
    final l = _Link()..unresolved = true;
    final c = FirmwareFlashController(l);
    expect(c.settled, isTrue);
    c.acknowledgeUnresolved();
    expect(l.unresolved, isFalse);
    expect(c.phase, FlashPhase.idle);
    c.load('a.bin', img);
    await c.stage();
    expect(c.phase, FlashPhase.verified);
  });
  test('the band family is read live, so a page opened early still gets gen5',
      () {
    expect(currentBandFamily(null, live: 'gen5'), 'gen5');
    expect(currentBandFamily(null, stored: 'gen5'), 'gen5');
    expect(currentBandFamily('gen4', live: 'gen5'), 'gen5');
    expect(currentBandFamily('gen5'), 'gen5');
    expect(currentBandFamily(null), isNull);
  });
}
