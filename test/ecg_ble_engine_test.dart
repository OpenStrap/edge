// The engine half of a WHOOP MG ECG reading: MG identity, the exclusive
// lease, the exact PREPARE/START/RESTART/CLEANUP lists (bytes, order,
// observer-before-write correlation, attempt-all, no retry), history
// preemption and refusal while leased, live R17 delivery (parsed / malformed
// / other revisions), raw R16 into the safe-trim buffer, READY recovery
// BEFORE `listening` and before INIT, link-down events, and the standing pin
// that no Labrador opcode is on a block list.

import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

Uint8List _helloBody({int revision = 1, int optical = 0}) {
  final body = Uint8List(Gen5HelloInfo.semanticBodyLen);
  final v = ByteData.sublistView(body);
  body[0] = revision;
  v.setUint32(1, 900, Endian.little);
  v.setUint32(6, DateTime.now().millisecondsSinceEpoch ~/ 1000, Endian.little);
  for (var i = 0; i < 10; i++) {
    // Synthetic, not a real strap: the serial is 10 ASCII bytes at offset 14
    // and nothing here depends on its value.
    body[14 + i] = '5AM0000000'.codeUnitAt(i);
  }
  v.setUint32(79, 13, Endian.little);
  v.setUint32(87, optical, Endian.little);
  body[91] = 50;
  body[92] = 41;
  body[93] = 1;
  body[102] = 1;
  return body;
}

Decoded _helloReply(int seq, {int revision = 1, int optical = 0}) =>
    Decoded('cmd_response', {
      'opcode': Cmd.getHello,
      'req_seq': seq,
      'cmd_status': CommandAwaiter.statusSuccess,
      'gen5_hello': Gen5HelloInfo.parse(
        _helloBody(revision: revision, optical: optical),
      )!,
    });

Decoded _ack(
  int seq,
  int opcode, {
  int status = CommandAwaiter.statusSuccess,
}) => Decoded('cmd_response', {
  'opcode': opcode,
  'req_seq': seq,
  'cmd_status': status,
});

/// A type-43 revision-17 inner with [count] samples (physical 228-byte shape).
Uint8List _r17Inner({
  int count = 100,
  int sequence = 23940969,
  int flags = 0x0a,
  int progress = 3,
  int? declaredCount,
  int revision = 17,
}) {
  final inner = Uint8List(228);
  final v = ByteData.sublistView(inner);
  inner[0] = 0x2B;
  inner[1] = revision;
  v.setUint32(3, sequence, Endian.little);
  v.setUint32(7, 1787823784, Endian.little);
  inner[13] = 1;
  inner[14] = flags;
  inner[16] = 1;
  inner[17] = progress;
  inner[20] = 70;
  v.setUint16(21, 0xffff, Endian.little);
  v.setUint16(24, declaredCount ?? count, Endian.little);
  for (var i = 0; i < count; i++) {
    v.setInt16(26 + 2 * i, i - 50, Endian.little);
  }
  return inner;
}

/// A type-47 revision-16 inner (1,572 bytes).
Uint8List _r16Inner({int sequence = 23940915}) {
  final inner = Uint8List(1572);
  final v = ByteData.sublistView(inner);
  inner[0] = 0x2F;
  inner[1] = 16;
  inner[2] = 3;
  v.setUint32(3, sequence, Endian.little);
  v.setUint32(7, 1787823731, Endian.little);
  v.setUint16(11, 24242, Endian.little);
  for (var i = 13; i < 1572; i++) {
    inner[i] = (i * 7) & 0xff;
  }
  return inner;
}

/// A fake gen5 link that records every outgoing command and answers through
/// [replyTo] FROM INSIDE the write — so a satisfied await proves the
/// observer existed before the write completed.
class _Link {
  final commands = <({int seq, int opcode, List<int> body})>[];
  final events = <EcgEngineEvent>[];
  final logs = <String>[];
  final trace = <String>[];
  late final BleEngine engine;
  Decoded? Function(int seq, int opcode)? replyTo;
  bool writeOk = true;
  List<EcgRawPacket>? committedEcgRaw;

  _Link({BandProfile band = BandProfile.gen5, EcgReadyHook? onReady}) {
    engine = BleEngine(
      onRecord: (_, _) async {},
      onState: (_) {},
      log: logs.add,
      onEcgEvent: events.add,
      onReadyEcgRecovery: onReady,
    );
    engine.debugInstallFakeLink(
      band: band,
      onWrite: (frame) async {
        final inner = parseFrame(frame, profile: band)!.inner;
        commands.add((seq: inner[1], opcode: inner[2], body: inner.sublist(3)));
        trace.add('cmd:${inner[2]}');
        if (!writeOk) return false;
        final reply = replyTo?.call(inner[1], inner[2]);
        if (reply != null) engine.debugAbsorbDecoded(reply);
        return true;
      },
      onCommit:
          (
            raws,
            samples,
            token, {
            archives,
            ecgRawPackets,
            deviceFamily,
          }) async {
            committedEcgRaw = ecgRawPackets;
          },
    );
  }

  void answerAll({int status = CommandAwaiter.statusSuccess}) =>
      replyTo = (seq, op) => _ack(seq, op, status: status);

  void helloMg({int optical = 0, int revision = 1}) =>
      engine.debugAbsorbDecoded(
        _helloReply(99, optical: optical, revision: revision),
      );

  List<int> get opcodes => commands.map((c) => c.opcode).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(BleEngine.resetBandClaimForTest);
  tearDown(BleEngine.resetBandClaimForTest);

  group('MG identity', () {
    test('false before hello; true for a revision-1 MAVERICK hello', () {
      final l = _Link();
      expect(l.engine.isMaverick, isFalse);
      l.helloMg(optical: 0);
      expect(l.engine.isMaverick, isTrue);
    });

    test(
      'the ordinary WHOOP 5.0 (optical 82) and an unknown revision are not MG',
      () {
        final l = _Link()..helloMg(optical: 82);
        expect(l.engine.isMaverick, isFalse);
        final l2 = _Link()..helloMg(optical: 0, revision: 2);
        expect(l2.engine.isMaverick, isFalse);
      },
    );
  });

  group('lease', () {
    test('one holder at a time; release frees it; stale after a new link', () {
      final l = _Link();
      final a = l.engine.ecgAcquire()!;
      expect(l.engine.ecgLeaseValid(a), isTrue);
      expect(l.engine.ecgAcquire(), isNull, reason: 'already leased');
      l.engine.ecgRelease(a);
      expect(l.engine.ecgLeaseValid(a), isFalse);
      final b = l.engine.ecgAcquire()!;
      expect(l.engine.ecgLeaseValid(b), isTrue);
      // A replacement link invalidates the old lease without releasing the
      // engine's view of it through that stale handle.
      l.engine.debugInstallFakeLink(
        onWrite: (_) async => true,
        band: BandProfile.gen5,
      );
      expect(l.engine.ecgLeaseValid(b), isFalse);
      l.engine.ecgRelease(b); // stale: must not clear a lease it no longer owns
    });
  });

  group('command lists — exact gen5 bytes, order, correlation', () {
    test(
      'PREPARE right: 123 01 01, 139 01 01, 125 01 01 — all correlated',
      () async {
        final l = _Link()..answerAll();
        final lease = l.engine.ecgAcquire()!;
        final out = await l.engine.ecgPrepare(lease, WristSelection.right);
        expect(l.opcodes, [123, 139, 125]);
        expect(l.commands[0].body.sublist(0, 5), [1, 1, 0, 0, 0]);
        expect(l.commands[1].body.sublist(0, 2), [1, 1]);
        expect(l.commands[2].body.sublist(0, 2), [1, 1]);
        expect(out.map((o) => o.label), [
          'selectWrist',
          'filteredOn',
          'rawSaveOn',
        ]);
        expect(out.every((o) => o.written && o.succeeded), isTrue);
        // Sequences are distinct and the reply matched THIS request's seq.
        expect(l.commands.map((c) => c.seq).toSet().length, 3);
      },
    );

    test('PREPARE left selects 01 02', () async {
      final l = _Link()..answerAll();
      await l.engine.ecgPrepare(l.engine.ecgAcquire()!, WristSelection.left);
      expect(l.commands[0].body.sublist(0, 2), [1, 2]);
    });

    test(
      'START: 20 (bodyless, padded) then 124 01 02; RESTART uses 01 03',
      () async {
        final l = _Link()..answerAll();
        final lease = l.engine.ecgAcquire()!;
        await l.engine.ecgStart(lease);
        expect(l.opcodes, [20, 124]);
        expect(l.commands[0].body, [
          0,
        ], reason: 'one aligned pad byte, no body');
        expect(l.commands[1].body.sublist(0, 2), [1, 2]);
        l.commands.clear();
        await l.engine.ecgRestart(lease);
        expect(l.opcodes, [20, 124]);
        expect(l.commands[1].body.sublist(0, 2), [1, 3]);
      },
    );

    test('CLEANUP: 124 01 01, 139 01 00, 125 01 00', () async {
      final l = _Link()..answerAll();
      final out = await l.engine.ecgCleanup(l.engine.ecgAcquire()!);
      expect(l.opcodes, [124, 139, 125]);
      expect(l.commands[0].body.sublist(0, 2), [1, 1]);
      expect(l.commands[1].body.sublist(0, 2), [1, 0]);
      expect(l.commands[2].body.sublist(0, 2), [1, 0]);
      expect(out.map((o) => o.label), [
        'generationStop',
        'filteredOff',
        'rawSaveOff',
      ]);
    });

    test(
      'a FAILURE reply marks the member failed and the rest are still sent',
      () async {
        final l = _Link();
        l.replyTo = (seq, op) => _ack(
          seq,
          op,
          status: op == 139
              ? CommandAwaiter.statusFailure
              : CommandAwaiter.statusSuccess,
        );
        final out = await l.engine.ecgPrepare(
          l.engine.ecgAcquire()!,
          WristSelection.right,
        );
        expect(l.opcodes, [123, 139, 125], reason: 'attempt-all');
        expect(out.map((o) => o.succeeded), [true, false, true]);
        expect(out.every((o) => o.written), isTrue);
      },
    );

    test(
      'a reply with the wrong sequence is not a match: timeout, no resend',
      () {
        fakeAsync((async) {
          final l = _Link();
          l.replyTo = (seq, op) => _ack(seq + 7, op);
          List<EcgCommandOutcome>? out;
          l.engine.ecgStart(l.engine.ecgAcquire()!).then((o) => out = o);
          async.elapse(const Duration(seconds: 11));
          expect(out, isNotNull);
          expect(l.opcodes, [
            20,
            124,
          ], reason: 'each member written exactly once');
          expect(out!.map((o) => o.written), [true, true]);
          expect(out!.map((o) => o.succeeded), [false, false]);
        });
      },
    );

    test(
      'a failed write is recorded unwritten and the list still walks on',
      () async {
        final l = _Link()..writeOk = false;
        final out = await l.engine.ecgCleanup(l.engine.ecgAcquire()!);
        expect(l.opcodes, [124, 139, 125]);
        expect(out.every((o) => !o.written && !o.succeeded), isTrue);
      },
    );

    test('a released or stale lease writes nothing', () async {
      final l = _Link()..answerAll();
      final lease = l.engine.ecgAcquire()!;
      l.engine.ecgRelease(lease);
      final out = await l.engine.ecgPrepare(lease, WristSelection.right);
      expect(l.commands, isEmpty);
      expect(out, hasLength(3));
      expect(out.every((o) => !o.written), isTrue);
    });
  });

  group('history ownership', () {
    test(
      'cancel ends an active history task with one abort, then refresh is refused while leased',
      () async {
        final l = _Link()..answerAll();
        expect(await l.engine.debugStartHistoricalRefresh(), isTrue);
        expect(l.engine.offloadActive, isTrue);
        expect(l.opcodes, contains(Cmd.sendHistoricalData));
        final lease = l.engine.ecgAcquire()!;
        l.commands.clear();
        await l.engine.ecgCancelHistory(lease);
        expect(l.opcodes, [Cmd.abortHistoricalTransmits]);
        expect(l.engine.offloadActive, isFalse);
        l.commands.clear();
        expect(await l.engine.debugStartHistoricalRefresh(), isFalse);
        expect(
          l.commands,
          isEmpty,
          reason: 'no 0x16 while the ECG owner holds the transport',
        );
        l.engine.ecgRelease(lease);
        expect(await l.engine.debugStartHistoricalRefresh(), isTrue);
      },
    );

    test('cancel with no history running sends nothing and returns', () async {
      final l = _Link()..answerAll();
      await l.engine.ecgCancelHistory(l.engine.ecgAcquire()!);
      expect(l.commands, isEmpty);
    });

    test('maintenance traffic pauses under a lease', () {
      expect(
        shouldPauseMaintenanceTraffic(offloadActive: false, ecgLeased: true),
        isTrue,
      );
      expect(shouldPauseMaintenanceTraffic(offloadActive: false), isFalse);
    });
  });

  group('live R17 delivery', () {
    test('a decodable type-43 revision-17 frame becomes an EcgFrameEvent', () {
      final l = _Link();
      l.engine.debugProcessImmediateFrame(
        Frame(_r17Inner(count: 49), true, true),
      );
      expect(l.events, hasLength(1));
      final e = l.events.single as EcgFrameEvent;
      expect(e.r17.sequence, 23940969);
      expect(e.r17.sampleCount, 49);
      expect(e.linkGeneration, l.engine.linkGeneration);
    });

    test('a revision-17 frame that does not parse is reported malformed', () {
      final l = _Link();
      l.engine.debugProcessImmediateFrame(
        Frame(_r17Inner(declaredCount: 101), true, true),
      );
      expect(l.events.single, isA<EcgMalformedR17Event>());
    });

    test(
      'other type-43 revisions (IMU R21) and gen4 links produce no ECG event',
      () {
        final l = _Link();
        l.engine.debugProcessImmediateFrame(
          Frame(_r17Inner(revision: 21), true, true),
        );
        expect(l.events, isEmpty);
        final g4 = _Link(band: BandProfile.gen4);
        g4.engine.debugProcessImmediateFrame(Frame(_r17Inner(), true, true));
        expect(g4.events, isEmpty);
      },
    );
  });

  group('raw R16 into the safe-trim buffer', () {
    test(
      'an ingested R16 is buffered on the drain and counted, not archived',
      () {
        final l = _Link();
        l.engine.debugIngestHistoricalFrame(Frame(_r16Inner(), true, true));
        final d = l.engine.debugDrain!;
        expect(d.bufferedEcgRaw, 1);
        expect(d.bufferedArchives, 0);
        expect(d.bufferedRecords, 0);
        expect(d.records, 1);
        expect(d.currentBurstHistoricalPacketCount, 1);
      },
    );

    test(
      'the buffered R16 is handed to the commit sink with the token',
      () async {
        final l = _Link();
        l.engine.debugIngestHistoricalFrame(Frame(_r16Inner(), true, true));
        final d = l.engine.debugDrain!;
        expect(await d.commit([1, 2, 3, 4, 5, 6, 7, 8]), isTrue);
        expect(l.committedEcgRaw, hasLength(1));
        expect(l.committedEcgRaw!.single.sequence, 23940915);
        expect(l.committedEcgRaw!.single.hex, hasLength(1572 * 2));
        expect(d.bufferedEcgRaw, 0);
      },
    );
  });

  group('DrainController raw-ECG lifecycle', () {
    DrainController drain(CommitSyncBatchSink onCommit) => DrainController(
      onRecord: (_, _) async {},
      onRecordsBatch: null,
      onCommit: onCommit,
      onArchive: null,
      log: (_) {},
    );
    EcgRawPacket pkt(int seq) => EcgRawPacket(
      hex: '2f10${seq.toRadixString(16)}',
      deviceId: '',
      sequence: seq,
      strapSeconds: 1,
      strapSubsec: 0,
      capturedAt: 1,
    );

    test(
      'a raw-only chunk is durable progress and commits before ACK',
      () async {
        var commits = 0;
        final d = drain((
          raws,
          samples,
          token, {
          archives,
          ecgRawPackets,
          deviceFamily,
        }) async {
          commits++;
          expect(raws, isEmpty);
          expect(ecgRawPackets, hasLength(2));
        });
        d.onEcgRawPacket(pkt(1), counter: 1);
        d.onEcgRawPacket(pkt(2), counter: 2);
        expect(d.bufferedEcgRaw, 2);
        expect(await d.commit([9, 9, 9, 9, 9, 9, 9, 9]), isTrue);
        expect(commits, 1);
        expect(
          d.lastTrimAdvanced,
          isTrue,
          reason: 'raw ECG alone advances the trim',
        );
      },
    );

    test(
      'a failed commit restores the raw ECG at the front and rolls the trim back',
      () async {
        final d = drain((
          raws,
          samples,
          token, {
          archives,
          ecgRawPackets,
          deviceFamily,
        }) async {
          throw StateError('disk');
        });
        d.onEcgRawPacket(pkt(1), counter: 1);
        expect(await d.commit([1, 1, 1, 1, 1, 1, 1, 1]), isFalse);
        expect(d.bufferedEcgRaw, 1);
        expect(d.lastTrimAdvanced, isFalse);
      },
    );

    test('discardOpenChunk drops buffered raw ECG', () {
      final d = drain(
        (
          raws,
          samples,
          token, {
          archives,
          ecgRawPackets,
          deviceFamily,
        }) async {},
      );
      d.onEcgRawPacket(pkt(1), counter: 1);
      d.discardOpenChunk();
      expect(d.bufferedEcgRaw, 0);
    });

    test('the unbuffered (no onCommit) controller refuses raw ECG', () {
      final d = DrainController(
        onRecord: (_, _) async {},
        onRecordsBatch: null,
        onCommit: null,
        onArchive: null,
        log: (_) {},
      );
      expect(() => d.onEcgRawPacket(pkt(1), counter: 1), throwsStateError);
    });
  });

  group('link down', () {
    test(
      'teardown emits EcgLinkDownEvent with the old generation and voids the lease',
      () async {
        final l = _Link()..answerAll();
        final lease = l.engine.ecgAcquire()!;
        final gen = l.engine.linkGeneration;
        await l.engine.disconnect();
        expect(
          l.events.whereType<EcgLinkDownEvent>().single.linkGeneration,
          gen,
        );
        expect(l.engine.linkGeneration, gen + 1);
        expect(l.engine.ecgLeaseValid(lease), isFalse);
        expect(l.engine.ecgLeaseHeld, isFalse);
      },
    );
  });

  group('opcode safety', () {
    test(
      'no Labrador opcode is on a block list, and the write path accepts them',
      () async {
        for (final op in [20, 123, 124, 125, 139]) {
          expect(dangerousCmds, isNot(contains(op)), reason: 'opcode $op');
          expect(OpcodeSafety.isDestructive(op), isFalse, reason: 'opcode $op');
        }
        final l = _Link();
        final frame = cmdLabradorDataGeneration(
          1,
          LabradorOperation.stop,
          profile: BandProfile.gen5,
        );
        expect(await l.engine.debugWriteRaw(frame), isTrue);
      },
    );
  });

  group('READY recovery', () {
    test(
      'the hook runs before listening and before INIT; cleanup precedes GET_DATA_RANGE',
      () {
        fakeAsync((async) {
          late _Link l;
          var readyDuringHook = true;
          l = _Link(
            onReady: (engine) async {
              l.trace.add('hook');
              readyDuringHook = engine.isConnected;
              expect(engine.ecgLeaseHeld, isTrue);
              expect(
                engine.ecgAcquire(),
                isNull,
                reason: 'recovery holds the lease',
              );
              final out = await engine.ecgRecoveryCleanup();
              expect(out.every((o) => o.succeeded), isTrue);
              l.trace.add('hook-done');
            },
          );
          // Bootstrap replies + the cleanup replies come from the same table.
          l.replyTo = (seq, op) => switch (op) {
            Cmd.getHello => _helloReply(seq),
            _ => _ack(seq, op),
          };
          bool? ok;
          l.engine.debugConnectGen5Official(_Ops(l)).then((v) => ok = v);
          async.elapse(const Duration(seconds: 8));
          expect(ok, isTrue);
          expect(
            readyDuringHook,
            isFalse,
            reason: 'READY is not visible during recovery',
          );
          final hook = l.trace.indexOf('hook');
          final done = l.trace.indexOf('hook-done');
          final range = l.trace.indexOf('cmd:${Cmd.getDataRange}');
          expect(hook, isNot(-1));
          expect(
            l.trace.sublist(hook, done),
            containsAllInOrder(['cmd:124', 'cmd:139', 'cmd:125']),
          );
          expect(
            range,
            greaterThan(done),
            reason: 'INIT (GET_DATA_RANGE) only after recovery',
          );
          expect(
            l.engine.ecgLeaseHeld,
            isFalse,
            reason: 'recovery lease released',
          );
          expect(l.engine.isConnected, isTrue);
        });
      },
    );

    test('ecgRecoveryCleanup outside the hook writes nothing', () async {
      final l = _Link()..answerAll();
      expect(await l.engine.ecgRecoveryCleanup(), isEmpty);
      expect(l.commands, isEmpty);
    });
  });
}

/// The scripted platform half of the official gen5 connect, as in
/// gen5_bootstrap_official_test.dart, minus its failure knobs.
class _Ops implements GattBootstrapOps {
  final _Link link;
  _Ops(this.link);

  @override
  bool get bondingApplies => true;
  @override
  Future<void> preferLe2mPhy() async => link.trace.add('phy');
  @override
  Future<BandEntry?> discoverAndValidate() async => kWhoopGen5;
  @override
  Future<int> requestMtu(int mtu) async => mtu;
  @override
  Future<bool> isBonded() async => true;
  @override
  Future<void> createBond() async {}
  @override
  Future<void> subscribe(String role) async => link.trace.add('sub:$role');
  @override
  Future<bool> subscribeOptionalMemfault() async => true;
}
