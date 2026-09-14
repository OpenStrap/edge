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

  /// When set, the NEXT commit parks on this future (then completes normally,
  /// or throws if [failHeldCommit] is set — the shape of a transaction that
  /// fails after parking for seconds).
  Completer<void>? holdCommit;
  bool failHeldCommit = false;

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
          if (opcode == Cmd.abortHistoricalTransmits && holdAbort != null) {
            return holdAbort!.future;
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
      r.holdAbort = Completer<bool>();

      // Terminal on session A with the abort write parked open.
      r.rx(_historyStart());
      r.rx(_gen5V18Inner(ts: ts, counter: 950));
      r.rx(_historyEnd(expected: 3, token: 0x9950));
      await pumpEventQueue();
      expect(r.aborts, hasLength(1), reason: 'abort issued and parked');

      // The link is replaced while that write is in flight, and the
      // replacement session's own drain traffic raises the offload state
      // (in production, INIT pre-arms it the same way).
      r.connect();
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
}
