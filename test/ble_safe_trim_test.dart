// Regression tests for the SAFE-TRIM invariant and the offload-transport
// guards around it.
//
// THE INVARIANT: the durable commit (decoded_onehz + decoded_rr + cursor +
// raw_archive, one transaction) must be durable BEFORE the engine echoes the
// verbatim 8-byte HISTORY_END token, because that echo is what makes the band
// trim the chunk out of its flash. The happy path always honoured it; every
// test here covers a FAILURE path that did not.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/sync/sync_policy.dart';

/// A well-formed inner-frame hex: [0]=0x2f historical, [1]=0x18 (revision 24),
/// then the u32 record counter. Nothing re-parses it any more — BurstStats is
/// handed the revision the ingest path already read — but the commit path
/// stores it, so it stays real hex rather than a label.
String _hex(int counter) =>
    '2f18${counter.toRadixString(16).padLeft(8, '0')}';

RawRecord _raw(int counter) => RawRecord(
  counter: counter,
  packetType: 0x2f,
  hex: _hex(counter),
  capturedAt: 1780000000000 + counter,
  recTs: 1780000000 + counter,
);

Sample _sample(int counter) =>
    Sample(tsEpoch: 1780000000 + counter, counter: counter, hr: 60);

ArchiveRecord _archive(int counter) => ArchiveRecord(
  counter: counter,
  hex: _hex(counter),
  packetType: 0x2f,
  capturedAt: 1780000000000 + counter,
  reason: 'undecodable_rec_v99',
);

const _tokenA = <int>[1, 2, 3, 4, 5, 6, 7, 8];
const _tokenB = <int>[9, 9, 9, 9, 9, 9, 9, 9];

/// A drain controller wired to [onCommit], the atomic-commit sink the real
/// engine points at `LocalDb.commitSyncBatch`.
DrainController _drainWith(CommitSyncBatchSink onCommit, {List<String>? logs}) =>
    DrainController(
      onRecord: (sample, raw) async {},
      onRecordsBatch: null,
      onCommit: onCommit,
      onArchive: null,
      log: (line) => logs?.add(line),
    );

void main() {
  group('P0 — a durable commit that fails must not let the caller ACK', () {
    test('commit() REPORTS failure instead of swallowing the exception', () async {
      final d = _drainWith(
        (raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async =>
            throw StateError('OOM in SqlCommand.getSqlArguments'),
      );
      d.onHistoricalRecord(_raw(1), _sample(1), 24);

      final durable = await d.commit(_tokenA);

      // OLD BEHAVIOUR: commit() was Future<void> — it logged 'offload commit
      // error' and returned normally, and the caller unconditionally built and
      // wrote buildHistoryResultOk(), so the band trimmed a chunk that had
      // rolled back. There was no success signal to check at all.
      expect(durable, isFalse);
    });

    test('a failed commit RE-BUFFERS the records instead of losing them', () async {
      final d = _drainWith(
        (raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async => throw StateError('rollback'),
      );
      d.onHistoricalRecord(_raw(1), _sample(1), 24);
      d.onHistoricalRecord(_raw(2), _sample(2), 24);
      d.onUndecodableRecord(_archive(3));

      expect(d.bufferedRecords, 2);
      final durable = await d.commit(_tokenA);

      expect(durable, isFalse);
      // OLD BEHAVIOUR: the buffer was snapshotted and CLEARED before the
      // commit, and the exception was swallowed — so with the transaction
      // rolled back and the cursor unadvanced, those rows existed nowhere.
      expect(d.bufferedRecords, 2);

      // Proof they are really still there: a later successful commit ships
      // every record AND the archived one.
      final seenRaws = <String>[];
      final seenArchives = <String>[];
      final d2 = _drainWith((raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {
        seenRaws.addAll(raws.map((r) => r.hex));
        seenArchives.addAll((archives ?? const []).map((a) => a.hex));
      });
      // (rebuild the same state on a controller whose commit succeeds)
      d2.onHistoricalRecord(_raw(1), _sample(1), 24);
      d2.onHistoricalRecord(_raw(2), _sample(2), 24);
      d2.onUndecodableRecord(_archive(3));
      expect(await d2.commit(_tokenA), isTrue);
      expect(seenRaws, [_hex(1), _hex(2)]);
      expect(seenArchives, [_hex(3)]);
    });

    test(
      're-buffered records keep arrival order ahead of records that landed '
      'during the failing await',
      () async {
        final gate = Completer<void>();
        var fail = true;
        final shipped = <String>[];
        final d = DrainController(
          onRecord: (sample, raw) async {},
          onRecordsBatch: null,
          onCommit: (raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {
            if (fail) {
              await gate.future;
              throw StateError('rollback');
            }
            shipped.addAll(raws.map((r) => r.hex));
          },
          onArchive: null,
          log: (_) {},
        );

        d.onHistoricalRecord(_raw(1), _sample(1), 24);
        final inFlight = d.commit(_tokenA);
        // A record arrives while the commit is parked mid-await.
        d.onHistoricalRecord(_raw(2), _sample(2), 24);
        gate.complete();
        expect(await inFlight, isFalse);

        expect(d.bufferedRecords, 2);
        fail = false;
        expect(await d.commit(_tokenA), isTrue);
        expect(shipped, [_hex(1), _hex(2)]);
      },
    );

    test('a failed commit rolls back the trim-advance bookkeeping', () async {
      var fail = false;
      final d = DrainController(
        onRecord: (sample, raw) async {},
        onRecordsBatch: null,
        onCommit: (raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {
          if (fail) throw StateError('rollback');
        },
        onArchive: null,
        log: (_) {},
      );

      // Empty token-only commits do not count as trim advance (would feed
      // auto-continue while the durable frontier stayed frozen).
      d.onHistoricalRecord(_raw(0), _sample(0), 24);
      expect(await d.commit(_tokenA), isTrue);
      expect(d.lastTrimAdvanced, isTrue);

      fail = true;
      d.onHistoricalRecord(_raw(1), _sample(1), 24);
      expect(await d.commit(_tokenB), isFalse);
      // The cursor did NOT move to tokenB, so nothing may claim it did.
      expect(d.lastTrimAdvanced, isTrue, reason: 'rolled back to the tokenA state');

      // And when tokenB is finally committed for real it still counts as an
      // ADVANCE. Without the rollback, _lastAckedToken was already tokenB, so
      // the real commit reported "no advance" and BackfillContinuation refused
      // to auto-continue a drain that had in fact progressed.
      fail = false;
      expect(await d.commit(_tokenB), isTrue);
      expect(d.lastTrimAdvanced, isTrue);
    });

    test('an empty buffer commit does not claim trim advanced', () async {
      final d = _drainWith((raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {});
      expect(await d.commit(_tokenA), isTrue);
      expect(d.lastTrimAdvanced, isFalse);
    });

    test('archive-only commit still counts as trim advanced', () async {
      final d = _drainWith((raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {});
      d.onUndecodableRecord(_archive(1));
      expect(await d.commit(_tokenA), isTrue);
      expect(d.lastTrimAdvanced, isTrue);
    });

    test('a successful commit clears the buffer and reports durable', () async {
      final d = _drainWith((raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {});
      d.onHistoricalRecord(_raw(1), _sample(1), 24);

      expect(await d.commit(_tokenA), isTrue);
      expect(d.bufferedRecords, 0);
    });
  });

  group('P0 — TrimAckPolicy gates the one irreversible act', () {
    test('a commit that did not become durable blocks the ACK', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: false,
          commitDurable: false,
        ),
        TrimAckVerdict.blockedCommitFailed,
      );
    });

    test('a stale session blocks the ACK', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: false,
          burstDiscarded: false,
          commitDurable: true,
        ),
        TrimAckVerdict.blockedStaleSession,
      );
    });

    test('a discarded burst blocks the ACK even when the commit succeeded', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: true,
          commitDurable: true,
        ),
        TrimAckVerdict.blockedDiscardedBurst,
      );
    });

    test('a stale session outranks every other reason — nothing may touch the '
        'new link', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: false,
          burstDiscarded: true,
          commitDurable: false,
        ),
        TrimAckVerdict.blockedStaleSession,
      );
    });

    test('a discarded burst outranks a durable commit result', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: true,
          commitDurable: false,
        ),
        TrimAckVerdict.blockedDiscardedBurst,
      );
    });

    test('every precondition holding is the ONLY way to send', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: false,
          commitDurable: true,
        ),
        TrimAckVerdict.send,
      );
    });

    test('drop-only empty burst blocks the ACK (no durable progress)', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: false,
          commitDurable: true,
          hadDurableRows: false,
          droppedThisBurst: 12,
        ),
        TrimAckVerdict.blockedNoDurableProgress,
      );
    });

    test('empty burst with zero drops may still ACK (console-only)', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: false,
          commitDurable: true,
          hadDurableRows: false,
          droppedThisBurst: 0,
        ),
        TrimAckVerdict.send,
      );
    });

    test('archive-or-raw banked rows still ACK even when some were dropped', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: false,
          commitDurable: true,
          hadDurableRows: true,
          droppedThisBurst: 5,
        ),
        TrimAckVerdict.send,
      );
    });

    test('commit failure outranks the no-durable-progress rule', () {
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: false,
          commitDurable: false,
          hadDurableRows: false,
          droppedThisBurst: 9,
        ),
        TrimAckVerdict.blockedCommitFailed,
      );
    });
  });

  group('P0 — DrainController wiring must not allow latent safe-trim holes', () {
    test('onRecordsBatch without onCommit is rejected at construction', () {
      expect(
        () => DrainController(
          onRecord: (sample, raw) async {},
          onRecordsBatch: (raws, samples) async {},
          onCommit: null,
          onArchive: null,
          log: (_) {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('supportsSafeTrim is true only when onCommit is wired', () {
      final withCommit = _drainWith((raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {});
      expect(withCommit.supportsSafeTrim, isTrue);

      final unbuffered = DrainController(
        onRecord: (sample, raw) async {},
        onRecordsBatch: null,
        onCommit: null,
        onArchive: null,
        log: (_) {},
      );
      expect(unbuffered.supportsSafeTrim, isFalse);
    });

    test('token commit without onCommit fails closed (no false durable)', () async {
      final d = DrainController(
        onRecord: (sample, raw) async {},
        onRecordsBatch: null,
        onCommit: null,
        onArchive: null,
        log: (_) {},
      );
      expect(await d.commit(_tokenA), isFalse);
      expect(d.lastTrimAdvanced, isFalse);
    });

    test('archive-only + onCommit still persists before success', () async {
      final seen = <String>[];
      final ok = _drainWith((raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {
        seen.addAll((archives ?? const []).map((a) => a.hex));
      });
      ok.onUndecodableRecord(_archive(9));
      expect(await ok.commit(_tokenA), isTrue);
      expect(seen, [_hex(9)]);
      expect(ok.bufferedArchives, 0);
      expect(ok.lastTrimAdvanced, isTrue);
    });

    test('unbuffered mode does not treat fire-and-forget rows as buffered', () {
      var wrote = 0;
      final d = DrainController(
        onRecord: (sample, raw) async {
          wrote++;
        },
        onRecordsBatch: null,
        onCommit: null,
        onArchive: null,
        log: (_) {},
      );
      d.onHistoricalRecord(_raw(1), _sample(1), 24);
      expect(d.bufferedRecords, 0);
      expect(d.supportsSafeTrim, isFalse);
      expect(wrote, 1);
    });
  });

  group('P0 — a discarded burst poisons its HISTORY_END token', () {
    test('discardOpenChunk marks the open burst un-ACKable', () async {
      final d = _drainWith((raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {});
      d.onHistoricalRecord(_raw(1), _sample(1), 24);
      expect(d.burstDiscarded, isFalse);

      d.discardOpenChunk();

      // OLD BEHAVIOUR: the records were dropped and NOTHING recorded it, so
      // the straggler HISTORY_END (already in flight when the idle watchdog
      // fired) committed an empty buffer and echoed the token verbatim — the
      // band then trimmed exactly the records that had just been thrown away.
      expect(d.burstDiscarded, isTrue);
      expect(d.bufferedRecords, 0);
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: d.burstDiscarded,
          commitDurable: true,
        ),
        TrimAckVerdict.blockedDiscardedBurst,
      );
    });

    test('poisons even when the open buffer is already empty', () {
      final d = _drainWith((raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {});
      d.discardOpenChunk();
      expect(d.burstDiscarded, isTrue);
    });

    test('a local rearm (abort→retry) does NOT clear the poison', () {
      // THE BUG: the idle watchdog discards the open chunk, _abortAndRetry arms
      // a 3 s timer, and _startHistoricalRefresh's first act was d.rearm() —
      // which cleared the latch. The abandoned burst's HISTORY_END was still in
      // flight, landed on a clean guard, and got ACKed verbatim: the band
      // trimmed exactly the records the watchdog threw away.
      final d = _drainWith((raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {});
      d.onHistoricalRecord(_raw(1), _sample(1), 24);
      d.discardOpenChunk();

      d.rearm();

      expect(d.burstDiscarded, isTrue);
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: d.burstDiscarded,
          commitDurable: true,
        ),
        TrimAckVerdict.blockedDiscardedBurst,
      );
    });

    test('only a HISTORY_START (beginBurst) clears the poison', () {
      final d = _drainWith((raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {});
      d.discardOpenChunk();
      expect(d.burstDiscarded, isTrue);

      d.rearm();
      d.beginBurst();

      expect(d.burstDiscarded, isFalse);
      expect(
        TrimAckPolicy.evaluate(
          sessionCurrent: true,
          burstDiscarded: d.burstDiscarded,
          commitDurable: true,
        ),
        TrimAckVerdict.send,
      );
    });

    test('poisonedBursts counts once per burst, not once per discard call', () {
      final d = _drainWith((raws, samples, token, {archives, ecgRawPackets, deviceFamily}) async {});
      d.discardOpenChunk();
      d.discardOpenChunk();
      expect(d.poisonedBursts, 1);
      d.beginBurst();
      d.discardOpenChunk();
      expect(d.poisonedBursts, 2);
    });
  });

  group('BurstTrimGuard', () {
    test('starts un-poisoned', () {
      expect(BurstTrimGuard().discarded, isFalse);
    });

    test('a discard latches until the next burst begins', () {
      final g = BurstTrimGuard();
      g.discardOpenChunk();
      expect(g.discarded, isTrue);
      g.beginBurst();
      expect(g.discarded, isFalse);
      expect(g.poisonedBursts, 1);
    });
  });

  group('P2 — a corrupt far-future RTC read is not a clock correlation', () {
    const wallNow = 1780000000;

    test('a read implausibly far in the future is refused', () {
      expect(
        ClockPolicy.acceptsClockRead(wallNow + 20 * 365 * 86400, wallNow),
        isFalse,
      );
    });

    test('a normal read is accepted', () {
      expect(ClockPolicy.acceptsClockRead(wallNow - 12, wallNow), isTrue);
    });

    test('an unset/behind RTC is still accepted — this gate is future-only', () {
      // Those go to ClockPolicy.shouldSetClock, which corrects them; refusing
      // them here would break the ordinary drift-correction path.
      expect(ClockPolicy.acceptsClockRead(1600000000, wallNow), isTrue);
    });

    test('small clock skew inside the future margin is accepted', () {
      expect(ClockPolicy.acceptsClockRead(wallNow + 60, wallNow), isTrue);
    });

    test(
      'trusting a corrupt read would arm the wake alarm years out — the exact '
      'failure the gate prevents',
      () {
        final corrupt = wallNow + 20 * 365 * 86400;
        final ref = ClockRef(device: corrupt, wall: wallNow);
        expect(ref.driftSec, lessThan(0));

        final target = DateTime.fromMillisecondsSinceEpoch(wallNow * 1000)
            .add(const Duration(hours: 8));
        final armed = AlarmPayloads.toStrapFrame(target, ref.driftSec);

        // setAlarm does when.subtract(driftSec); a negative drift pushes the
        // armed epoch decades into the future, where it silently never fires.
        expect(armed.difference(target).inDays, greaterThan(5 * 365));
        // …which is why the read never becomes a ClockRef in the first place.
        expect(ClockPolicy.acceptsClockRead(corrupt, wallNow), isFalse);
      },
    );
  });
}
