// Adversarial history-task boundaries — the Gen5 task lifecycle under
// validation retries, failed HISTORICAL_DATA_RESULT writes, terminal aborts,
// concurrent refresh triggers and stale continuations.
//
// Contract under test (doc 05, follow-up ledger items 4–7):
//  - the consecutive validation-failure counter lives on the TASK: a new task
//    starts fresh, a replacement HISTORY_START keeps it, success resets it;
//  - a HISTORICAL_DATA_RESULT the phone cannot write is TERMINAL for the task:
//    one best-effort abort, no reconnect loop, and the already-committed rows
//    stay committed (without the trim token);
//  - a new task must not start while an abort is still in flight, and an old
//    task's parked continuations/queued frames can neither ACK, abort nor
//    mutate the task that replaced them;
//  - Gen4 is untouched: its count gate stays advisory and its ACK bytes are
//    identical.
//
// Everything drives the REAL receive path (FrameRoutePolicy → serialized
// offload queue → _handleSyncMarker) over a stubbed GATT write with the real
// atomic-commit sink shape — not re-implemented policy logic.

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

int _wallNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Uint8List _historyStart() =>
    Uint8List.fromList(<int>[PacketType.metadata, 0x01, SyncMeta.historyStart]);

Uint8List _historyComplete() => Uint8List.fromList(
    <int>[PacketType.metadata, 0x03, SyncMeta.historyComplete]);

/// A type-49 METADATA HISTORY_END inner: `expected_count` u32 @9 and the
/// 8-byte trim token @13:21 the result echoes verbatim.
Uint8List _historyEnd({required int expected, required int token}) {
  final inner = Uint8List(24);
  inner[0] = PacketType.metadata;
  inner[1] = 0x02;
  inner[2] = SyncMeta.historyEnd;
  final v = ByteData.sublistView(inner);
  v.setUint32(3, 1786000000, Endian.little); // strap clock
  v.setUint32(9, expected, Endian.little);
  v.setUint32(13, token, Endian.little); // marker A
  v.setUint32(17, 0x18, Endian.little); // marker B / batch id
  return inner;
}

/// Raw notification bytes of an intact gen5 frame whose revision this build
/// does not speak (header byte 1 = 0x02, header CRC recomputed).
Uint8List _rev2Chunk(Uint8List inner) {
  final f = buildFrame(inner, profile: BandProfile.gen5);
  f[1] = 0x02;
  final c = crc16Modbus(f.sublist(0, 6));
  f[6] = c & 0xFF;
  f[7] = (c >> 8) & 0xFF;
  return f;
}

/// The verbatim 8 bytes a success result for [token] must echo.
List<int> _tokenBytes(int token) {
  final b = Uint8List(8);
  ByteData.sublistView(b)
    ..setUint32(0, token, Endian.little)
    ..setUint32(4, 0x18, Endian.little);
  return b;
}

Uint8List _gen5V18Inner({required int ts, required int counter}) {
  final inner = Uint8List(kGen5V18InnerLen);
  final v = ByteData.sublistView(inner);
  inner[0] = PacketType.historicalData;
  inner[1] = 18;
  inner[2] = 0x80;
  v.setUint32(3, counter, Endian.little);
  v.setUint32(7, ts, Endian.little);
  inner[14] = 64; // heart rate
  v.setFloat32(33, 0.5, Endian.little); // dynamic acceleration
  v.setFloat32(45, 1.0, Endian.little); // gravity z → |g| = 1.0
  return inner;
}

/// A gen4 v24 historical inner (the trusted decode path — no gate applies).
Uint8List _gen4V24Inner({required int ts, required int counter}) {
  final inner = Uint8List(89);
  inner[0] = PacketType.historicalData;
  inner[1] = 24;
  final view = ByteData.sublistView(inner);
  view.setUint32(3, counter, Endian.little);
  view.setUint32(7, ts, Endian.little);
  return inner;
}

/// A type-48 EVENT inner (envelope per protocol's `_envelopeBody`).
Uint8List _eventInner(int id, List<int> body, {int ts = 1786000000}) {
  final inner = Uint8List(12 + body.length);
  inner[0] = PacketType.event;
  inner[1] = 0x07;
  final view = ByteData.sublistView(inner);
  view.setUint16(2, id, Endian.little);
  view.setUint32(4, ts, Endian.little);
  view.setUint16(8, 0, Endian.little);
  view.setUint16(10, body.length, Endian.little);
  inner.setRange(12, inner.length, body);
  return inner;
}

/// One outgoing command, decoded far enough to identify: opcode + first body
/// byte (a HISTORICAL_DATA_RESULT is `01` for success, `00` for failure).
class _Cmd {
  final int opcode;
  final int body0;
  final List<int> body;
  _Cmd(this.opcode, this.body0, this.body);
}

/// A fake gen5/gen4 link with the real safe-trim commit sink and a
/// configurable transport: individual result polarities can be failed, the
/// abort write can be held open, and GET_CLOCK is answered with a healthy
/// correlated reply so `_startHistoricalRefresh` runs end to end.
class _Rig {
  final BandProfile band;
  final logs = <String>[];

  /// Every write ATTEMPT that reached the transport, in order (the hook runs
  /// after the engine's session/owner guards — a stale-session write never
  /// appears here).
  final writes = <_Cmd>[];

  /// Ordering probe: `commit:<token|null>` and `write:<opcode>:<body0>`.
  final events = <String>[];
  final committedTokens = <String?>[];
  final committedRows = <int>[];

  bool failFailureResults = false;
  bool failSuccessResults = false;
  bool answerClock = true;

  /// When set, abort (opcode 20) writes park on this future.
  Completer<bool>? holdAbort;

  /// When set, the link is replaced (a drop + reconnect, as far as
  /// session-scoped state is concerned) immediately after the
  /// SEND_HISTORICAL_DATA write SUCCEEDS — the write lands, the session dies
  /// before the caller's continuation resumes.
  bool dropLinkAfterDrainRequest = false;

  /// When set, the band answers SEND_HISTORICAL_DATA with a HISTORY_START
  /// delivered before the write future resolves (the answer beats the
  /// caller's continuation).
  bool startOnDrainRequest = false;

  /// Called when GET_CLOCK is written — i.e. while a claim is still inside
  /// its pre-request waits, before SEND_HISTORICAL_DATA goes out.
  void Function()? onClockRequest;

  /// Called for every outgoing command, with its opcode.
  void Function(int opcode)? onWriteOpcode;

  /// When set, the next write of [holdOpcode] parks on this future (and the
  /// write chain behind it with it).
  int? holdOpcode;
  Completer<bool>? holdWrite;

  /// When set, the NEXT commit parks on this future (then completes normally,
  /// or throws if [failHeldCommit] is set — the shape of a transaction that
  /// fails after parking for seconds).
  Completer<void>? holdCommit;
  bool failHeldCommit = false;

  /// The next N commits throw (the store rolled back).
  int failCommits = 0;

  late final BleEngine engine;

  _Rig({this.band = BandProfile.gen5}) {
    engine = BleEngine(
      onRecord: (_, _) async {},
      onState: (_) {},
      log: logs.add,
    );
    connect();
  }

  /// Stand up a fresh session on the same engine (a reconnect, as far as
  /// everything session-scoped is concerned).
  void connect() => engine.debugInstallFakeLink(
        band: band,
        onCommit: (raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {
          final hold = holdCommit;
          if (hold != null) {
            holdCommit = null;
            await hold.future;
            if (failHeldCommit) {
              failHeldCommit = false;
              throw StateError('held commit rolled back');
            }
          }
          if (failCommits > 0) {
            failCommits--;
            throw StateError('commit rolled back');
          }
          events.add('commit:$token');
          committedTokens.add(token);
          committedRows.add(raws.length + (archives ?? const []).length);
        },
        onWrite: (f) async {
          final p = parseFrame(f, profile: band);
          if (p == null || !p.valid) return true;
          final opcode = p.inner[2];
          final body = p.inner.sublist(3);
          final body0 = body.isEmpty ? -1 : body[0];
          writes.add(_Cmd(opcode, body0, body));
          events.add('write:$opcode:$body0');
          onWriteOpcode?.call(opcode);
          if (opcode == Cmd.getClock) onClockRequest?.call();
          if (opcode == Cmd.getClock && answerClock) {
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
          final hw = holdWrite;
          if (hw != null && opcode == holdOpcode) {
            holdWrite = null;
            return hw.future;
          }
          if (opcode == Cmd.abortHistoricalTransmits && holdAbort != null) {
            return holdAbort!.future;
          }
          if (opcode == Cmd.sendHistoricalData && startOnDrainRequest) {
            scheduleMicrotask(() => rx(_historyStart()));
          }
          if (opcode == Cmd.sendHistoricalData && dropLinkAfterDrainRequest) {
            dropLinkAfterDrainRequest = false;
            connect(); // the write succeeds; the session it served is gone
          }
          if (opcode == Cmd.historicalDataResult) {
            if (body0 == 0x00 && failFailureResults) return false;
            if (body0 == 0x01 && failSuccessResults) return false;
          }
          return true;
        },
      );

  void rx(Uint8List inner, {String role = 'data'}) =>
      engine.debugReceiveFrame(Frame(inner, true, true), role: role);

  /// Claim a history task exactly as INIT/refresh do, minus the writes — the
  /// state a link is in right after its own opcode 22 went out. Only traffic
  /// for a task this engine requested is ever answered.
  void claim() => engine.debugClaimHistoryTask();

  List<_Cmd> get failureResults => writes
      .where((c) => c.opcode == Cmd.historicalDataResult && c.body0 == 0x00)
      .toList();
  List<_Cmd> get successResults => writes
      .where((c) => c.opcode == Cmd.historicalDataResult && c.body0 == 0x01)
      .toList();
  List<_Cmd> get aborts =>
      writes.where((c) => c.opcode == Cmd.abortHistoricalTransmits).toList();
  List<_Cmd> get drainRequests =>
      writes.where((c) => c.opcode == Cmd.sendHistoricalData).toList();
  List<_Cmd> get rangePolls =>
      writes.where((c) => c.opcode == Cmd.getDataRange).toList();

  List<String> get shortLines =>
      logs.where((l) => l.contains('Burst packet-count SHORT')).toList();
}

/// Resolve [f] under fakeAsync (the value it completed with, or null).
T? await_<T>(Future<T> f, FakeAsync async) {
  T? v;
  f.then((x) => v = x);
  async.elapse(Duration.zero);
  return v;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ts = _wallNow() - 3600;

  group('DrainController — the three lifecycle boundaries', () {
    DrainController drain() => DrainController(
          onRecord: (sample, raw) async {},
          onRecordsBatch: null,
          onCommit: (raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {},
          onArchive: null,
          log: (_) {},
        );

    test('startFreshTask resets the failure counter', () {
      final d = drain();
      d.consecutiveValidationFailures = 7;
      d.startFreshTask();
      expect(d.consecutiveValidationFailures, 0);
    });

    test('beginBurst (replacement HISTORY_START) KEEPS the failure counter '
        'while rearm keeps it too', () {
      final d = drain();
      d.consecutiveValidationFailures = 4;
      d.rearm();
      d.beginBurst();
      expect(d.consecutiveValidationFailures, 4,
          reason: 'doc 05: a replacement START discards the partial '
              'accumulator but keeps the failure counter');
    });

    test('successful validation resets the counter (the one in-task reset)',
        () {
      final d = drain();
      // Two failures against an empty tally…
      expect(d.validateBurst(expectedPacketCount: 5), isFalse);
      expect(d.validateBurst(expectedPacketCount: 5), isFalse);
      expect(d.consecutiveValidationFailures, 2);
      // …then a burst that matches.
      expect(d.validateBurst(expectedPacketCount: 0), isTrue);
      expect(d.consecutiveValidationFailures, 0);
    });

    test('onTaskTerminal resolves awaitComplete promptly and incomplete; '
        'rearm re-arms the waiter for the next task', () {
      fakeAsync((async) {
        final d = drain();
        SyncReport? report;
        d.awaitComplete(isLinkUp: () => true).then((r) => report = r);
        async.elapse(const Duration(seconds: 3));
        expect(report, isNull, reason: 'healthy offload keeps waiting');

        d.onTaskTerminal();
        async.elapse(const Duration(seconds: 2));
        expect(report, isNotNull,
            reason: 'the abort boundary must release the waiter — not the '
                '60 s idle window, not the full timeout');
        expect(report!.complete, isFalse);

        // A fresh CLAIM (startFreshTask re-arms internally) clears the
        // terminal: the NEXT waiter parks normally instead of resolving
        // instantly on the LAST task's abort.
        d.startFreshTask();
        SyncReport? next;
        d.awaitComplete(isLinkUp: () => true).then((r) => next = r);
        async.elapse(const Duration(seconds: 3));
        expect(next, isNull);
        d.onComplete();
        async.elapse(const Duration(seconds: 2));
        expect(next?.complete, isTrue);
      });
    });

    test(
        'a replacement claim landing between the terminal and the waiter\'s '
        'next tick still resolves the OLD waiter incomplete', () {
      fakeAsync((async) {
        final d = drain();
        SyncReport? old;
        d.awaitComplete(isLinkUp: () => true).then((r) => old = r);

        // Terminal AND the replacement claim inside one tick window — the
        // claim clears the terminal flag before the once-a-second check ever
        // sees it. The waiter generation is what still catches it.
        d.onTaskTerminal();
        d.startFreshTask();
        SyncReport? fresh;
        d.awaitComplete(isLinkUp: () => true).then((r) => fresh = r);

        async.elapse(const Duration(seconds: 2));
        expect(old, isNotNull,
            reason: 'the superseded waiter must resolve — not park against '
                'the replacement task');
        expect(old!.complete, isFalse);
        expect(fresh, isNull, reason: 'the new task\'s waiter stays armed');

        d.onComplete();
        async.elapse(const Duration(seconds: 2));
        expect(fresh?.complete, isTrue);
      });
    });

    test(
        'HISTORY_COMPLETE followed by an immediate auto-continue claim still '
        'reports the superseded task as COMPLETE', () {
      fakeAsync((async) {
        final d = drain();
        SyncReport? old;
        d.awaitComplete(isLinkUp: () => true).then((r) => old = r);

        // The offload completes and auto-continue claims the next task
        // before the waiter's next once-a-second tick — the claim wipes the
        // completion flag, so the recorded per-task outcome is all that is
        // left of the truth.
        d.onComplete();
        d.startFreshTask();

        async.elapse(const Duration(seconds: 2));
        expect(old, isNotNull);
        expect(old!.complete, isTrue,
            reason: 'the superseded task DID complete — reporting failure '
                'here turned every fast auto-continue into a phantom error');
      });
    });

    test('the report counts this task, not the whole connection', () {
      fakeAsync((async) {
        final d = drain();
        RawRecord raw(int counter) => RawRecord(
              counter: counter,
              packetType: 0x2f,
              hex: '2f18${counter.toRadixString(16).padLeft(8, '0')}',
              capturedAt: 1786000000000 + counter,
              recTs: 1786000000 + counter,
            );
        SyncReport? first;
        d.awaitComplete(isLinkUp: () => true).then((r) => first = r);
        d.onHistoricalRecord(raw(1), null, 24);
        d.onHistoricalRecord(raw(2), null, 24);
        d.noteBatchAcked();
        // Auto-continue claims the next task before the waiter's tick.
        d.onComplete();
        d.startFreshTask();
        async.elapse(const Duration(seconds: 2));
        expect((first?.records, first?.batches), (2, 1));

        // The next pull on the same link gets nothing.
        SyncReport? next;
        d.awaitComplete(isLinkUp: () => true).then((r) => next = r);
        async.elapse(const Duration(seconds: 3));
        d.onTaskTerminal();
        async.elapse(const Duration(seconds: 2));
        expect(next?.complete, isFalse);
        expect((next?.records, next?.batches), (0, 0),
            reason: 'connection totals made a dead pull look like progress');
        expect((d.records, d.batches), (2, 1));
      });
    });

    test('a claim landing during the final flush keeps the old task counts',
        () {
      fakeAsync((async) {
        final gate = Completer<void>();
        final d = DrainController(
          onRecord: (sample, r) async {},
          onRecordsBatch: null,
          onCommit: (raws, samples, token, {archives, ecgRawPackets, deviceFamily}) =>
              gate.future,
          onArchive: null,
          log: (_) {},
        );
        RawRecord raw(int counter) => RawRecord(
              counter: counter,
              packetType: 0x2f,
              hex: '2f18${counter.toRadixString(16).padLeft(8, '0')}',
              capturedAt: 1786000000000 + counter,
              recTs: 1786000000 + counter,
            );
        SyncReport? old;
        d.awaitComplete(isLinkUp: () => true).then((r) => old = r);
        d.onHistoricalRecord(raw(1), null, 24);
        d.onHistoricalRecord(raw(2), null, 24);
        d.onComplete();
        // The tick sees COMPLETE and parks in flush() on the slow commit.
        async.elapse(const Duration(seconds: 1));
        expect(old, isNull);
        // Auto-continue claims the next task while the commit is in flight.
        d.startFreshTask();
        gate.complete();
        async.flushMicrotasks();
        expect(old?.complete, isTrue);
        expect((old?.records, old?.batches), (2, 0),
            reason: 'the replacement task\'s reset counters leaked into '
                'the finished task\'s report');
      });
    });

    test(
        'a superseded waiter performs NO commit — the replacement\'s buffered '
        'rows are persisted only by its own token commit', () {
      fakeAsync((async) {
        RawRecord raw(int counter) => RawRecord(
              counter: counter,
              packetType: 0x2f,
              hex: '2f18${counter.toRadixString(16).padLeft(8, '0')}',
              capturedAt: 1786000000000 + counter,
              recTs: 1786000000 + counter,
            );
        final commits = <(String?, int)>[];
        final d = DrainController(
          onRecord: (sample, r) async {},
          onRecordsBatch: null,
          onCommit: (raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {
            commits.add((token, raws.length));
          },
          onArchive: null,
          log: (_) {},
        );
        SyncReport? old;
        d.awaitComplete(isLinkUp: () => true).then((r) => old = r);

        // The task completes and auto-continue claims the replacement, whose
        // open burst buffers rows BEFORE the old waiter's next tick.
        d.onComplete();
        d.startFreshTask();
        d.beginBurst();
        d.onHistoricalRecord(raw(1), null, 24);
        d.onHistoricalRecord(raw(2), null, 24);

        async.elapse(const Duration(seconds: 2));
        expect(old?.complete, isTrue);
        expect(commits, isEmpty,
            reason: 'a stale waiter flushing here would snapshot the '
                'replacement\'s open burst and could overlap its token '
                'commit — the ACK must never precede those rows\' '
                'durability');
        expect(d.bufferedRecords, 2,
            reason: 'the rows stay in the replacement\'s buffer');

        // Only the replacement's OWN token commit persists them.
        bool? durable;
        d.commit(const [1, 2, 3, 4, 5, 6, 7, 8]).then((v) => durable = v);
        async.flushMicrotasks();
        expect(durable, isTrue);
        expect(commits, [('0102030405060708', 2)]);
      });
    });
  });

  group('T1 — a later task never inherits the previous task\'s slack', () {
    test(
        'three failures in task A do not grant task B\'s first burst the '
        'two-packet slack', () async {
      final r = _Rig();
      r.claim();
      // Task A: one short burst, judged three times via marker-only
      // re-offers — the counter climbs to 3 (slack would be 2 from here).
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 100));
      for (var i = 0; i < 3; i++) {
        r.rx(_historyEnd(expected: 5, token: 0x9100));
        await pumpEventQueue();
      }
      expect(r.shortLines, hasLength(3));

      // Task A hands over (COMPLETE) — nothing about completion touches the
      // counter.
      r.rx(_historyComplete());
      await pumpEventQueue();

      // Task B is explicitly claimed and its first burst delivers 1 frame
      // against expected 3 (behind its own HISTORY_START — before that first
      // START a HISTORY_END is a doc-05 duplicate and is dropped). With task
      // A's three failures inherited, the slack of 2 would ACCEPT 1/3 and
      // let the band trim two frames never tallied — and a HISTORY_START no
      // longer resets the counter, so only the task claim stands between
      // burst B and that inherited slack.
      expect(await r.engine.debugStartHistoricalRefresh(), isTrue);
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts + 10, counter: 101));
      r.rx(_historyEnd(expected: 3, token: 0x9101));
      await pumpEventQueue();

      expect(r.shortLines, hasLength(4),
          reason: 'task B\'s first burst is judged at attempt 1, slack 0');
      expect(r.shortLines.last, contains('attempt 1,'));
      expect(r.successResults, isEmpty,
          reason: 'nothing may be ACKed on inherited slack');
    });

    test('a replacement HISTORY_START keeps the counter and resets the tally',
        () async {
      final r = _Rig();
      r.claim();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 200));
      r.rx(_gen5V18Inner(ts: ts + 1, counter: 201));
      r.rx(_historyEnd(expected: 9, token: 0x9200));
      await pumpEventQueue();
      expect(r.shortLines, hasLength(1));
      expect(r.shortLines.last, contains('attempt 1,'));
      expect(r.shortLines.last, contains('traffic=2'));

      // Replacement START inside the same task: the partial accumulator/tally
      // is discarded, the failure count is not.
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts + 2, counter: 202));
      r.rx(_gen5V18Inner(ts: ts + 3, counter: 203));
      r.rx(_gen5V18Inner(ts: ts + 4, counter: 204));
      r.rx(_historyEnd(expected: 9, token: 0x9200));
      await pumpEventQueue();

      expect(r.shortLines, hasLength(2));
      expect(r.shortLines.last, contains('attempt 2,'),
          reason: 'the failure count survived the replacement START');
      expect(r.shortLines.last, contains('traffic=3'),
          reason: 'the tally did not — only the new delivery is counted');
    });

    test('a successful validation resets the counter mid-task', () async {
      final r = _Rig();
      r.claim();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 300));
      r.rx(_historyEnd(expected: 3, token: 0x9300));
      await pumpEventQueue();
      r.rx(_historyEnd(expected: 3, token: 0x9300));
      await pumpEventQueue();
      expect(r.shortLines, hasLength(2)); // attempts 1 and 2

      // The band re-offers complete this time — success.
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts + 1, counter: 301));
      r.rx(_gen5V18Inner(ts: ts + 2, counter: 302));
      r.rx(_historyEnd(expected: 2, token: 0x9301));
      await pumpEventQueue();
      expect(r.successResults, hasLength(1));

      // The next short burst is judged at attempt 1 again.
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts + 3, counter: 303));
      r.rx(_historyEnd(expected: 3, token: 0x9302));
      await pumpEventQueue();
      expect(r.shortLines, hasLength(3));
      expect(r.shortLines.last, contains('attempt 1,'));
    });
  });

  group('T4 — the fifteenth failure', () {
    test('attempts 1–14 send the negative result; attempt 15 sends exactly '
        'one abort and no fifteenth result', () async {
      final r = _Rig();
      r.claim();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 400));
      for (var i = 1; i <= kBurstValidationAttemptLimit; i++) {
        r.rx(_historyEnd(expected: 5, token: 0x9400));
        await pumpEventQueue();
      }
      expect(r.failureResults, hasLength(kBurstValidationAttemptLimit - 1));
      expect(r.aborts, hasLength(1));
      expect(r.engine.offloadSnapshot['last_hps_terminal'], 'stuck');
      expect(r.engine.offloadSnapshot['history_task_ended'], isTrue);
      expect(r.engine.offloadActive, isFalse,
          reason: 'the task is released after the abort boundary');

      // The terminal is emitted once: further re-offers are inert.
      final before = r.writes.length;
      r.rx(_historyEnd(expected: 5, token: 0x9400));
      await pumpEventQueue();
      expect(r.writes.length, before);
    });
  });

  group('T5 — a failed negative-result write is terminal', () {
    test(
        'rows stay committed without the token, one abort goes out, no '
        'success ACK ever, and a later task starts cleanly', () async {
      final r = _Rig()..failFailureResults = true;
      r.claim();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 500));
      r.rx(_historyEnd(expected: 3, token: 0x9500));
      await pumpEventQueue();

      // The received row was preserved — committed WITHOUT the trim token.
      expect(r.committedTokens, [null]);
      expect(r.committedRows, [1]);
      expect(r.successResults, isEmpty,
          reason: 'a failed burst must never be ACKed');
      expect(r.failureResults, hasLength(1),
          reason: 'one attempt reached the transport and failed');
      expect(r.aborts, hasLength(1), reason: 'exactly one best-effort abort');
      expect(r.engine.offloadSnapshot['last_hps_reason'],
          'failure_result_write_failed');
      expect(r.engine.offloadActive, isFalse);

      // Duplicate HISTORY_END markers after terminal are inert: no watchdog
      // re-arm, no further validation, no traffic.
      final before = r.writes.length;
      for (var i = 0; i < 3; i++) {
        r.rx(_historyEnd(expected: 3, token: 0x9500));
        await pumpEventQueue();
      }
      expect(r.writes.length, before);
      expect(r.engine.offloadSnapshot['ended_markers_dropped'], 3);
      expect(r.engine.offloadActive, isFalse,
          reason: 'stragglers must not re-open the task');

      // A straggler HISTORY_COMPLETE is inert too: it must not record a
      // SUCCESS terminal over the abort or run the post-offload policy.
      r.rx(_historyComplete());
      await pumpEventQueue();
      expect(
        r.logs.any((l) => l.contains('HistoryComplete — backlog drained')),
        isFalse,
      );
      expect(r.engine.offloadSnapshot['last_hps_reason'],
          'failure_result_write_failed');

      // A later explicit task starts cleanly once the write path recovers.
      r.failFailureResults = false;
      expect(await r.engine.debugStartHistoricalRefresh(), isTrue);
      expect(r.drainRequests, hasLength(1));
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts + 10, counter: 501));
      r.rx(_historyEnd(expected: 1, token: 0x9501));
      await pumpEventQueue();
      expect(r.successResults, hasLength(1),
          reason: 'the new task validates and ACKs normally');
    });
  });

  group('T6 — exhausted positive-result writes', () {
    test(
        'durable commit first, bounded retries, then one abort — and no '
        'reconnect, no acked bookkeeping', () async {
      final r = _Rig()..failSuccessResults = true;
      r.claim();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 600));
      r.rx(_historyEnd(expected: 1, token: 0x9600));
      // Real (bounded) retry backoff: 200 + 400 ms.
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(seconds: 1));
      await pumpEventQueue();

      // Commit-before-ACK: the durable commit precedes the first ACK attempt.
      final commitAt = r.events.indexWhere((e) => e.startsWith('commit:') && !e.endsWith(':null'));
      final firstAckAt = r.events.indexWhere(
          (e) => e == 'write:${Cmd.historicalDataResult}:1');
      expect(commitAt, isNonNegative);
      expect(firstAckAt, greaterThan(commitAt));

      expect(r.successResults, hasLength(3),
          reason: 'the existing bounded ACK retries are preserved');
      expect(r.aborts, hasLength(1),
          reason: 'exactly one abort once the retries are exhausted');
      expect(r.engine.offloadSnapshot['batches_acked'], 0,
          reason: 'no acknowledged-batch bookkeeping may advance');
      expect(r.engine.offloadSnapshot['last_hps_reason'], 'ack_write_exhausted');
      expect(r.logs.where((l) => l.contains('bouncing the link')), isEmpty,
          reason: 'no immediate reconnect loop');
      expect(r.engine.isConnected, isFalse,
          reason: 'fake link never enters listening — but nothing tore the '
              'session down either');
      expect(r.logs.where((l) => l.contains('BATCH-ACK FAILED')), hasLength(1));
      expect(r.engine.offloadActive, isFalse);
    });
  });

  group('T7 — no task starts while an abort is in flight', () {
    test(
        'manual, strap and repeated triggers all wait for the abort; at most '
        'one serialized next task follows', () async {
      final r = _Rig()..failFailureResults = true;
      r.claim();
      r.holdAbort = Completer<bool>();

      // Terminal with the abort write parked open.
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 700));
      r.rx(_historyEnd(expected: 3, token: 0x9700));
      await pumpEventQueue();
      expect(r.aborts, hasLength(1), reason: 'abort issued and parked');

      // Refresh triggers land while the abort is pending: a manual refresh,
      // the strap's high-frequency prompt, and a second manual attempt.
      final manual1 = r.engine.debugStartHistoricalRefresh();
      r.rx(_eventInner(EventId.highFreqSyncPrompt, const <int>[]),
          role: 'events');
      final manual2 = r.engine.debugStartHistoricalRefresh();
      await pumpEventQueue();

      expect(r.rangePolls, isEmpty,
          reason: 'no GET_DATA_RANGE may go out before the abort completes');
      expect(r.drainRequests, isEmpty,
          reason: 'no opcode 22 may go out before the abort completes');

      // The abort completes — exactly one waiter claims the next task.
      r.holdAbort!.complete(true);
      r.holdAbort = null;
      final results = await Future.wait([manual1, manual2]);
      await pumpEventQueue();
      // Give the strap-prompt path (fired unawaited) time to finish too.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(r.drainRequests, hasLength(1),
          reason: 'at most one properly serialized next task');
      expect(results.where((sent) => sent), hasLength(1));
    });
  });

  group('T8 — an old task generation cannot touch its replacement', () {
    test(
        'a continuation whose parked commit FAILS after the watchdog ends '
        'the task cannot ACK, and its restored rows do not leak into the '
        'replacement task', () {
      fakeAsync((async) {
        // Microtasks AND the serialized drainer's zero-duration batch yields.
        void pump() => async.elapse(Duration.zero);

        final r = _Rig();
        r.claim();
        r.holdCommit = Completer<void>();
        r.failHeldCommit = true;
        final held = r.holdCommit!;

        // A complete burst whose durable commit parks mid-await.
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 800));
        r.rx(_historyEnd(expected: 1, token: 0x9800));
        pump();
        expect(r.successResults, isEmpty, reason: 'commit still parked');

        // Three more frames AND a COMPLETE arrive and queue up BEHIND the
        // parked marker — they belong to the old task.
        r.rx(_gen5V18Inner(ts: ts + 1, counter: 801));
        r.rx(_gen5V18Inner(ts: ts + 2, counter: 802));
        r.rx(_gen5V18Inner(ts: ts + 3, counter: 803));
        r.rx(_historyComplete());

        // The idle watchdog ends the task while the commit is parked.
        async.elapse(const Duration(seconds: 61));
        expect(r.aborts, hasLength(1));

        // The parked commit resolves by FAILING: DrainController restores
        // its snapshot into the shared buffer. The stale continuation must
        // not ACK, and the old task's queued COMPLETE must not record a
        // success terminal for it.
        held.complete();
        pump();
        expect(r.successResults, isEmpty,
            reason: 'a stale continuation may not echo the trim token');
        expect(
          r.logs.any((l) => l.contains('HistoryComplete — backlog drained')),
          isFalse,
          reason: 'a stale-generation COMPLETE is dropped, not completed',
        );

        // A replacement task starts. It must first DISCARD the failed
        // commit's restored rows (never ACKed — the band re-delivers them),
        // and the old task's queued frames must not be counted into its
        // burst window.
        var claimed = false;
        r.engine.debugStartHistoricalRefresh().then((v) => claimed = v);
        pump();
        expect(claimed, isTrue);
        expect(
          r.logs.any((l) => l.contains('leftover un-ACKed buffer')),
          isTrue,
          reason: 'the restored row is discarded before the new task starts',
        );
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts + 10, counter: 810));
        r.rx(_gen5V18Inner(ts: ts + 11, counter: 811));
        r.rx(_historyEnd(expected: 5, token: 0x9810));
        pump();

        expect(r.shortLines, hasLength(1),
            reason: 'the new burst is short — 2 of 5');
        expect(r.shortLines.last, contains('traffic=2'),
            reason: 'the old task\'s three leftover frames counted for '
                'nothing in the new window');
        // The refusal commits the short burst without a token — and it must
        // carry ONLY the new task's two rows, not the old task's restored one.
        expect(r.committedRows, [2],
            reason: 'the failed commit\'s restored row did not ride into the '
                'replacement task\'s commit');
      });
    });

    test('a task claim waits for a marker handler still parked in a commit, '
        'not only for the abort', () {
      fakeAsync((async) {
        void pump() => async.elapse(Duration.zero);
        final r = _Rig();
        r.claim();
        r.holdCommit = Completer<void>();
        final held = r.holdCommit!;

        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 850));
        r.rx(_historyEnd(expected: 1, token: 0x9850));
        pump();

        // The watchdog ends the task; its abort completes immediately, but
        // the marker handler is STILL parked inside the held commit.
        async.elapse(const Duration(seconds: 61));
        expect(r.aborts, hasLength(1));

        // A claim during that window must wait for full quiescence — if it
        // ran now, a later commit FAILURE would re-buffer the old task's rows
        // into the controller the new task is already using.
        var claimed = false;
        r.engine.debugStartHistoricalRefresh().then((v) => claimed = v);
        pump();
        expect(claimed, isFalse,
            reason: 'the old task\'s handler has not unwound yet');
        expect(r.drainRequests, isEmpty,
            reason: 'no opcode 22 before the old task is quiescent');

        held.complete();
        pump();
        expect(claimed, isTrue);
        expect(r.drainRequests, hasLength(1));
      });
    });
  });

  group('T3b — a new task has no active burst until its first START', () {
    test('a HISTORY_END before the task\'s first HISTORY_START is a doc-05 '
        'duplicate — dropped, never validated, no ACK', () async {
      final r = _Rig();
      expect(await r.engine.debugStartHistoricalRefresh(), isTrue);

      // A late END straggling in from a previous task, inside the window
      // between opcode 22 and the strap's first START.
      r.rx(_historyEnd(expected: 3, token: 0x9350));
      await pumpEventQueue();
      expect(r.shortLines, isEmpty, reason: 'never judged by the count gate');
      expect(r.failureResults, isEmpty);
      expect(r.successResults, isEmpty);
      expect(
        r.logs.any((l) => l.contains('before this task\'s first '
            'HISTORY_START')),
        isTrue,
      );

      // The real task then proceeds normally.
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 350));
      r.rx(_historyEnd(expected: 1, token: 0x9351));
      await pumpEventQueue();
      expect(r.successResults, hasLength(1));
    });

    test('historical data before the first START is dropped, not ingested '
        'into the coming burst', () async {
      final r = _Rig();
      expect(await r.engine.debugStartHistoricalRefresh(), isTrue);

      // Two stragglers from the previous task…
      r.rx(_gen5V18Inner(ts: ts, counter: 360));
      r.rx(_gen5V18Inner(ts: ts + 1, counter: 361));
      // …then the real burst: START + one frame, expected 1.
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts + 2, counter: 362));
      r.rx(_historyEnd(expected: 1, token: 0x9360));
      await pumpEventQueue();

      expect(r.successResults, hasLength(1),
          reason: '1/1 — the stragglers neither inflated the tally…');
      expect(r.committedRows, [1],
          reason: '…nor were they buffered into the burst\'s commit');
    });
  });

  group('T9 — session replacement', () {
    test('an ACK retry loop finishing for session A neither writes onto nor '
        'aborts session B', () {
      fakeAsync((async) {
        final r = _Rig()..failSuccessResults = true;
        r.claim();
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 900));
        r.rx(_historyEnd(expected: 1, token: 0x9900));
        async.elapse(Duration.zero);
        expect(r.successResults, hasLength(1),
            reason: 'first ACK attempt failed; retry backoff pending');

        // The link is replaced while the retry loop sleeps.
        r.connect();
        final writesAtReplacement = r.writes.length;

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(r.writes.length, writesAtReplacement,
            reason: 'no retry, result or abort may reach the new session — '
                'the owner-bound write and the stale-session guards both '
                'stand between them');
        expect(r.logs.where((l) => l.contains('BATCH-ACK FAILED')), isEmpty,
            reason: 'the stale continuation stops silently — it does not '
                'run the failure bookkeeping for a session it no longer owns');
      });
    });

    test('an old task\'s abort unwinding after session replacement does not '
        'release offload state it no longer owns', () async {
      final r = _Rig()..failFailureResults = true;
      r.claim();
      r.holdAbort = Completer<bool>();

      // Terminal on session A with the abort write parked open.
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 950));
      r.rx(_historyEnd(expected: 3, token: 0x9950));
      await pumpEventQueue();
      expect(r.aborts, hasLength(1), reason: 'abort issued and parked');

      // The link is replaced while that write is in flight, and the
      // replacement session claims its own task and its drain traffic raises
      // the offload state (the claim stands in for that session's INIT).
      r.connect();
      r.claim();
      r.rx(_gen5V18Inner(ts: ts + 1, counter: 951));
      await pumpEventQueue();
      expect(r.engine.offloadActive, isTrue);

      // The old abort finally resolves — its boundary must not clear the
      // NEW session's claim on the way out.
      r.holdAbort!.complete(true);
      r.holdAbort = null;
      await pumpEventQueue();
      expect(r.engine.offloadActive, isTrue,
          reason: 'the ending task may only release state it still owns');
    });
  });

  group('T-INIT — the INIT drain honours the lifecycle barrier and its '
      'session', () {
    test(
        'a link that dies while INIT waits out an old parked commit sends no '
        'INIT traffic and does not report a successful setup', () {
      fakeAsync((async) {
        void pump() => async.elapse(Duration.zero);
        final r = _Rig();
        r.claim();
        r.holdCommit = Completer<void>();
        final held = r.holdCommit!;

        // Session A's marker handler parks inside its commit…
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 970));
        r.rx(_historyEnd(expected: 1, token: 0x9970));
        pump();

        // …while session A's connect continuation reaches the INIT claim and
        // waits on the lifecycle barrier.
        bool? ready;
        r.engine.debugStartInitDrain().then((v) => ready = v);
        pump();
        expect(ready, isNull, reason: 'the barrier is held by the commit');

        // The link is replaced while the barrier is held.
        r.connect();
        final at = r.writes.length;

        held.complete();
        pump();
        expect(ready, isFalse,
            reason: 'a stale connect continuation must not report READY');
        expect(r.writes.length, at,
            reason: 'no GET_DATA_RANGE/opcode 22 for a dead session — and '
                'nothing on the replacement link');
      });
    });

    test(
        'an INIT whose last write succeeds onto a link that dies before the '
        'continuation resumes still does not report a successful setup',
        () async {
      final r = _Rig()..dropLinkAfterDrainRequest = true;
      // The whole INIT sequence is written successfully — but the session is
      // replaced the instant the final (drain-trigger) write lands, i.e.
      // before _startInitDrain's continuation can run. The setup verdict
      // must be false: a READY report for a dead session arms the caller's
      // post-connect flows against a link that no longer exists.
      expect(await r.engine.debugStartInitDrain(), isFalse);
      expect(r.drainRequests, hasLength(1),
          reason: 'the write itself did go out — only the verdict changes');
    });

    test('sendInit is session-bound — a link swap mid-sequence stops the '
        'tail and reports not-written', () async {
      final r = _Rig();
      final init = r.engine.sendInit();
      // Let the range poll go out, then swap the link inside the 120 ms gap
      // before SEND_HISTORICAL_DATA.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(r.rangePolls, hasLength(1));
      final at = r.writes.length;
      r.connect();

      expect(await init, isFalse);
      expect(r.writes.length, at,
          reason: 'the drain trigger must not land on the replacement link');
      expect(r.drainRequests, isEmpty);
    });
  });

  group('T10 — gen4 stays advisory and byte-identical', () {
    test('a short gen4 burst is still ACKed with the verbatim token and '
        'never accumulates failures', () async {
      final r = _Rig(band: BandProfile.gen4);
      r.claim();
      for (var i = 0; i < 4; i++) {
        r.rx(_historyStart());
        r.rx(_gen4V24Inner(ts: ts + i, counter: 1000 + i));
        r.rx(_historyEnd(expected: 5, token: 0xA000 + i));
        await pumpEventQueue();
      }

      expect(r.failureResults, isEmpty,
          reason: 'gen4 never sends the failure result — the gate is '
              'advisory there');
      expect(r.aborts, isEmpty);
      expect(r.shortLines, isEmpty);
      expect(
        r.logs.where((l) => l.contains('ADVISORY, gen4')).length,
        4,
        reason: 'the mismatch is recorded for observability only',
      );
      expect(r.successResults, hasLength(4));
      // Byte-identical ACK: `01` + the verbatim 8-byte token.
      final last = r.successResults.last;
      expect(last.body.take(9).toList(), [0x01, ..._tokenBytes(0xA003)]);
    });
  });

  group('T11 — commit-before-ACK ordering', () {
    test('the durable commit with the trim token precedes the ACK write', () async {
      final r = _Rig();
      r.claim();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1100));
      r.rx(_historyEnd(expected: 1, token: 0xB100));
      await pumpEventQueue();

      expect(r.successResults, hasLength(1));
      final commitAt =
          r.events.indexWhere((e) => e.startsWith('commit:') && !e.endsWith(':null'));
      final ackAt = r.events
          .indexWhere((e) => e == 'write:${Cmd.historicalDataResult}:1');
      expect(commitAt, isNonNegative,
          reason: 'the trim token must be committed durably');
      expect(ackAt, greaterThan(commitAt),
          reason: 'the ACK is written only after the commit reported durable');
      // And the ACK echoes the token verbatim.
      expect(r.successResults.single.body.take(9).toList(),
          [0x01, ..._tokenBytes(0xB100)]);
    });
  });

  group('T12 — the waiter only waits; an unanswered request is ended', () {
    test(
        'a runSync waiter timing out mid-burst leaves the task claimed and '
        'the same task is not re-claimed', () async {
      final r = _Rig();
      expect(await r.engine.debugStartHistoricalRefresh(), isTrue);
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1200));
      await pumpEventQueue();
      var c = 1201;
      final feeder = Timer.periodic(const Duration(milliseconds: 400),
          (_) => r.rx(_gen5V18Inner(ts: ts + (c - 1200), counter: c++)));
      final report =
          await r.engine.runSync(timeout: const Duration(seconds: 2));
      feeder.cancel();
      expect(report.complete, isFalse);
      expect(r.engine.offloadActive, isTrue,
          reason: 'a waiter that stops waiting must leave the transfer '
              'claimed — only the task\'s own terminals release it');

      // The burst is still ours: a second trigger is refused…
      expect(await r.engine.debugStartHistoricalRefresh(), isFalse);
      expect(r.drainRequests, hasLength(1),
          reason: 'no second opcode 22 on top of a running transfer');

      // …and the burst finishes normally, committed before it is ACKed.
      r.rx(_historyEnd(expected: c - 1200, token: 0xC100));
      await pumpEventQueue();
      expect(r.successResults, hasLength(1));
      expect(r.successResults.single.body.take(9).toList(),
          [0x01, ..._tokenBytes(0xC100)]);
      final commitAt = r.events.indexWhere(
          (e) => e.startsWith('commit:') && !e.endsWith(':null'));
      final ackAt = r.events
          .indexWhere((e) => e == 'write:${Cmd.historicalDataResult}:1');
      expect(commitAt, isNonNegative);
      expect(ackAt, greaterThan(commitAt),
          reason: 'commit-before-ACK holds across the waiter timeout');
    });

    test('reports hand over every record and ACK exactly once — before, '
        'during and between waits', () async {
      final r = _Rig();
      expect(await r.engine.debugStartHistoricalRefresh(), isTrue);
      var c = 1250;
      var fed = 0;
      void rec() {
        r.rx(_gen5V18Inner(ts: ts + (c - 1250), counter: c++));
        fed++;
      }

      // Before anyone waits: a whole ACKed burst.
      r.rx(_historyStart());
      rec();
      rec();
      r.rx(_historyEnd(expected: 2, token: 0xC500));
      await pumpEventQueue();
      expect(r.successResults, hasLength(1));
      var feeder = Timer.periodic(const Duration(milliseconds: 300), (_) => rec());
      final first = await r.engine.runSync(timeout: const Duration(seconds: 2));
      feeder.cancel();
      await pumpEventQueue();
      // Between the waits: another ACKed burst.
      r.rx(_historyStart());
      rec();
      r.rx(_historyEnd(expected: 1, token: 0xC501));
      await pumpEventQueue();
      expect(r.successResults, hasLength(2));
      feeder = Timer.periodic(const Duration(milliseconds: 300), (_) => rec());
      final second =
          await r.engine.runSync(timeout: const Duration(seconds: 2));
      feeder.cancel();
      expect(first.batches, 1,
          reason: 'the ACK that landed before the first wait is progress');
      expect(second.batches, 1, reason: 'the ACK between the waits too');
      expect(first.records + second.records, fed,
          reason: 'every record exactly once across the two reports');
    });

    test('runSync no longer throws when the ledger write fails', () async {
      final r = _Rig();
      // No catchError: the ledger write is diagnostics only and must not
      // escape the wait (it throws in the test host — no database).
      final report =
          await r.engine.runSync(timeout: const Duration(seconds: 1));
      expect(report.complete, isFalse);
    });

    test(
        'an unanswered SEND_HISTORICAL_DATA is aborted once after the '
        'window, retried once, then left alone', () {
      fakeAsync((async) {
        final r = _Rig();
        r.engine.debugStartHistoricalRefresh();
        async.elapse(Duration.zero);
        expect(r.drainRequests, hasLength(1));

        async.elapse(const Duration(seconds: 9));
        expect(r.aborts, isEmpty, reason: 'still inside the window');
        expect(r.engine.offloadActive, isTrue);

        async.elapse(const Duration(seconds: 2));
        expect(r.aborts, hasLength(1),
            reason: 'the request is ended with exactly one abort');
        expect(r.engine.offloadActive, isFalse);
        expect(r.engine.offloadSnapshot['last_hps_reason'], 'no_history_start');
        expect(r.engine.offloadSnapshot['first_start_timeouts'], 1);

        // One retry after the settle (+ the real-clock 0x16 floor).
        async.elapse(const Duration(seconds: 10));
        expect(r.drainRequests, hasLength(2));
        expect(r.rangePolls, hasLength(1));

        // The retry goes unanswered too: one more abort…
        async.elapse(const Duration(seconds: 12));
        expect(r.aborts, hasLength(2));

        // …and no further retry this session.
        async.elapse(const Duration(seconds: 30));
        expect(r.drainRequests, hasLength(2));
        expect(r.aborts, hasLength(2));
        expect(r.engine.offloadActive, isFalse);
        expect(r.successResults, isEmpty);
        expect(r.failureResults, isEmpty);
      });
    });

    test('a START inside the window cancels it', () {
      fakeAsync((async) {
        final r = _Rig();
        r.engine.debugStartHistoricalRefresh();
        async.elapse(const Duration(seconds: 3));
        r.rx(_historyStart());
        async.elapse(const Duration(seconds: 30));
        expect(r.aborts, isEmpty,
            reason: 'only the 60 s idle watchdog may end it from here');
        expect(
            r.engine.offloadSnapshot['first_start_watchdog_armed'], isFalse);
        expect(r.engine.offloadActive, isTrue);
      });
    });

    test('an answer that beats the write\'s return still counts', () {
      fakeAsync((async) {
        final r = _Rig()..startOnDrainRequest = true;
        r.engine.debugStartHistoricalRefresh();
        async.elapse(const Duration(seconds: 30));
        expect(r.drainRequests, hasLength(1));
        expect(r.aborts, isEmpty);
        expect(
            r.engine.offloadSnapshot['first_start_watchdog_armed'], isFalse);
      });
    });

    test('a HISTORY_COMPLETE with no burst satisfies the watchdog', () {
      fakeAsync((async) {
        final r = _Rig();
        r.engine.debugStartHistoricalRefresh();
        async.elapse(Duration.zero);
        r.rx(_historyComplete());
        async.elapse(const Duration(seconds: 30));
        expect(r.aborts, isEmpty);
        expect(r.engine.offloadActive, isFalse,
            reason: 'an empty band ends the task through COMPLETE');
      });
    });

    test('gen5 straggler data does not satisfy it', () {
      fakeAsync((async) {
        final r = _Rig();
        r.engine.debugStartHistoricalRefresh();
        async.elapse(Duration.zero);
        r.rx(_gen5V18Inner(ts: ts, counter: 1250)); // pre-START, dropped
        async.elapse(const Duration(seconds: 11));
        expect(r.aborts, hasLength(1));
      });
    });

    test('gen4: a data frame satisfies it', () {
      fakeAsync((async) {
        final r = _Rig(band: BandProfile.gen4);
        r.engine.debugStartHistoricalRefresh();
        async.elapse(Duration.zero);
        r.rx(_gen4V24Inner(ts: ts, counter: 1260));
        async.elapse(const Duration(seconds: 11));
        expect(r.aborts, isEmpty);
      });
    });

    test('a straggler during the claim\'s own waits is not the answer',
        () {
      fakeAsync((async) {
        final r = _Rig(band: BandProfile.gen4);
        // gen4 accepts any history traffic as the answer — but only to a
        // request that is actually going out. This record lands while the
        // claim is still reading the clock: it cannot be an answer, and with
        // no task of ours just ended it reads as another client's transfer,
        // so the request is not sent into it.
        r.onClockRequest = () => r.rx(_gen4V24Inner(ts: ts, counter: 1270));
        bool? sent;
        r.engine.debugStartHistoricalRefresh().then((v) => sent = v);
        async.elapse(const Duration(seconds: 1));
        expect(sent, isFalse);
        expect(r.drainRequests, isEmpty);
        expect(
            r.engine.offloadSnapshot['first_start_watchdog_armed'], isFalse);
        async.elapse(const Duration(seconds: 11));
        expect(r.aborts, isEmpty);
        expect(r.engine.offloadActive, isFalse);
      });
    });

    for (final band in [BandProfile.gen4, BandProfile.gen5]) {
      test('INIT: a transfer starting during its earlier packets is not '
          'answered, and the drain request is withheld '
          '(${band == BandProfile.gen5 ? 'gen5' : 'gen4'})', () {
        fakeAsync((async) {
          final r = _Rig(band: band);
          var injected = false;
          r.onWriteOpcode = (op) {
            if (injected || op == Cmd.sendHistoricalData) return;
            injected = true;
            // Another client's burst, before our opcode 22 has gone out.
            r.rx(_historyStart());
            r.rx(band == BandProfile.gen5
                ? _gen5V18Inner(ts: ts, counter: 1280)
                : _gen4V24Inner(ts: ts, counter: 1280));
            r.rx(_historyEnd(expected: 1, token: 0xC280));
          };
          bool? ready;
          r.engine.debugStartInitDrain().then((v) => ready = v);
          async.elapse(const Duration(seconds: 2));
          expect(injected, isTrue);
          expect(ready, isTrue);
          expect(r.drainRequests, isEmpty,
              reason: 'no request into a transfer that just started');
          expect(r.successResults, isEmpty, reason: 'its END is not ours');
          expect(r.failureResults, isEmpty);
          expect(r.logs.any((l) => l.contains('another client started '
              'transferring history during INIT')), isTrue);
          expect(r.engine.offloadActive, isFalse);
          async.elapse(const Duration(seconds: 7));
          expect(r.aborts, isEmpty);
          expect(r.drainRequests, isEmpty);
          // Once that transfer has gone quiet the deferred drain is
          // re-requested rather than left for the 15-min periodic timer.
          async.elapse(const Duration(seconds: 4));
          expect(r.drainRequests, hasLength(1));
          async.elapse(const Duration(seconds: 60));
          expect(r.aborts, hasLength(r.drainRequests.length),
              reason: 'every abort ends a request that went out, none the '
                  'deferred claim');
        });
      });
    }

    test('an auto-continue whose waits receive traffic still times out '
        'unanswered', () {
      fakeAsync((async) {
        final r = _Rig(band: BandProfile.gen4);
        var clocks = 0;
        r.onClockRequest = () {
          // The second GET_CLOCK is the auto-continue's: the COMPLETE handler
          // holds the queue while it runs, and this record queues behind it.
          if (++clocks == 2) r.rx(_gen4V24Inner(ts: ts + 5, counter: 1291));
        };
        r.engine.debugStartHistoricalRefresh();
        async.elapse(Duration.zero);
        r.rx(_historyStart());
        r.rx(_gen4V24Inner(ts: ts, counter: 1290));
        r.rx(_historyEnd(expected: 1, token: 0xC290));
        r.rx(_historyComplete());
        // (+ the 5 s 0x16 floor, which runs on the real clock)
        async.elapse(const Duration(seconds: 6));
        expect(clocks, 2);
        expect(r.drainRequests, hasLength(2), reason: 'auto-continued');
        async.elapse(const Duration(seconds: 11));
        expect(r.aborts, hasLength(1),
            reason: 'the record arrived before the request went out, so it '
                'cannot be the band answering it');
      });
    });

    test('a late START during the retry\'s own waits does not refill the '
        'budget', () {
      fakeAsync((async) {
        final r = _Rig();
        var clocks = 0;
        r.onClockRequest = () {
          if (++clocks == 2) r.rx(_historyStart()); // the retry's GET_CLOCK
        };
        r.engine.debugStartHistoricalRefresh();
        async.elapse(const Duration(seconds: 11));
        expect(r.aborts, hasLength(1));
        async.elapse(const Duration(seconds: 10));
        expect(clocks, 2);
        // Before our request went out, that START is indistinguishable from
        // another client starting: the retry stands down rather than send
        // into it, and the START refilled nothing.
        expect(r.drainRequests, hasLength(1));
        expect(r.engine.offloadSnapshot['no_start_retries'], 1);
        // ...but it is not stranded: once the window closes it re-requests.
        async.elapse(const Duration(seconds: 21));
        expect(r.drainRequests, hasLength(2));
        // Unanswered again: its own watchdog ends it, and the spent retry
        // budget stops the chain there.
        async.elapse(const Duration(seconds: 60));
        expect(r.drainRequests, hasLength(2));
        expect(r.aborts, hasLength(2));
      });
    });

    test('a late COMPLETE during the auto-continue\'s waits does not finish '
        'the replacement task', () {
      fakeAsync((async) {
        final r = _Rig();
        var clocks = 0;
        r.onClockRequest = () {
          // The previous task's COMPLETE, re-offered while the auto-continue
          // has claimed but not yet sent its request.
          if (++clocks == 2) r.rx(_historyComplete());
        };
        r.engine.debugStartHistoricalRefresh();
        async.elapse(Duration.zero);
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1330));
        r.rx(_historyEnd(expected: 1, token: 0xC330));
        r.rx(_historyComplete());
        async.elapse(const Duration(seconds: 6)); // (+ the real-clock floor)
        expect(clocks, 2);
        expect(r.drainRequests, hasLength(2), reason: 'auto-continued');
        expect(r.engine.offloadActive, isTrue,
            reason: 'the replacement task is still waiting on its answer');
        // Before our request went out it was not ours: only observed.
        expect(r.engine.offloadSnapshot['foreign_markers_seen'], 1);
        async.elapse(const Duration(seconds: 11));
        expect(r.aborts, hasLength(1),
            reason: 'its own watchdog ends it, not the leftover COMPLETE');
      });
    });

    test('a request queued behind another write is not answerable until its '
        'bytes go out — and is withheld if a transfer starts meanwhile', () {
      fakeAsync((async) {
        final r = _Rig();
        r.holdOpcode = Cmd.getBatteryLevel;
        r.holdWrite = Completer<bool>();
        final held = r.holdWrite!;
        r.onClockRequest = () {
          // Something else takes the write chain just before our request.
          r.engine.debugWriteRaw(buildCommand(
              99, Cmd.getBatteryLevel, const [], BandProfile.gen5));
        };
        bool? sent;
        r.engine.debugStartHistoricalRefresh().then((v) => sent = v);
        async.elapse(Duration.zero);
        expect(r.drainRequests, isEmpty, reason: 'queued behind the held write');
        // A START while our request is still queued: not ours (nothing is
        // until the bytes go out) — another client starting.
        r.rx(_historyStart());
        async.elapse(Duration.zero);
        held.complete(true);
        async.elapse(const Duration(seconds: 1));
        expect(sent, isFalse);
        expect(r.drainRequests, isEmpty,
            reason: 'checked again at the moment the bytes would go out');
        expect(r.logs.any((l) => l.contains('while this request was queued')),
            isTrue);
        expect(r.engine.offloadActive, isFalse);
        async.elapse(const Duration(seconds: 11));
        expect(r.drainRequests, hasLength(1), reason: 're-requested once quiet');
        async.elapse(const Duration(seconds: 60));
        expect(r.aborts, hasLength(r.drainRequests.length));
      });
    });

    test('a refresh request whose task ends while it is queued is withheld',
        () {
      fakeAsync((async) {
        final r = _Rig();
        r.holdOpcode = Cmd.getBatteryLevel;
        r.holdWrite = Completer<bool>();
        final held = r.holdWrite!;
        r.onClockRequest = () => r.engine.debugWriteRaw(
            buildCommand(99, Cmd.getBatteryLevel, const [], BandProfile.gen5));
        bool? sent;
        r.engine.debugStartHistoricalRefresh().then((v) => sent = v);
        async.elapse(Duration.zero);
        expect(r.drainRequests, isEmpty, reason: 'queued behind the held write');
        // The task ends while its opcode 22 still sits in the write chain.
        r.engine.endHistoryTask(reason: 'test');
        async.elapse(Duration.zero);
        held.complete(true);
        async.elapse(const Duration(seconds: 1));
        expect(r.drainRequests, isEmpty,
            reason: 'no drain request for a task that already ended');
        expect(r.aborts, hasLength(1));
        expect(sent, isFalse);
        expect(r.engine.offloadActive, isFalse);
        async.elapse(const Duration(seconds: 11));
        expect(r.aborts, hasLength(1), reason: 'no watchdog for it either');
      });
    });

    test('an INIT request whose task ends while it is queued is withheld', () {
      fakeAsync((async) {
        final r = _Rig();
        r.holdOpcode = Cmd.getBatteryLevel;
        r.holdWrite = Completer<bool>();
        final held = r.holdWrite!;
        bool? ready;
        r.engine.debugStartInitDrain().then((v) => ready = v);
        async.elapse(Duration.zero);
        expect(r.rangePolls, hasLength(1));
        // Something takes the write chain inside INIT's 120 ms gap, so the
        // opcode 22 queues behind it — then the task ends.
        r.engine.debugWriteRaw(
            buildCommand(99, Cmd.getBatteryLevel, const [], BandProfile.gen5));
        async.elapse(const Duration(milliseconds: 150));
        r.engine.endHistoryTask(reason: 'test');
        async.elapse(Duration.zero);
        held.complete(true);
        async.elapse(const Duration(seconds: 1));
        expect(r.drainRequests, isEmpty);
        expect(r.aborts, hasLength(1));
        expect(ready, isTrue, reason: 'the link itself is up');
        expect(r.engine.offloadActive, isFalse);
        async.elapse(const Duration(seconds: 11));
        expect(r.aborts, hasLength(1));
      });
    });

    for (final init in [false, true]) {
      test('${init ? 'INIT' : 'refresh'}: a request whose write failed is '
          'answered by nothing', () {
        fakeAsync((async) {
          final r = _Rig();
          r.holdOpcode = Cmd.sendHistoricalData;
          r.holdWrite = Completer<bool>();
          final held = r.holdWrite!;
          bool? result;
          (init
                  ? r.engine.debugStartInitDrain()
                  : r.engine.debugStartHistoricalRefresh())
              .then((v) => result = v);
          async.elapse(const Duration(seconds: 1));
          held.complete(false); // the transport refused the bytes
          async.elapse(Duration.zero);
          expect(result, init ? isTrue : isFalse);
          expect(r.engine.offloadActive, isFalse);
          // A straggler COMPLETE from before: it answers no request of ours.
          r.rx(_historyComplete());
          async.elapse(Duration.zero);
          expect(r.engine.offloadSnapshot['history_completions'], 0);
        });
      });
    }

    test('INIT arms it too', () {
      fakeAsync((async) {
        final r = _Rig();
        bool? ready;
        r.engine.debugStartInitDrain().then((v) => ready = v);
        async.elapse(const Duration(seconds: 1));
        expect(ready, isTrue);
        expect(r.drainRequests, hasLength(1));
        expect(r.aborts, isEmpty);
        async.elapse(const Duration(seconds: 11));
        expect(r.aborts, hasLength(1));
        expect(r.engine.offloadActive, isFalse);
      });
    });

    test('a START landing just after each deadline does not refill the '
        'retry budget', () {
      fakeAsync((async) {
        final r = _Rig();
        r.engine.debugStartHistoricalRefresh();
        async.elapse(const Duration(seconds: 11));
        expect(r.aborts, hasLength(1));
        // Late: the task already ended. Indistinguishable from another
        // client starting a transfer, so the pending retry stands down.
        r.rx(_historyStart());
        async.elapse(const Duration(seconds: 11));
        expect(r.drainRequests, hasLength(1));
        expect(r.logs.any((l) => l.contains('another client is transferring')),
            isTrue);

        // A later request of ours goes unanswered too (it first waits out
        // the 5 s 0x16 floor, which runs on the real clock).
        r.engine.debugStartHistoricalRefresh();
        async.elapse(const Duration(seconds: 17));
        expect(r.drainRequests, hasLength(2));
        expect(r.aborts, hasLength(2));
        final timeouts = r.logs
            .where((l) => l.contains('no answer to SEND_HISTORICAL_DATA'))
            .toList();
        expect(timeouts, hasLength(2));
        expect(timeouts.last, contains('no further retry this session'),
            reason: 'the ended task\'s late START refilled nothing');
        r.rx(_historyStart()); // late again
        async.elapse(const Duration(seconds: 60));
        expect(r.drainRequests, hasLength(2));
        expect(r.engine.offloadSnapshot['no_start_retries'], 1);
      });
    });

    test('gen4: data before an accepted START still refills the budget', () {
      fakeAsync((async) {
        final r = _Rig(band: BandProfile.gen4);
        r.engine.debugStartHistoricalRefresh();
        async.elapse(const Duration(seconds: 11));
        expect(r.aborts, hasLength(1));
        async.elapse(const Duration(seconds: 10));
        expect(r.drainRequests, hasLength(2));
        expect(r.engine.offloadSnapshot['no_start_retries'], 1);

        // The retry is answered — gen4 data first (that alone disarms the
        // watchdog), then the burst's START.
        r.rx(_gen4V24Inner(ts: ts, counter: 1600));
        r.rx(_historyStart());
        async.elapse(Duration.zero);
        expect(r.engine.offloadSnapshot['no_start_retries'], 0,
            reason: 'an accepted START refills the budget');
      });
    });

    test('gen4: history arriving off the data characteristic disarms the '
        'watchdog too', () {
      fakeAsync((async) {
        final r = _Rig(band: BandProfile.gen4);
        r.engine.debugStartHistoricalRefresh();
        async.elapse(Duration.zero);
        expect(r.engine.offloadSnapshot['first_start_watchdog_armed'], isTrue);
        // Reassembled on `events`: the immediate path, not the queue.
        r.rx(_gen4V24Inner(ts: ts, counter: 1610), role: 'events');
        async.elapse(const Duration(seconds: 11));
        expect(r.aborts, isEmpty);
        expect(
            r.engine.offloadSnapshot['first_start_watchdog_armed'], isFalse);
      });
    });

    test('auto-continue refused before claiming releases the claim',
        () async {
      final r = _Rig();
      r.claim();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1300));
      r.rx(_historyEnd(expected: 1, token: 0xC300));
      await pumpEventQueue();
      expect(r.successResults, hasLength(1));
      final requestsBefore = r.drainRequests.length;

      // The ECG owner holds the transport WITHOUT cancelling history, so the
      // auto-continue at COMPLETE is refused before it claims anything.
      final lease = r.engine.ecgAcquire()!;
      r.rx(_historyComplete());
      await pumpEventQueue();
      expect(r.logs.any((l) => l.contains('[SYNC] auto-continue')), isTrue,
          reason: 'the post-offload policy decided to continue');
      expect(r.logs.any((l) => l.contains('refused — the ECG owner')), isTrue);
      expect(r.drainRequests, hasLength(requestsBefore),
          reason: 'the auto-continue was refused by the ECG lease');
      expect(r.engine.offloadActive, isFalse,
          reason: 'no task owns the offload — the claim must not be orphaned');
      r.engine.ecgRelease(lease);
    });

    test('an auto-continued request is covered by the first-START watchdog',
        () {
      fakeAsync((async) {
        final r = _Rig()..claim();
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1310));
        r.rx(_historyEnd(expected: 1, token: 0xC310));
        r.rx(_historyComplete());
        async.elapse(const Duration(seconds: 1));
        expect(r.logs.any((l) => l.contains('[SYNC] auto-continue')), isTrue);
        expect(r.drainRequests, hasLength(1),
            reason: 'the auto-continue asked for more');
        expect(
            r.engine.offloadSnapshot['first_start_watchdog_armed'], isTrue);

        // The band never answers it: one abort, one retry, then left alone.
        async.elapse(const Duration(seconds: 10));
        expect(r.aborts, hasLength(1));
        expect(r.engine.offloadSnapshot['last_hps_reason'], 'no_history_start');
        async.elapse(const Duration(seconds: 10));
        expect(r.drainRequests, hasLength(2));
        async.elapse(const Duration(seconds: 60));
        expect(r.aborts, hasLength(2));
        expect(r.drainRequests, hasLength(2));
        expect(r.successResults, hasLength(1));
      });
    });

    test('an auto-continued request the band answers keeps its retry budget',
        () {
      fakeAsync((async) {
        final r = _Rig()..claim();
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1320));
        r.rx(_historyEnd(expected: 1, token: 0xC320));
        r.rx(_historyComplete());
        async.elapse(const Duration(seconds: 1));
        expect(r.drainRequests, hasLength(1));
        r.rx(_historyStart()); // the band answers the auto-continue
        async.elapse(const Duration(seconds: 30));
        expect(r.aborts, isEmpty);
        expect(
            r.engine.offloadSnapshot['first_start_watchdog_armed'], isFalse);
        expect(r.engine.offloadSnapshot['no_start_retries'], 0);
      });
    });
  });

  group('T13 — transfers this app did not request', () {
    String hex(List<int> b) =>
        b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

    test('an unsolicited gen5 transfer is never answered', () async {
      final r = _Rig(); // connected, NO task claimed
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1400));
      r.rx(_gen5V18Inner(ts: ts + 1, counter: 1401));
      r.rx(_historyEnd(expected: 2, token: 0xD100));
      r.rx(_historyComplete());
      await pumpEventQueue();
      expect(r.writes, isEmpty,
          reason: 'no result, abort, request or clock write into a '
              'transfer another client owns');
      expect(r.engine.offloadActive, isFalse);
      expect(r.committedTokens, everyElement(isNull),
          reason: 'banked without a trim token — our cursor never moves');
      expect(r.committedRows.fold<int>(0, (a, b) => a + b), 2,
          reason: 'every record we saw is kept');
    });

    test('a short unsolicited burst gets no failure result', () async {
      final r = _Rig();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1410));
      r.rx(_historyEnd(expected: 5, token: 0xD200));
      await pumpEventQueue();
      expect(r.writes, isEmpty);
      expect(r.shortLines, isEmpty);
      expect(r.committedTokens, everyElement(isNull));
      expect(r.committedRows.fold<int>(0, (a, b) => a + b), 1);
    });

    test('unsolicited traffic arms no watchdog', () {
      fakeAsync((async) {
        final r = _Rig();
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1420));
        async.elapse(const Duration(seconds: 200));
        expect(r.aborts, isEmpty);
        expect(r.drainRequests, isEmpty);
        expect(r.rangePolls, isEmpty);
        expect(r.writes, isEmpty);
      });
    });

    test('an unsolicited COMPLETE runs no post-offload policy', () async {
      final r = _Rig();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1430));
      r.rx(_historyEnd(expected: 1, token: 0xD400));
      r.rx(_historyComplete());
      await pumpEventQueue();
      expect(r.logs.where((l) => l.contains('auto-continue')), isEmpty);
      expect(r.rangePolls, isEmpty);
      expect(r.engine.offloadSnapshot['last_hps_terminal'], isNull);
      expect(r.writes, isEmpty);
    });

    test('gen4: an unsolicited transfer is not ACKed', () async {
      final r = _Rig(band: BandProfile.gen4);
      r.rx(_historyStart());
      r.rx(_gen4V24Inner(ts: ts, counter: 1440));
      r.rx(_historyEnd(expected: 1, token: 0xD500));
      await pumpEventQueue();
      expect(r.successResults, isEmpty);
      expect(r.writes, isEmpty);
      expect(r.committedTokens, [null]);
      expect(r.committedRows, [1]);
    });

    test('a claim during a live foreign transfer is deferred, then allowed',
        () {
      fakeAsync((async) {
        final r = _Rig();
        r.rx(_historyStart());
        async.elapse(const Duration(seconds: 1));
        bool? first;
        r.engine.debugStartHistoricalRefresh().then((v) => first = v);
        async.elapse(Duration.zero);
        expect(first, isFalse);
        expect(r.drainRequests, isEmpty);
        expect(
            r.logs.any((l) => l.contains('another client is transferring')),
            isTrue);

        // No caller has to come back: the deferred claim re-requests by
        // itself once the transfer has been quiet for the window.
        async.elapse(const Duration(seconds: 8));
        expect(r.drainRequests, isEmpty);
        async.elapse(const Duration(seconds: 3));
        expect(r.drainRequests, hasLength(1));
        expect(r.engine.offloadActive, isTrue);
      });
    });

    test('a deferred claim re-requests soon after the foreign COMPLETE', () {
      fakeAsync((async) {
        final r = _Rig();
        r.rx(_historyStart());
        r.engine.debugStartHistoricalRefresh();
        async.elapse(Duration.zero);
        expect(r.drainRequests, isEmpty);
        r.rx(_historyComplete());
        async.elapse(const Duration(seconds: 4));
        expect(r.drainRequests, hasLength(1),
            reason: 'after the settle, not the full quiet window');
      });
    });

    test('a deferred claim keeps waiting while the foreign transfer streams, '
        'without spinning', () {
      fakeAsync((async) {
        final r = _Rig();
        r.rx(_historyStart());
        r.engine.debugStartHistoricalRefresh();
        var c = 1800;
        final stream = Timer.periodic(const Duration(seconds: 2),
            (_) => r.rx(_gen5V18Inner(ts: ts, counter: c++)));
        async.elapse(const Duration(seconds: 45));
        expect(r.drainRequests, isEmpty);
        expect(async.pendingTimers.length, lessThan(10));
        stream.cancel();
        async.elapse(const Duration(seconds: 21));
        expect(r.drainRequests, hasLength(1));
      });
    });

    test('a foreign COMPLETE closes the window immediately', () async {
      final r = _Rig();
      r.rx(_historyStart());
      r.rx(_historyEnd(expected: 0, token: 0xD700));
      r.rx(_historyComplete());
      await pumpEventQueue();
      expect(await r.engine.debugStartHistoricalRefresh(), isTrue);
      expect(r.drainRequests, hasLength(1));
    });

    test('ownership ends at our COMPLETE', () async {
      final r = _Rig()..claim();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1480));
      r.rx(_historyEnd(expected: 1, token: 0xD800));
      await pumpEventQueue();
      expect(r.successResults, hasLength(1));
      r.rx(_historyComplete());
      await pumpEventQueue();
      // The band re-offers an END after our task is over: not ours to answer.
      r.rx(_historyEnd(expected: 1, token: 0xD800));
      await pumpEventQueue();
      expect(r.successResults, hasLength(1));
      expect(r.failureResults, isEmpty);
      // …and our own re-offer never defers our next request: the
      // auto-continue the COMPLETE decided on went out (after its range
      // poll's 120 ms gap).
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(r.engine.offloadSnapshot['foreign_history_live'], isFalse);
      expect(r.drainRequests, hasLength(1));
      expect(r.engine.offloadSnapshot['history_task_owned'], isTrue);
    });

    test('another client starting while our COMPLETE banks its tail is '
        'seen on arrival', () {
      fakeAsync((async) {
        final r = _Rig()..claim();
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1900));
        r.rx(_historyEnd(expected: 1, token: 0xDD00));
        async.elapse(Duration.zero);
        expect(r.successResults, hasLength(1));
        // A tail record, then our COMPLETE — whose tail commit parks.
        r.rx(_gen5V18Inner(ts: ts + 1, counter: 1901));
        async.elapse(Duration.zero);
        r.holdCommit = Completer<void>();
        final held = r.holdCommit!;
        r.rx(_historyComplete());
        async.elapse(Duration.zero);
        // Another client's START lands behind it, and a refresh races the
        // drainer for the moment the handler finishes.
        r.rx(_historyStart());
        bool? claimed;
        r.engine.debugStartHistoricalRefresh().then((v) => claimed = v);
        async.elapse(Duration.zero);
        held.complete();
        async.elapse(const Duration(milliseconds: 500));
        expect(claimed, isFalse,
            reason: 'the START arrived after our COMPLETE — it is not ours, '
                'whatever ownership said while the tail was banking');
        expect(r.engine.offloadSnapshot['foreign_history_live'], isTrue);
        expect(r.engine.offloadActive, isFalse);

        // The queue is drained; a later trigger is still refused.
        expect(await_(r.engine.debugStartHistoricalRefresh(), async), isFalse);
        expect(r.drainRequests, isEmpty, reason: 'no competing 0x16');
        expect(r.successResults, hasLength(1));
      });
    });

    test('foreign rows never ride into our first token commit', () async {
      final r = _Rig()
        ..claim()
        ..failFailureResults = true;
      // Our task ends by abort; records still in flight arrive after it.
      // They are not ours any more, but they do not look like another
      // client starting either, so the next claim goes ahead at once.
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1488));
      r.rx(_historyEnd(expected: 3, token: 0xD880));
      await pumpEventQueue();
      expect(r.aborts, hasLength(1));
      r.rx(_gen5V18Inner(ts: ts + 1, counter: 1490));
      r.rx(_gen5V18Inner(ts: ts + 2, counter: 1491));
      await pumpEventQueue();
      expect(r.engine.offloadSnapshot['foreign_history_live'], isFalse);
      final eventsBefore = r.events.length;
      expect(await r.engine.debugStartHistoricalRefresh(), isTrue);
      final claimEvents = r.events.sublist(eventsBefore);
      expect(claimEvents.first, 'commit:null',
          reason: 'the foreign buffer is banked before our task is claimed');
      expect(r.committedRows.last, 2);
      expect(
          claimEvents.indexWhere((e) =>
              e.startsWith('write:${Cmd.getClock}:') ||
              e.startsWith('write:${Cmd.sendHistoricalData}:')),
          greaterThan(0));

      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts + 3, counter: 1492));
      r.rx(_historyEnd(expected: 1, token: 0xD900));
      await pumpEventQueue();
      expect(r.committedTokens.last, hex(_tokenBytes(0xD900)));
      expect(r.committedRows.last, 1,
          reason: 'our token commit carries only our burst');
      expect(r.successResults, hasLength(1));
    });

    test('foreign rows banked by the quiet flush, then our own task', () {
      fakeAsync((async) {
        final r = _Rig();
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1495));
        r.rx(_gen5V18Inner(ts: ts + 1, counter: 1496));
        async.elapse(const Duration(seconds: 1));
        bool? first;
        r.engine.debugStartHistoricalRefresh().then((v) => first = v);
        async.elapse(Duration.zero);
        expect(first, isFalse);

        async.elapse(const Duration(seconds: 11));
        expect(r.committedTokens, [null]);
        expect(r.committedRows, [2],
            reason: 'the 5 s quiet flush banked the foreign rows tokenless');

        // The deferred claim re-requested on its own once the window closed.
        expect(r.drainRequests, hasLength(1));
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts + 2, counter: 1497));
        r.rx(_historyEnd(expected: 1, token: 0xD990));
        async.elapse(Duration.zero);
        expect(r.committedTokens.last, hex(_tokenBytes(0xD990)));
        expect(r.committedRows.last, 1);
        expect(r.successResults, hasLength(1));
      });
    });

    test('a foreign record landing while a claim waits out an abort is '
        'banked tokenless and never rides into our token commit', () {
      fakeAsync((async) {
        final r = _Rig()
          ..claim()
          ..failFailureResults = true;
        r.holdAbort = Completer<bool>();
        // Our task ends with its abort write parked open.
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1520));
        r.rx(_historyEnd(expected: 3, token: 0xDB00));
        async.elapse(Duration.zero);
        expect(r.aborts, hasLength(1));
        expect(r.committedTokens, [null]);

        // A new claim waits on the lifecycle barrier…
        bool? claimed;
        r.engine.debugStartHistoricalRefresh().then((v) => claimed = v);
        async.elapse(Duration.zero);
        expect(claimed, isNull);
        // …and a record of a transfer we did not request lands meanwhile.
        r.rx(_gen5V18Inner(ts: ts + 10, counter: 1530));
        async.elapse(Duration.zero);

        r.holdAbort!.complete(true);
        r.holdAbort = null;
        async.elapse(const Duration(milliseconds: 500));
        expect(claimed, isTrue);
        expect(r.engine.debugDrain!.bufferedRecords, 0,
            reason: 'the foreign record is not in our drain');

        // The quiet flush banks it on its own, tokenless.
        async.elapse(const Duration(seconds: 6));
        expect(r.committedTokens, [null, null]);
        expect(r.committedRows.last, 1);

        // Our burst: its token commit carries exactly our one record.
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts + 20, counter: 1540));
        r.rx(_historyEnd(expected: 1, token: 0xDB10));
        async.elapse(Duration.zero);
        expect(r.committedTokens.last, hex(_tokenBytes(0xDB10)));
        expect(r.committedRows.last, 1);
        expect(r.successResults, hasLength(1),
            reason: 'one ACK — for our burst only, after its commit');
        final commitAt = r.events.indexOf('commit:${hex(_tokenBytes(0xDB10))}');
        final ackAt =
            r.events.indexOf('write:${Cmd.historicalDataResult}:1');
        expect(ackAt, greaterThan(commitAt));
      });
    });

    test('an auto-continue defers to another client\'s live transfer and '
        'releases the claim', () {
      fakeAsync((async) {
        final r = _Rig()..claim();
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1950));
        r.rx(_historyEnd(expected: 1, token: 0xDE00));
        async.elapse(Duration.zero);
        expect(r.successResults, hasLength(1));
        // Another client starts just as our COMPLETE arrives.
        r.rx(_historyComplete());
        r.rx(_historyStart());
        async.elapse(const Duration(seconds: 2));
        expect(r.logs.any((l) => l.contains('[SYNC] auto-continue')), isTrue);
        expect(r.logs.any((l) => l.contains('another client is transferring')),
            isTrue);
        expect(r.drainRequests, isEmpty,
            reason: 'the auto-continue must not compete with that transfer');
        expect(r.engine.offloadActive, isFalse,
            reason: 'refused before claiming: the claim is released');
        expect(r.engine.offloadSnapshot['history_task_owned'], isFalse);
      });
    });

    test('our own auto-continued task is ours: its START and END are '
        'answered, the window stays closed', () {
      fakeAsync((async) {
        final r = _Rig()..claim();
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1960));
        r.rx(_historyEnd(expected: 1, token: 0xDF00));
        r.rx(_historyComplete());
        async.elapse(const Duration(seconds: 1));
        expect(r.drainRequests, hasLength(1), reason: 'auto-continued');
        expect(r.engine.offloadSnapshot['history_task_owned'], isTrue);

        // The band answers the auto-continue with a fresh burst.
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts + 1, counter: 1961));
        r.rx(_historyEnd(expected: 1, token: 0xDF10));
        async.elapse(Duration.zero);
        expect(r.successResults, hasLength(2),
            reason: 'the auto-continued burst is ACKed as ours');
        expect(r.successResults.last.body.take(9).toList(),
            [0x01, ..._tokenBytes(0xDF10)]);
        expect(r.engine.offloadSnapshot['foreign_history_live'], isFalse);
        expect(r.engine.offloadSnapshot['foreign_records_banked'], 0);
        expect(r.engine.offloadSnapshot['first_start_watchdog_armed'], isFalse);
      });
    });

    test('a foreign START queued behind a held COMPLETE still defers a '
        'claim', () {
      fakeAsync((async) {
        final r = _Rig();
        // Another client's transfer: one burst, then its COMPLETE, whose
        // tokenless bank parks mid-commit.
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1700));
        r.rx(_historyEnd(expected: 1, token: 0xDC00));
        async.elapse(Duration.zero);
        r.rx(_gen5V18Inner(ts: ts + 1, counter: 1701));
        r.holdCommit = Completer<void>();
        final held = r.holdCommit!;
        r.rx(_historyComplete());
        async.elapse(Duration.zero);
        // …and it starts its next transfer while that commit is parked.
        r.rx(_historyStart());

        bool? claimed;
        r.engine.debugStartHistoricalRefresh().then((v) => claimed = v);
        async.elapse(Duration.zero);
        held.complete();
        async.elapse(const Duration(milliseconds: 500));
        expect(claimed, isFalse,
            reason: 'the queued START was seen on arrival — no competing '
                'transfer may start, whatever the drainer has reached');
        expect(r.drainRequests, isEmpty);
        expect(r.writes.where((w) => w.opcode != Cmd.getClock), isEmpty);
      });
    });

    test('another client starting between our abort and our retry defers '
        'the retry', () {
      fakeAsync((async) {
        final r = _Rig();
        r.engine.debugStartHistoricalRefresh();
        async.elapse(const Duration(seconds: 11));
        expect(r.aborts, hasLength(1), reason: 'our request went unanswered');
        // Our task's terminal latch is set; another client's START arrives
        // inside the 3 s retry settle.
        r.rx(_historyStart());
        async.elapse(const Duration(milliseconds: 10));
        expect(r.engine.offloadSnapshot['foreign_history_live'], isTrue,
            reason: 'recorded for deferral and maintenance pausing even '
                'though the latch keeps the marker inert');
        async.elapse(const Duration(seconds: 6));
        expect(r.drainRequests, hasLength(1),
            reason: 'the retry must not compete with that transfer');
        expect(r.aborts, hasLength(1));
        expect(r.logs.any((l) => l.contains('another client is transferring')),
            isTrue);
      });
    });

    test('INIT re-checks the foreign window after its waits', () {
      fakeAsync((async) {
        final r = _Rig()
          ..claim()
          ..failFailureResults = true;
        r.holdAbort = Completer<bool>();
        // Our task ends with its abort parked: INIT has to wait it out.
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1800));
        r.rx(_historyEnd(expected: 3, token: 0xE800));
        async.elapse(Duration.zero);
        expect(r.aborts, hasLength(1));
        bool? ready;
        r.engine.debugStartInitDrain().then((v) => ready = v);
        async.elapse(Duration.zero);
        expect(ready, isNull);
        // The other client's START lands while INIT waits.
        r.rx(_historyStart());
        async.elapse(Duration.zero);
        r.holdAbort!.complete(true);
        r.holdAbort = null;
        async.elapse(const Duration(seconds: 2));
        expect(ready, isTrue);
        expect(r.drainRequests, isEmpty,
            reason: 'INIT must not ask for history into a live foreign '
                'transfer it learned about during its own waits');
        expect(r.logs.any((l) => l.contains('INIT drain DEFERRED — another')),
            isTrue);
        expect(r.engine.offloadActive, isFalse);
      });
    });

    test('joining another client\'s burst mid-way (records, no marker yet) '
        'defers a claim; gen4 END is not answered', () async {
      final r = _Rig(band: BandProfile.gen4);
      r.rx(_gen4V24Inner(ts: ts, counter: 1700));
      r.rx(_gen4V24Inner(ts: ts + 1, counter: 1701));
      await pumpEventQueue();
      expect(r.engine.offloadSnapshot['foreign_history_live'], isTrue);
      expect(await r.engine.debugStartHistoricalRefresh(), isFalse,
          reason: 'claiming now would make its END look like ours');
      r.rx(_historyEnd(expected: 2, token: 0xD710));
      await pumpEventQueue();
      expect(r.writes, isEmpty);
      expect(r.committedTokens, everyElement(isNull));
      expect(r.committedRows.fold<int>(0, (a, b) => a + b), 2);
    });

    test('an abandoned foreign transfer stops deferring after the stall '
        'bound, however often its END is re-offered', () {
      fakeAsync((async) {
        final r = _Rig();
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1710));
        // Nobody answers it: the band re-offers the END every 2.5 s.
        final reoffer = Timer.periodic(const Duration(milliseconds: 2500),
            (_) => r.rx(_historyEnd(expected: 1, token: 0xD720)));
        async.elapse(const Duration(seconds: 30));
        expect(await_(r.engine.debugStartHistoricalRefresh(), async), isFalse);
        expect(r.drainRequests, isEmpty);
        async.elapse(const Duration(seconds: 31));
        expect(r.engine.offloadSnapshot['foreign_history_live'], isFalse);
        async.elapse(const Duration(seconds: 10));
        reoffer.cancel();
        expect(r.drainRequests, hasLength(1),
            reason: 'the deferred claim re-requests once the stall bound '
                'closes the window');
        expect(r.writes.where((w) => w.opcode == Cmd.historicalDataResult),
            isEmpty);
      });
    });

    test('a link closing mid-transfer banks the foreign buffer', () async {
      final r = _Rig();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1720));
      r.rx(_gen5V18Inner(ts: ts + 1, counter: 1721));
      await pumpEventQueue();
      expect(r.committedRows, isEmpty, reason: 'still buffered');
      await r.engine.disconnect();
      await pumpEventQueue();
      expect(r.committedTokens, [null]);
      expect(r.committedRows, [2],
          reason: 'the other client trims these; dropping them loses them');
    });

    test('a latched link still banks another client\'s burst at its END', () {
      fakeAsync((async) {
        final r = _Rig()
          ..claim()
          ..failFailureResults = true;
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1730));
        r.rx(_historyEnd(expected: 3, token: 0xD730));
        async.elapse(Duration.zero);
        expect(r.aborts, hasLength(1));
        final commits = r.committedTokens.length;
        // Another client's burst while our task's latch is set.
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts + 10, counter: 1740));
        r.rx(_historyEnd(expected: 1, token: 0xD740));
        async.elapse(const Duration(seconds: 1));
        expect(r.committedTokens.length, commits + 1,
            reason: 'banked at the burst boundary, not 5 s later');
        expect(r.committedTokens.last, isNull);
      });
    });

    test('a continuous foreign stream is banked within 5 s, not when it '
        'stops', () {
      fakeAsync((async) {
        final r = _Rig();
        var c = 1750;
        final stream = Timer.periodic(const Duration(seconds: 1),
            (_) => r.rx(_gen5V18Inner(ts: ts + (c - 1750), counter: c++)));
        async.elapse(const Duration(seconds: 7));
        expect(r.engine.offloadSnapshot['foreign_records_banked'],
            greaterThan(0));
        stream.cancel();
      });
    });

    test('a transfer that starts while our request is still being prepared '
        'is not ours, and our request is not sent into it', () async {
      final r = _Rig(band: BandProfile.gen4);
      // Another client's whole burst lands during our claim's clock read —
      // before our SEND_HISTORICAL_DATA has gone out.
      r.onClockRequest = () {
        r.rx(_historyStart());
        r.rx(_gen4V24Inner(ts: ts, counter: 1760));
        r.rx(_historyEnd(expected: 1, token: 0xD760));
      };
      expect(await r.engine.debugStartHistoricalRefresh(), isFalse);
      await pumpEventQueue();
      expect(r.drainRequests, isEmpty);
      expect(r.successResults, isEmpty,
          reason: 'its END must not be validated and ACKed as ours');
      expect(r.committedTokens, everyElement(isNull));
      expect(r.committedRows.fold<int>(0, (a, b) => a + b), 1);
      expect(r.logs.any((l) => l.contains('while this request was being '
          'prepared')), isTrue);
      expect(r.engine.offloadActive, isFalse);
    });

    test('a stray COMPLETE before our request goes out does not end our task',
        () async {
      final r = _Rig();
      r.onClockRequest = () => r.rx(_historyComplete());
      expect(await r.engine.debugStartHistoricalRefresh(), isTrue);
      await pumpEventQueue();
      expect(r.drainRequests, hasLength(1));
      expect(r.engine.offloadSnapshot['history_task_owned'], isTrue,
          reason: 'the COMPLETE could not be an answer to a request not yet '
              'sent');
      expect(r.engine.offloadSnapshot['last_hps_terminal'], isNull);
    });

    test('a link closing banks another client\'s records still queued',
        () async {
      final r = _Rig();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1770));
      await pumpEventQueue();
      final held = r.holdCommit = Completer<void>();
      r.rx(_historyEnd(expected: 1, token: 0xD770)); // its bank parks
      await pumpEventQueue();
      r.rx(_gen5V18Inner(ts: ts + 1, counter: 1771)); // queued behind it
      r.rx(_gen5V18Inner(ts: ts + 2, counter: 1772));
      // The final bank waits out the parked one, detached from the teardown.
      final closing = r.engine.disconnect();
      await pumpEventQueue();
      held.complete();
      await closing;
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(r.committedTokens, everyElement(isNull));
      expect(r.committedRows.fold<int>(0, (a, b) => a + b), 3);
    });

    test('a deferred request leaves no watchdog behind (no abort a minute '
        'later)', () {
      fakeAsync((async) {
        final r = _Rig(band: BandProfile.gen4);
        var injected = false;
        r.onWriteOpcode = (op) {
          if (injected || op != Cmd.getDataRange) return;
          injected = true;
          // Another client's burst while the claim waits out its range poll —
          // the drainer handles it while the claim is still live.
          r.rx(_historyStart());
          r.rx(_gen4V24Inner(ts: ts, counter: 1765));
        };
        bool? sent;
        r.engine
            .debugStartHistoricalRefresh(refreshRange: true)
            .then((v) => sent = v);
        async.elapse(const Duration(seconds: 1));
        expect(injected, isTrue);
        expect(sent, isFalse);
        async.elapse(const Duration(seconds: 9));
        expect(r.aborts, isEmpty,
            reason: 'nothing of ours was ever requested');
        expect(r.drainRequests, isEmpty);
        async.elapse(const Duration(seconds: 61));
        expect(r.drainRequests, isNotEmpty, reason: 're-requested once quiet');
        expect(r.aborts, hasLength(r.drainRequests.length),
            reason: 'every abort ends a request that went out');
      });
    });

    test('a link closing banks foreign records the drainer was holding',
        () async {
      final r = _Rig();
      final held = r.holdCommit = Completer<void>();
      // One extracted batch: the END's bank parks; the records behind it are
      // in the drainer's hand, not in the queue.
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1780));
      r.rx(_historyEnd(expected: 1, token: 0xD780));
      r.rx(_gen5V18Inner(ts: ts + 1, counter: 1781));
      r.rx(_gen5V18Inner(ts: ts + 2, counter: 1782));
      await pumpEventQueue();
      final closing = r.engine.disconnect();
      await pumpEventQueue();
      held.complete();
      await closing;
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(r.committedTokens, everyElement(isNull));
      expect(r.committedRows.fold<int>(0, (a, b) => a + b), 3);
    });

    test('a new foreign START ends our own tail: its later records re-open '
        'the window after a pause', () {
      fakeAsync((async) {
        final r = _Rig()
          ..claim()
          ..failFailureResults = true;
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1790));
        r.rx(_historyEnd(expected: 3, token: 0xD790));
        async.elapse(Duration.zero);
        expect(r.aborts, hasLength(1), reason: 'our task ended');
        r.rx(_historyStart()); // another client's transfer
        async.elapse(const Duration(seconds: 11)); // it pauses
        expect(r.engine.offloadSnapshot['foreign_history_live'], isFalse);
        r.rx(_gen5V18Inner(ts: ts + 20, counter: 1795)); // and resumes
        async.elapse(Duration.zero);
        expect(r.engine.offloadSnapshot['foreign_history_live'], isTrue);
        expect(await_(r.engine.debugStartHistoricalRefresh(), async), isFalse);
      });
    });

    test('a final bank that fails as the link closes is counted, and its '
        'rows are retained nowhere — not even after a reconnect', () async {
      final r = _Rig()..failCommits = 2;
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1800));
      r.rx(_historyEnd(expected: 1, token: 0xD800)); // bank #1 fails
      await pumpEventQueue();
      await r.engine.disconnect(); // the final bank fails too
      await pumpEventQueue();
      expect(r.committedRows, isEmpty);
      expect(r.engine.offloadSnapshot['foreign_rows_lost_at_shutdown'], 1);
      // A new link's banks never bring the old link's rows back (a reset in
      // between must stay a reset).
      r.connect();
      r.rx(_historyStart());
      r.rx(_historyEnd(expected: 0, token: 0xD801));
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(r.committedRows, isEmpty);
    });

    test('a reconnect while a foreign bank is still running leaves the new '
        'link intact', () async {
      final r = _Rig();
      final held = r.holdCommit = Completer<void>();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1805));
      r.rx(_historyEnd(expected: 1, token: 0xD805)); // its bank parks
      await pumpEventQueue();
      final closing = r.engine.disconnect();
      await closing; // the teardown does not wait on the parked bank
      r.connect(); // the next link is up before that bank finishes
      held.complete();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await r.engine.debugStartHistoricalRefresh(), isTrue,
          reason: 'nothing of the old teardown resumed onto the new link');
      expect(r.drainRequests, hasLength(1));
      expect(r.committedRows.fold<int>(0, (a, b) => a + b), 1);
    });

    test('a record that arrives once shutdown has begun is either in the '
        'final bank or dropped — never left half-routed', () async {
      final r = _Rig();
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 1810));
      await pumpEventQueue();
      final closing = r.engine.disconnect();
      r.rx(_gen5V18Inner(ts: ts + 1, counter: 1811)); // races the teardown
      await closing;
      r.rx(_gen5V18Inner(ts: ts + 2, counter: 1812)); // after: no link
      r.engine.debugReceiveChunk(
          _rev2Chunk(_gen5V18Inner(ts: ts + 3, counter: 1813)));
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final banked = r.committedRows.fold<int>(0, (a, b) => a + b);
      expect(banked, anyOf(1, 2));
      expect(r.engine.offloadSnapshot['foreign_records_banked'], banked);
      expect(r.engine.offloadSnapshot['queued_frames'], 0);
      // Nothing of it surfaces later on a new link.
      r.connect();
      r.rx(_historyStart());
      r.rx(_historyEnd(expected: 0, token: 0xD811));
      await pumpEventQueue();
      expect(r.committedRows.fold<int>(0, (a, b) => a + b), banked);
    });

    test('the banked count is the rows actually committed, whatever flushes '
        'overlap', () {
      fakeAsync((async) {
        final r = _Rig();
        final held = r.holdCommit = Completer<void>();
        r.rx(_historyStart());
        for (var i = 0; i < 256; i++) {
          r.rx(_gen5V18Inner(ts: ts + i, counter: 2000 + i)); // size bank, parks
        }
        async.elapse(Duration.zero);
        for (var i = 0; i < 3; i++) {
          r.rx(_gen5V18Inner(ts: ts + 300 + i, counter: 2300 + i));
        }
        r.rx(_historyEnd(expected: 259, token: 0xE000)); // marker bank queues
        async.elapse(const Duration(seconds: 6)); // timer bank queues too
        held.complete();
        async.elapse(const Duration(seconds: 1));
        final delivered = r.committedRows.fold<int>(0, (a, b) => a + b);
        expect(delivered, 259);
        expect(r.engine.offloadSnapshot['foreign_records_banked'], delivered,
            reason: 'three flushes saw the same 3 rows buffered; only one '
                'commit stored them');
      });
    });

    test('frames of an unknown revision in another client\'s transfer are '
        'archived and banked like its records (quiet bank)', () {
      fakeAsync((async) {
        final r = _Rig();
        r.rx(_historyStart()); // another client's transfer is live
        async.elapse(Duration.zero);
        r.engine.debugReceiveChunk(
            _rev2Chunk(_gen5V18Inner(ts: ts, counter: 1810)));
        async.elapse(const Duration(seconds: 6));
        expect(r.engine.offloadSnapshot['frame_rev_rejects_total'], 1);
        expect(r.committedTokens, [null]);
        expect(r.committedRows, [1], reason: 'the archive, banked tokenless');
        expect(r.writes, isEmpty);
      });
    });

    test('... and at the size threshold', () {
      fakeAsync((async) {
        final r = _Rig();
        r.rx(_historyStart());
        async.elapse(Duration.zero);
        for (var i = 0; i < 256; i++) {
          r.engine.debugReceiveChunk(
              _rev2Chunk(_gen5V18Inner(ts: ts + i, counter: 1820 + i)));
        }
        async.elapse(const Duration(milliseconds: 10));
        expect(r.engine.offloadSnapshot['foreign_records_banked'], 256,
            reason: 'banked on size, not after the quiet timer');
      });
    });

    test('records after our own abort are banked, not answered', () {
      fakeAsync((async) {
        final r = _Rig()
          ..claim()
          ..failFailureResults = true;
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 1500));
        r.rx(_historyEnd(expected: 3, token: 0xDA00));
        async.elapse(Duration.zero);
        expect(r.aborts, hasLength(1));
        expect(r.committedTokens, [null]);
        expect(r.committedRows, [1]);
        final writesAtAbort = r.writes.length;

        r.rx(_gen5V18Inner(ts: ts + 5, counter: 1505));
        async.elapse(const Duration(seconds: 6));
        expect(r.committedTokens, [null, null]);
        expect(r.committedRows.last, 1);
        expect(r.writes.length, writesAtAbort,
            reason: 'nothing is written for a straggler of an ended task');
      });
    });
  });

  group('T14 — one arrival classifier for every ingest path', () {
    String hex(List<int> b) =>
        b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

    test('records on cmd_from/events while our COMPLETE banks its tail are '
        'banked tokenless, never into our drain', () {
      fakeAsync((async) {
        final r = _Rig()..claim();
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 2000));
        r.rx(_historyEnd(expected: 1, token: 0xE000));
        async.elapse(Duration.zero);
        r.rx(_gen5V18Inner(ts: ts + 1, counter: 2001)); // our tail
        async.elapse(Duration.zero);
        r.holdCommit = Completer<void>();
        final held = r.holdCommit!;
        r.rx(_historyComplete());
        async.elapse(Duration.zero);
        // Another client's records, reassembled off the data characteristic.
        r.rx(_gen5V18Inner(ts: ts + 10, counter: 2010), role: 'cmd_from');
        r.rx(_gen5V18Inner(ts: ts + 11, counter: 2011), role: 'events');
        async.elapse(Duration.zero);
        expect(r.engine.debugDrain!.bufferedRecords, 0,
            reason: 'never into the drain our next token commit reads');
        held.complete();
        async.elapse(const Duration(seconds: 6));
        expect(r.engine.offloadSnapshot['foreign_records_banked'], 2);

        // Our next task: its token commit carries only its own record.
        r.claim();
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts + 20, counter: 2020));
        r.rx(_historyEnd(expected: 1, token: 0xE010));
        async.elapse(Duration.zero);
        expect(r.committedTokens.last, hex(_tokenBytes(0xE010)));
        expect(r.committedRows.last, 1);
        expect(r.committedTokens.where((t) => t == null).length, 2,
            reason: 'our tail + the two foreign rows, both tokenless');
      });
    });

    test('a completed task does not survive a reconnect: a foreign END '
        'before INIT opens the window and INIT skips its drain', () {
      fakeAsync((async) {
        final r = _Rig()..claim();
        r.rx(_historyStart());
        r.rx(_gen5V18Inner(ts: ts, counter: 2100));
        r.rx(_historyEnd(expected: 1, token: 0xE100));
        r.rx(_historyComplete());
        async.elapse(Duration.zero);
        expect(r.successResults, hasLength(1));

        // New link, mid-way through another client's transfer: its START
        // came before we subscribed, its END is the first thing we see.
        r.connect();
        r.rx(_historyEnd(expected: 3, token: 0xE1F0));
        async.elapse(Duration.zero);
        expect(r.engine.offloadSnapshot['foreign_history_live'], isTrue);
        final before = r.drainRequests.length;
        bool? ready;
        r.engine.debugStartInitDrain().then((v) => ready = v);
        async.elapse(const Duration(seconds: 2));
        expect(ready, isTrue);
        expect(r.drainRequests.length, before,
            reason: 'no competing 0x16 into that transfer');
        expect(r.logs.any((l) => l.contains('INIT drain DEFERRED — another')),
            isTrue);
      });
    });

    // role × state × marker. Every cell asserts the classification through
    // what it may and may not cause: an owned frame is answered/buffered as
    // ours; a foreign one writes nothing, is banked tokenless (records) and
    // moves the deferral window per the self-deferral rule.
    const roles = ['data', 'cmd_from', 'events'];
    const states = ['no task', 'owned mid-burst', 'our COMPLETE held',
        'task aborted', 'after reconnect'];
    const kinds = ['START', 'record', 'END', 'COMPLETE'];

    for (final state in states) {
      for (final kind in kinds) {
        for (final role in roles) {
          test('$state × $kind via $role', () {
            fakeAsync((async) {
              void pump() => async.elapse(Duration.zero);
              final r = _Rig();
              Completer<void>? held;
              switch (state) {
                case 'owned mid-burst':
                  r.claim();
                  r.rx(_historyStart());
                  r.rx(_gen5V18Inner(ts: ts, counter: 3000));
                case 'our COMPLETE held':
                  r.claim();
                  r.rx(_historyStart());
                  r.rx(_gen5V18Inner(ts: ts, counter: 3000));
                  r.rx(_historyEnd(expected: 1, token: 0xF000));
                  pump();
                  r.rx(_gen5V18Inner(ts: ts + 1, counter: 3001));
                  pump();
                  held = r.holdCommit = Completer<void>();
                  r.rx(_historyComplete());
                case 'task aborted':
                  r
                    ..claim()
                    ..failFailureResults = true;
                  r.rx(_historyStart());
                  r.rx(_gen5V18Inner(ts: ts, counter: 3000));
                  r.rx(_historyEnd(expected: 3, token: 0xF000));
                  pump();
                  expect(r.aborts, hasLength(1));
                case 'after reconnect':
                  r.claim();
                  r.rx(_historyStart());
                  r.rx(_gen5V18Inner(ts: ts, counter: 3000));
                  r.rx(_historyEnd(expected: 1, token: 0xF000));
                  r.rx(_historyComplete());
                  // Let the auto-continue the COMPLETE decided on settle on
                  // the old link before it goes away.
                  async.elapse(const Duration(seconds: 1));
                  r.connect();
              }
              pump();
              final owned = state == 'owned mid-burst';
              final writesBefore = r.writes.length;
              final bufferedBefore = r.engine.debugDrain!.bufferedRecords;

              final inner = switch (kind) {
                'START' => _historyStart(),
                'record' => _gen5V18Inner(ts: ts + 50, counter: 3050),
                'END' => _historyEnd(expected: 1, token: 0xF0E0),
                _ => _historyComplete(),
              };
              r.rx(inner, role: role);
              pump();
              held?.complete();
              async.elapse(const Duration(seconds: 6));

              final snap = r.engine.offloadSnapshot;
              final newWrites = r.writes.sublist(writesBefore);
              if (owned) {
                switch (kind) {
                  case 'START': // a replacement START: still our task
                    expect(snap['history_task_owned'], isTrue);
                  case 'record':
                    expect(r.engine.debugDrain!.bufferedRecords,
                        bufferedBefore + 1);
                  case 'END':
                    expect(newWrites.single.opcode, Cmd.historicalDataResult);
                    expect(newWrites.single.body0, 0x01);
                  case 'COMPLETE':
                    expect(snap['history_task_owned'], isFalse);
                }
                expect(snap['foreign_records_banked'], 0);
                expect(snap['foreign_history_live'], isFalse);
                return;
              }
              // Foreign: never answered (no result, no abort), nothing into
              // our drain. Our own COMPLETE's auto-continue may still go out
              // — unless the frame opened the foreign window.
              expect(
                  newWrites.where((w) =>
                      w.opcode == Cmd.historicalDataResult ||
                      w.opcode == Cmd.abortHistoricalTransmits),
                  isEmpty,
                  reason: 'never answered');
              if (kind == 'START') {
                expect(newWrites.where((w) => w.opcode == Cmd.sendHistoricalData),
                    isEmpty,
                    reason: 'no request competes with a transfer that just '
                        'started');
              }
              final ourTail =
                  state == 'our COMPLETE held' || state == 'task aborted';
              switch (kind) {
                case 'START':
                  expect(snap['foreign_history_live'], isTrue);
                case 'record':
                  expect(snap['foreign_records_banked'], 1);
                  expect(r.engine.debugDrain!.bufferedRecords, 0);
                case 'END':
                  // Our own re-offered END never self-defers.
                  expect(snap['foreign_history_live'], !ourTail);
                case 'COMPLETE':
                  expect(snap['foreign_history_live'], isFalse);
              }
            });
          });
        }
      }
    }
  });
}
