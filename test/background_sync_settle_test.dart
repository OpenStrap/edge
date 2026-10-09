// The headless sync stops WAITING on the drain after runSync(); if the band is
// still transmitting, the alarm/clock writes that follow must not interleave
// with the transfer. finishHeadlessDrain ends the running task with
// the ordinary one-abort terminal first — and does nothing when no task runs.

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/sync/background_sync.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _noRearm(BleEngine _) async {}

int _wallNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Uint8List _historyStart() =>
    Uint8List.fromList(<int>[PacketType.metadata, 0x01, SyncMeta.historyStart]);

Uint8List _historyComplete() => Uint8List.fromList(
    <int>[PacketType.metadata, 0x03, SyncMeta.historyComplete]);

Uint8List _historyEnd({required int expected, required int token}) {
  final inner = Uint8List(24);
  inner[0] = PacketType.metadata;
  inner[1] = 0x02;
  inner[2] = SyncMeta.historyEnd;
  ByteData.sublistView(inner)
    ..setUint32(3, 1786000000, Endian.little)
    ..setUint32(9, expected, Endian.little)
    ..setUint32(13, token, Endian.little)
    ..setUint32(17, 0x18, Endian.little);
  return inner;
}

Uint8List _gen5V18Inner({required int ts, required int counter}) {
  final inner = Uint8List(kGen5V18InnerLen);
  final v = ByteData.sublistView(inner);
  inner[0] = PacketType.historicalData;
  inner[1] = 18;
  inner[2] = 0x80;
  v.setUint32(3, counter, Endian.little);
  v.setUint32(7, ts, Endian.little);
  inner[14] = 64;
  v.setFloat32(33, 0.5, Endian.little);
  v.setFloat32(45, 1.0, Endian.little);
  return inner;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BleEngine engine;
  late List<int> opcodes;
  late List<String> logs;
  final heldCommits = <Completer<void>>[];

  /// [holdCommits]: every durable commit parks until [releaseCommit].
  void install({bool holdCommits = false}) {
    opcodes = <int>[];
    logs = <String>[];
    heldCommits.clear();
    engine = BleEngine(onRecord: (_, _) async {}, onState: (_) {}, log: logs.add);
    engine.debugInstallFakeLink(
      band: BandProfile.gen5,
      onCommit: (raws, samples, token,
          {archives, ecgRawPackets, deviceFamily}) async {
        if (!holdCommits) return;
        final c = Completer<void>();
        heldCommits.add(c);
        await c.future;
      },
      onWrite: (f) async {
        final p = parseFrame(f, profile: BandProfile.gen5);
        if (p == null || !p.valid) return true;
        final opcode = p.inner[2];
        opcodes.add(opcode);
        if (opcode == Cmd.getClock) {
          final seq = p.inner[1];
          scheduleMicrotask(() => engine.debugAbsorbDecoded(
                Decoded('cmd_response', {
                  'opcode': Cmd.getClock,
                  'req_seq': seq,
                  'cmd_status': 1,
                  'clock_epoch': _wallNow(),
                }),
              ));
        }
        return true;
      },
    );
  }

  void releaseCommit() => heldCommits.removeAt(0).complete();

  void rx(Uint8List inner) =>
      engine.debugReceiveFrame(Frame(inner, true, true), role: 'data');

  test('a still-running transfer is ended with one abort before config writes',
      () async {
    install();
    expect(await engine.debugStartHistoricalRefresh(), isTrue);
    rx(_historyStart());
    rx(_gen5V18Inner(ts: _wallNow() - 3600, counter: 4100));
    await pumpEventQueue();
    expect(engine.offloadActive, isTrue);
    final before = opcodes.length;

    await finishHeadlessDrain(engine, rearm: _noRearm);
    final after = opcodes.sublist(before);
    expect(after, [Cmd.abortHistoricalTransmits],
        reason: 'exactly one opcode-20 write, nothing else');
    expect(engine.offloadActive, isFalse);

    // Idempotent: nothing left to end.
    final again = opcodes.length;
    await finishHeadlessDrain(engine, rearm: _noRearm);
    expect(opcodes.length, again);
  });

  test('with no task running it writes nothing', () async {
    install();
    await finishHeadlessDrain(engine, rearm: _noRearm);
    expect(opcodes, isEmpty);
    expect(engine.offloadActive, isFalse);
  });

  test('a retry armed by an unanswered request cannot restart history during '
      'the configuration writes', () {
    fakeAsync((async) {
      install();
      engine.debugStartHistoricalRefresh();
      async.elapse(Duration.zero);
      expect(opcodes.where((o) => o == Cmd.sendHistoricalData), hasLength(1));

      // The band never answers: the first-START watchdog ends the task and
      // arms its one retry (3 s settle).
      async.elapse(const Duration(seconds: 11));
      expect(opcodes.where((o) => o == Cmd.abortHistoricalTransmits),
          hasLength(1));
      expect(engine.offloadActive, isFalse);

      // The headless path settles — nothing is transferring, but the retry
      // is still pending.
      finishHeadlessDrain(engine, rearm: _noRearm);
      async.elapse(Duration.zero);
      final at = opcodes.length;

      // Configuration writes take longer than the retry deadline (+ floor);
      // a band prompt and a manual trigger land meanwhile too.
      final prompt = Uint8List(12);
      prompt[0] = PacketType.event;
      prompt[1] = 0x07;
      ByteData.sublistView(prompt)
        ..setUint16(2, EventId.highFreqSyncPrompt, Endian.little)
        ..setUint32(4, 1786000000, Endian.little);
      engine.debugReceiveFrame(Frame(prompt, true, true), role: 'events');
      bool? manual;
      engine.debugStartHistoricalRefresh().then((v) => manual = v);
      async.elapse(const Duration(seconds: 30));
      expect(manual, isFalse);
      expect(opcodes.sublist(at), isNot(contains(Cmd.sendHistoricalData)),
          reason: 'no opcode 22 may go out while configuration is written');
      expect(opcodes.sublist(at), isNot(contains(Cmd.getDataRange)));
    });
  });

  test('a COMPLETE whose auto-continue lands during the settle cannot start '
      'a new request while configuration is written', () {
    fakeAsync((async) {
      install(holdCommits: true);
      engine.debugStartHistoricalRefresh();
      async.elapse(Duration.zero);
      rx(_historyStart());
      rx(_gen5V18Inner(ts: _wallNow() - 3600, counter: 4200));
      rx(_historyEnd(expected: 1, token: 0x4200));
      async.elapse(Duration.zero);
      releaseCommit(); // the END's token commit
      async.elapse(Duration.zero);
      expect(opcodes.where((o) => o == Cmd.historicalDataResult),
          hasLength(1));
      // The band's COMPLETE: its tail commit parks while the headless path
      // settles — the auto-continue it decides on runs after the hold.
      rx(_gen5V18Inner(ts: _wallNow() - 3599, counter: 4201));
      rx(_historyComplete());
      async.elapse(Duration.zero);
      var settled = false;
      finishHeadlessDrain(engine, rearm: _noRearm).then((_) => settled = true);
      async.elapse(Duration.zero);
      final at = opcodes.length;
      releaseCommit();
      async.elapse(const Duration(seconds: 10));
      expect(settled, isTrue);
      expect(logs.any((l) => l.contains('[SYNC] auto-continue')), isTrue);
      expect(logs.any((l) => l.contains('history is held on this link')),
          isTrue);
      expect(opcodes.sublist(at), isNot(contains(Cmd.sendHistoricalData)));
      expect(opcodes.sublist(at), isNot(contains(Cmd.getDataRange)));
    });
  });

  test('the headless drain settles BEFORE it re-arms the alarm', () async {
    install();
    expect(await engine.debugStartHistoricalRefresh(), isTrue);
    rx(_historyStart());
    rx(_gen5V18Inner(ts: _wallNow() - 3600, counter: 4300));
    await pumpEventQueue();
    final before = opcodes.length;
    bool? activeAtRearm;
    bool? heldAtRearm;
    bool? refreshAtRearm;
    late List<int> writesBeforeRearm;
    await finishHeadlessDrain(engine, rearm: (e) async {
      writesBeforeRearm = opcodes.sublist(before);
      activeAtRearm = e.offloadActive;
      heldAtRearm = e.offloadSnapshot['history_held'] as bool;
      refreshAtRearm = await e.debugStartHistoricalRefresh();
    });
    expect(writesBeforeRearm, [Cmd.abortHistoricalTransmits],
        reason: 'the running task was ended before the alarm writes');
    expect(activeAtRearm, isFalse);
    expect(heldAtRearm, isTrue);
    expect(refreshAtRearm, isFalse,
        reason: 'nothing may start history while the alarm is written');
  });

  test('a Shortcut sync is not held: re-arming leaves its drain free',
      () async {
    SharedPreferences.setMockInitialValues({});
    install();
    // The Shortcut path re-arms right after connect, then keeps draining on
    // the same link with requestHistorySync — it never settles.
    await rearmHeadlessAlarm(engine);
    expect(engine.offloadSnapshot['history_held'], isFalse);
    expect(await engine.debugStartHistoricalRefresh(), isTrue);
    expect(opcodes, contains(Cmd.sendHistoricalData));
  });

  group('headless shutdown waits for the closed link\'s foreign bank', () {
    test('completion stays pending until the bank settles', () async {
      install(holdCommits: true);
      // Another client's burst; its bank parks in the store.
      rx(_historyStart());
      rx(_gen5V18Inner(ts: _wallNow() - 3600, counter: 4400));
      rx(_historyEnd(expected: 1, token: 0x4400));
      await pumpEventQueue();
      expect(heldCommits, hasLength(1));
      var done = false;
      disconnectHeadless(engine).then((_) => done = true);
      await pumpEventQueue();
      expect(done, isFalse,
          reason: 'the run must not finish while those rows are in flight');
      releaseCommit();
      await pumpEventQueue();
      expect(done, isTrue);
    });

    test('… and gives up at the bound if the store never answers', () {
      fakeAsync((async) {
        install(holdCommits: true);
        rx(_historyStart());
        rx(_gen5V18Inner(ts: _wallNow() - 3600, counter: 4410));
        rx(_historyEnd(expected: 1, token: 0x4410));
        async.elapse(Duration.zero);
        var done = false;
        disconnectHeadless(engine, bound: const Duration(seconds: 12))
            .then((_) => done = true);
        async.elapse(const Duration(seconds: 11));
        expect(done, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(done, isTrue);
        expect(logs.any((l) => l.contains('not waiting longer')), isTrue);
      });
    });
  });
}
