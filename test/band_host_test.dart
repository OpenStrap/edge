// M1 §10: `BandHost` — the one place that drives an adapter and banks what
// comes back. Exercised directly here (not through hrs_link.dart, which does
// not yet call it — see M1's commit order) using the real `BleHrsAdapter`
// over a `ReplayBandLink`, the same fixture shape as `test/hrs_link_test.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/ble_hrs.dart';
import 'package:openstrap_edge/ble/adapters/host.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';

const List<int> kBpmOnly = <int>[0x00, 61];
const List<int> kHrWithTwoRr = <int>[
  0x16,
  120,
  0xF4, 0x01, // 500 ticks = 488 ms
  0x00, 0x02, // 512 ticks = 500 ms
];

void main() {
  const deviceId = 'hrs-a1b2c3d4';

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'band_host_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('drives an adapter over a replay link and banks HR + beats', () async {
    final host = BandHost(adapter: kBleHrsAdapter, deviceId: deviceId);
    final link = ReplayBandLink();
    final future = host.run(link);
    link.feed('00002a37-0000-1000-8000-00805f9b34fb', kHrWithTwoRr,
        atSec: 1_800_000_000);
    link.feed('00002a37-0000-1000-8000-00805f9b34fb', kBpmOnly,
        atSec: 1_800_000_001);
    await link.close();
    await future;
    await host.stop();

    final db = await LocalDb.instance;
    final onehz = await db.query('decoded_onehz', orderBy: 'ts_ms');
    expect(onehz, hasLength(2));
    expect(onehz.first['device_id'], deviceId);
    expect(onehz.first['hr'], 120);
    expect(onehz.first['source'], 'ble_hrs');
    expect(onehz.first['device_family'], 'ble_hrs');

    final rr = await db.query('decoded_rr', orderBy: 'beat_index');
    expect(rr, hasLength(2));
    expect(rr[0]['rr_ms'], 488);
    expect(rr[1]['rr_ms'], 500);
  });

  test('stop() completes an in-flight run() rather than leaving it pending',
      () async {
    final host = BandHost(adapter: kBleHrsAdapter, deviceId: deviceId);
    final link = ReplayBandLink();
    var ran = false;
    final future = host.run(link).then((_) => ran = true);
    link.feed('00002a37-0000-1000-8000-00805f9b34fb', kBpmOnly,
        atSec: 1_800_000_020);
    await Future<void>.delayed(Duration.zero);
    expect(ran, isFalse, reason: 'the session is still open');
    // The stream never ends here — `stop()` cancels the subscription, and
    // cancelling does not fire onDone. Without the host-level completer this
    // await never returns (OuraLink._sync would hold its link slot forever).
    final stopped = host.stop();
    await future.timeout(const Duration(seconds: 2));
    expect(ran, isTrue);
    await link.close();
    await stopped;
  });

  test('the live reading publishes as samples arrive', () async {
    final host = BandHost(adapter: kBleHrsAdapter, deviceId: deviceId);
    final link = ReplayBandLink();
    final future = host.run(link);
    link.feed('00002a37-0000-1000-8000-00805f9b34fb', kHrWithTwoRr,
        atSec: 1_800_000_010);
    // Give the stream a turn to process the notification.
    await Future<void>.delayed(Duration.zero);
    expect(host.reading.value?.bpm, 120);
    await link.close();
    await future;
    await host.stop();
    expect(host.reading.value, isNull, reason: 'stop() clears the reading');
  });

  test('an admitSample predicate the caller supplies can still refuse a '
      'second (the Oura-style bound, kept separate from any gate)', () async {
    final host = BandHost(
      adapter: kBleHrsAdapter,
      deviceId: deviceId,
      admitSample: (ts) => ts != 1_800_000_030,
    );
    final link = ReplayBandLink();
    final future = host.run(link);
    link.feed('00002a37-0000-1000-8000-00805f9b34fb', kHrWithTwoRr,
        atSec: 1_800_000_030);
    await link.close();
    await future;
    await host.stop();

    final db = await LocalDb.instance;
    final onehz = await db.query('decoded_onehz');
    expect(onehz, isEmpty);
  });

  test('the sync_cursor advance is namespaced to THIS device, never the '
      'primary\'s bare key', () async {
    final host = BandHost(adapter: kBleHrsAdapter, deviceId: deviceId);
    final link = ReplayBandLink();
    final future = host.run(link);
    link.feed('00002a37-0000-1000-8000-00805f9b34fb', kHrWithTwoRr,
        atSec: 1_800_000_020);
    await link.close();
    await future;
    await host.stop();

    expect(await LocalDb.getCursorInt(LocalDb.cursorKeyFor('rec_ts_hw', deviceId)),
        1_800_000_020);
    expect(await LocalDb.getCursorInt('rec_ts_hw'), isNull,
        reason: 'the primary\'s bare cursor key must be untouched');
  });

  test('a failed batch commit reports host_commit_failed and never '
      'confirms the checkpoint', () async {
    // The checkpoint contract: `confirm()` only after a durable commit.
    // A minimal adapter that yields a batch AND a checkpoint makes the
    // confirm call directly observable; the injected commit failure must
    // emit `host_commit_failed`, never confirm, and leave nothing stored.
    final notes = <String>[];
    var confirmed = false;
    final adapter = _CheckpointAdapter(() async {
      confirmed = true;
      return true;
    });
    final host = BandHost(
      adapter: adapter,
      deviceId: deviceId,
      onNote: (key, _) => notes.add(key),
      faultCommitForTest: (commit) async {
        throw StateError('injected durable commit failure');
      },
    );
    final link = ReplayBandLink();
    final future = host.run(link);
    await link.close();
    await future;
    await host.stop();

    expect(notes, contains('host_commit_failed'),
        reason: 'the host observed the failed durable commit itself');
    expect(confirmed, isFalse,
        reason: 'confirm() must never run for a batch that did not land');
    final db = await LocalDb.instance;
    expect(
      await db.query('decoded_onehz',
          where: 'device_id = ?', whereArgs: [deviceId]),
      isEmpty,
      reason: 'nothing from the failed transaction reached the table',
    );
  });

  test('a session still running during "delete everything" writes nothing '
      'and never confirms', () async {
    // A chest strap armed by a workout, or an Oura offload, is not stopped by
    // the primary band's unpair. Whatever it commits after the wipe would put
    // a deleted device's rows back into the fresh store.
    addTearDown(ResetGate.resetForTest);
    final notes = <String>[];
    var confirmed = false;
    final adapter = _CheckpointAdapter(() async {
      confirmed = true;
      return true;
    });
    final host = BandHost(
      adapter: adapter,
      deviceId: deviceId,
      onNote: (key, _) => notes.add(key),
    );
    ResetGate.enter();
    final link = ReplayBandLink();
    final future = host.run(link);
    await link.close();
    await future;
    await host.stop();
    ResetGate.leave();

    expect(confirmed, isFalse,
        reason: 'the device keeps what was never banked');
    expect(notes, contains('host_commit_failed'));
    final db = await LocalDb.instance;
    expect(await db.query('decoded_onehz'), isEmpty);
    expect(await db.query('sync_cursor'), isEmpty);
    expect(await db.query('compute_jobs'), isEmpty,
        reason: 'no derive is queued over a wiped store');
  });

  test('a session that began before a reset that has since finished still '
      'writes nothing', () async {
    // An Oura sync queued on the secondary-link slot, or a scale connect
    // still in flight, can outlive the reset: by the time it commits the gate
    // is down again, and only the generation it started under tells it the
    // store it was writing for is gone.
    addTearDown(ResetGate.resetForTest);
    final notes = <String>[];
    var confirmed = false;
    final startedUnder = ResetGate.generation;
    ResetGate.enter();
    ResetGate.leave();
    expect(ResetGate.active, isFalse);
    final host = BandHost(
      adapter: _CheckpointAdapter(() async {
        confirmed = true;
        return true;
      }),
      deviceId: deviceId,
      onNote: (key, _) => notes.add(key),
      resetGeneration: startedUnder,
    );
    final link = ReplayBandLink();
    final future = host.run(link);
    await link.close();
    await future;
    await host.stop();

    expect(confirmed, isFalse);
    expect(notes, contains('host_commit_failed'));
    final db = await LocalDb.instance;
    expect(await db.query('decoded_onehz'), isEmpty);
    expect(await db.query('compute_jobs'), isEmpty);
  });

  test('a batch already queued on the commit gate refuses once the reset '
      'has started', () async {
    addTearDown(ResetGate.resetForTest);
    await LocalDb.instance;
    ResetGate.enter();
    await expectLater(
        LocalDb.commitSyncBatch(const [], const []), throwsStateError);
    // The wipe itself runs on the same gate and still completes.
    await LocalDb.wipeAll();
    ResetGate.leave();
    await LocalDb.commitSyncBatch(const [], const []);
  });

  test('the control case: a landed commit confirms and emits no '
      'host_commit_failed', () async {
    final notes = <String>[];
    var confirmed = false;
    final adapter = _CheckpointAdapter(() async {
      confirmed = true;
      return true;
    });
    final host = BandHost(
      adapter: adapter,
      deviceId: deviceId,
      onNote: (key, _) => notes.add(key),
    );
    final link = ReplayBandLink();
    final future = host.run(link);
    await link.close();
    await future;
    await host.stop();

    expect(notes, isNot(contains('host_commit_failed')));
    expect(confirmed, isTrue,
        reason: 'the landed commit must confirm the checkpoint');
    final db = await LocalDb.instance;
    expect(
      await db.query('decoded_onehz',
          where: 'device_id = ?', whereArgs: [deviceId]),
      isNotEmpty,
      reason: 'the successful commit durably stored its rows',
    );
  });

  group('sessionFailed', () {
    Future<BandHost> runOnce(_CheckpointAdapter adapter) async {
      final host = BandHost(adapter: adapter, deviceId: deviceId);
      final link = ReplayBandLink();
      final future = host.run(link);
      await link.close();
      await future;
      await host.stop();
      return host;
    }

    test('is false when every row landed and was confirmed', () async {
      final host = await runOnce(_CheckpointAdapter(() async => true));
      expect(host.sessionFailed, isFalse);
    });

    test('is true when the device refused the confirmation', () async {
      final host = await runOnce(_CheckpointAdapter(() async => false));
      expect(host.sessionFailed, isTrue);
    });

    test('is true when the adapter stream ended on an error', () async {
      final host = await runOnce(
          _CheckpointAdapter(() async => true, failAtEnd: true));
      expect(host.sessionFailed, isTrue);
      expect(host.vendorWriteFailed, isFalse);
    });

    test('is true when a reset refused the session\'s commits', () async {
      final adapter = _CheckpointAdapter(() async => true);
      final host = BandHost(adapter: adapter, deviceId: deviceId);
      ResetGate.enter();
      try {
        final link = ReplayBandLink();
        final future = host.run(link);
        await link.close();
        await future;
        await host.stop();
      } finally {
        ResetGate.leave();
      }
      expect(host.sessionFailed, isTrue);
    });
  });
}

/// Minimal adapter for the checkpoint-contract tests: one batch with one
/// sample, then one checkpoint whose confirm is observable. `kBleHrs`'s own
/// entry is reused so the stored family/source keys stay realistic.
class _CheckpointAdapter extends BandAdapter {
  final Future<bool> Function() _confirm;
  final bool failAtEnd;
  _CheckpointAdapter(this._confirm, {this.failAtEnd = false});

  @override
  BandEntry get entry => kBleHrs;

  @override
  Map<InputSignal, Duration> get signals => const {};

  @override
  Stream<BandEvent> run(BandLink link) async* {
    yield SampleBatch([
      NeutralSample(
        anchor: entry.timeAnchor,
        tsEpoch: 1_800_000_060,
        hr: 100,
      ),
    ]);
    yield OffloadCheckpoint(_confirm);
    if (failAtEnd) throw StateError('transfer cut short');
  }
}
