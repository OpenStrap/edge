@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/readiness_calibration_backfill.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/ed2a_recalc_fixture.dart';
import 'readiness_calibration_backfill_test.dart' show bundle;

const _watch = ('garmin-a', 'garmin');
Future<void> _wearable() async {
  await LocalDb.upsertDevice(id: _watch.$1, adapterId: _watch.$2, label: 'Watch A');
  await LocalDb.setCursor(kActiveWearableCursor, _watch.$1);
  await LocalDb.setCursor(wearableEnabledCursor(_watch.$2), '1');
  await edRows(edStart, edStart + 1200, id: _watch.$1, family: _watch.$2,
      source: _watch.$2, hr: 70, az: 0);
}

void main() {
  setUpAll(edInit);
  setUp(() async { await edFresh('ed2a_e19.db'); await _wearable(); });
  tearDown(() async {
    endWearableDayIndexPass();
    debugOnWearableDayIndexScan = null;
    debugDisableWearableDayIndex = false;
    await edDrop();
  });

  test('one real wearable scan per pass; new pass sees newly appended days', () async {
    var scans = 0;
    debugOnWearableDayIndexScan = (_, _) => scans++;
    beginWearableDayIndexPass();
    try {
      final first = await wearableRecTsMaxByDay(_watch);
      expect(first, {edDay: edStart + 1199});
      expect(await wearableRecTsMaxByDay(_watch), first);
      expect(scans, 1, reason: 'second request in the same pass must hit');
    } finally { endWearableDayIndexPass(); }
    expect(debugWearableDayIndexSize, 0);
    final later = DateTime(2020, 1, 3, 10).millisecondsSinceEpoch ~/ 1000;
    await edRows(later, later + 1, id: _watch.$1, family: _watch.$2, source: _watch.$2);
    beginWearableDayIndexPass();
    try {
      expect((await wearableRecTsMaxByDay(_watch)).keys, contains('2020-01-03'));
      expect(scans, 2, reason: 'an index belongs to one pass, not to the engine lifetime');
    } finally { endWearableDayIndexPass(); }
  });

  for (final change in ['input revision', 'generation', 'algorithm']) {
    test('$change cannot lend a stale index to the next request', () async {
      var scans = 0;
      debugOnWearableDayIndexScan = (_, _) => scans++;
      beginWearableDayIndexPass();
      try { await wearableRecTsMaxByDay(_watch); }
      finally { endWearableDayIndexPass(); }
      switch (change) {
        case 'input revision': await edRows(edStart, edStart + 1,
            id: _watch.$1, family: _watch.$2, source: _watch.$2, hr: 80);
        case 'generation': await LocalDb.close(); await LocalDb.instance;
        case 'algorithm': debugWearableDayIndexRekey(kAlgoVersion - 1);
      }
      beginWearableDayIndexPass();
      try {
        final fresh = await wearableRecTsMaxByDay(_watch);
        expect(fresh, {edDay: edStart + 1199});
        expect(scans, 2, reason: 'the changed context belongs to a fresh pass');
        expect(await wearableRecTsMaxByDay(_watch), fresh);
        expect(scans, 2, reason: 'unchanged second request in that pass must hit');
      } finally { endWearableDayIndexPass(); }
    });
  }

  for (final key in ['device', 'family']) {
    test('different wearable $key gets its own pass key', () async {
      var scans = 0;
      debugOnWearableDayIndexScan = (_, _) => scans++;
      final other = key == 'device' ? ('garmin-b', 'garmin') : ('garmin-a', 'oura');
      beginWearableDayIndexPass();
      try {
        final original = await wearableRecTsMaxByDay(_watch);
        final changed = await wearableRecTsMaxByDay(other);
        expect(changed, isEmpty);
        expect(original, isNotEmpty);
        expect(scans, 2, reason: 'a different $key must miss');
        expect(await wearableRecTsMaxByDay(_watch), original);
        expect(await wearableRecTsMaxByDay(other), changed);
        expect(scans, 2, reason: 'both keys, including empty index, should now hit');
      } finally { endWearableDayIndexPass(); }
    });
  }

  test('index is discarded when body throws after a populated lookup', () async {
    var scans = 0;
    var populated = 0;
    debugOnWearableDayIndexScan = (_, _) => scans++;
    Future<void> failedPass() async {
      beginWearableDayIndexPass();
      try {
        expect(await wearableRecTsMaxByDay(_watch), isNotEmpty);
        populated = debugWearableDayIndexSize;
        throw StateError('after index fill');
      } finally { endWearableDayIndexPass(); }
    }
    await expectLater(failedPass(), throwsStateError);
    expect(debugWearableDayIndexSize, 0);
    beginWearableDayIndexPass();
    try { await wearableRecTsMaxByDay(_watch); }
    finally { endWearableDayIndexPass(); }
    expect(scans, 2, reason: 'the failed pass cannot lend its index to a retry');
    expect(populated, 1, reason: 'exception cleanup must be tested with an occupied index');
  });

  test('real run clears the index and running latch on an injected scan failure', () async {
    var scans = 0;
    var occupiedDuringFailure = 0;
    debugOnWearableDayIndexScan = (_, _) {
      scans++;
      if (scans == 1) {
        occupiedDuringFailure = debugWearableDayIndexSize;
        throw StateError('injected after wearable scan');
      }
    };
    final e = DerivationEngine();
    await e.run(edProfile);
    expect(e.running, isFalse, reason: 'failure must release the process-wide latch');
    expect(e.snapshot()['last_error'], contains('injected after wearable scan'));
    expect(debugWearableDayIndexSize, 0, reason: 'outer finally must release the pass index');
    final beforeRetry = scans;
    expect(await e.run(edProfile), greaterThan(0));
    expect(scans, greaterThan(beforeRetry), reason: 'retry must build a fresh index');
    expect(occupiedDuringFailure, 1, reason: 'the fault must occur after population');
  });

  test('actual light run scans the wearable index once through readiness backfill', () async {
    var scans = 0;
    debugOnWearableDayIndexScan = (_, _) => scans++;
    final e = DerivationEngine();
    expect(await e.run(edProfile), greaterThan(0));
    expect(scans, 1, reason: 'scope, edge and readiness backfill share the pass index');
    expect(debugWearableDayIndexSize, 0);
  });

  test('lookups outside a pass stay fresh (passing guard)', () async {
    var scans = 0;
    debugOnWearableDayIndexScan = (_, _) => scans++;
    await wearableRecTsMaxByDay(_watch);
    final t = DateTime(2020, 1, 3, 10).millisecondsSinceEpoch ~/ 1000;
    await edRows(t, t + 1, id: _watch.$1, family: _watch.$2, source: _watch.$2);
    expect((await wearableRecTsMaxByDay(_watch)).keys, contains('2020-01-03'));
    expect(scans, 2);
    expect(debugWearableDayIndexSize, 0);
  });

  test('readiness backfill defers wearable substrate and still rescores pruned days (guard)', () async {
    for (final day in [edDay, '2020-01-01']) {
      final payload = bundle(0.5, 0.5, 0);
      await LocalDb.putDayResult(dayId: day, algoVersion: 111,
        payloadJson: jsonEncode(payload), windowJson: '{}', finalized: true,
        readiness: (payload['scalars'] as Map)['readiness'] as double);
    }
    final before = await edStored(edDay);
    beginWearableDayIndexPass();
    late final ({int seeded, int rescored, int forced}) result;
    try {
      final raw = await substrateDays();
      expect(raw, contains(edDay));
      result = await backfillReadinessCalibration(rawDays: raw,
          zHistoryLoader: () async => (day, family) => <double>[]);
    } finally { endWearableDayIndexPass(); }
    expect(result.rescored, 1, reason: 'pruned history still needs calibration');
    expect(result.forced, 0);
    expect((await LocalDb.dayResult('2020-01-01'))!['algo_version'], kAlgoVersion);
    expect((await LocalDb.dayResult(edDay))!['algo_version'], 111,
        reason: 'wearable substrate must wait for its own derive');
    // readiness_z seeding is intentional; the day bundle must remain untouched.
    final row = await LocalDb.dayResult(edDay);
    expect(jsonDecode(before)['day_result'][0]['payload_json'], row!['payload_json']);
  });

  test('existing fixture: pass index enabled/disabled derive JSON remains exact (guard)', () async {
    await edExistingFixture();
    final e = DerivationEngine();
    expect(await e.runDays(edProfile, {edDay}), 1);
    final indexed = await edStored(edDay);
    debugDisableWearableDayIndex = true;
    expect(await DerivationEngine().runDays(edProfile, {edDay}), 1);
    expect(await edStored(edDay), indexed);
    debugDisableWearableDayIndex = false;
    await edRows(edStart, edStart + 1, hr: 89);
    expect(await e.runDays(edProfile, {edDay}), 1);
    final changed = await edStored(edDay);
    debugDisableWearableDayIndex = true;
    expect(await DerivationEngine().runDays(edProfile, {edDay}), 1);
    expect(await edStored(edDay), changed);
  });
}
