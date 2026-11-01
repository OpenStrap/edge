@Timeout(Duration(minutes: 10))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/sleep_profile_policy.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/ed2a_recalc_fixture.dart';

Future<void> _profile({String field = 'hr_floor_p5', int delta = 1}) async {
  final p = {...const ana.SleepUserProfile(nights: 14, hrFloorP5: 48,
    hrFloorP25: 51, hrSleepMedian: 55, hrArousal: 70, rmssdMed: 40,
    rmssdMad: 5, enmoStillCut: 0.02, enmoMoveCut: 0.1,
    lfhfMed: 1, rkMed: 2).toJson(), 'folded_days': [edDay]};
  p[field] = (p[field] as num) + delta;
  await LocalDb.putBaseline('sleep_user_profile', jsonEncode(p));
}

Future<void> _history({int shift = 0}) async {
  final db = await LocalDb.instance;
  for (var i = 1; i <= 14; i++) {
    final d = DateTime(2020, 1, 2 - i);
    final start = DateTime(d.year, d.month, d.day, 1).millisecondsSinceEpoch;
    await db.insert('day_result', {'day_id': dayLabelOf(d),
      'algo_version': kAlgoVersion, 'payload_json': '{}', 'computed_at': 1,
      'window_json': jsonEncode({'onset_ms': start + shift * 1000,
        'offset_ms': start + (6 * 3600 + shift) * 1000})},
      conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

Future<void> _vendor({String stage = 'light', String id = ''}) async {
  final db = await LocalDb.instance;
  for (final (offset, duration, label) in [(0, 7200, stage),
      (7200, 3600, 'deep'), (10800, 3600, 'rem')]) {
    await db.insert('vendor_sleep_epoch', {
      'device_id': id, 'night_onset_ts': edStart, 'start_ts': edStart + offset,
      'end_ts': edStart + offset + duration, 'stage': label,
      'source': 'gen4', 'decoded_at': 1,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

void main() {
  final originalZone = Platform.environment['TZ'] ?? 'UTC';
  setUpAll(edInit);
  setUp(() async {
    await edFresh('ed2a_e12.db');
    await edRows(edStart, edStart + 1200, hr: 60, az: 1);
  });
  tearDown(() async { edSetZone(originalZone); await edDrop(); });

  test('unchanged staging input is computed once, including absent sleep', () async {
    final e = DerivationEngine();
    final first = await e.debugSleepCandidate(edDay);
    expect(e.debugStagingComputations, 1);
    final again = await e.debugSleepCandidate(edDay);
    expect(jsonEncode(again.toJson()), jsonEncode(first.toJson()));
    expect(e.debugStagingComputations, 1,
        reason: 'the second call must reuse the worker result, even absence');
  });

  test('the staging worker closure does not drag the engine into the isolate', () async {
    // AppState hands its engine a callback over its own fields (BLE phase
    // futures among them). If the worker closure captured the engine, that
    // callback would ride into Isolate.run and the send would be refused.
    final unsendable = Completer<void>();
    final e = DerivationEngine(offloadActive: () => unsendable.isCompleted);
    final c = await e.debugSleepCandidate(edDay);
    expect(c.toJson(), isNotNull);
    expect(e.debugStagingComputations, 1);
  });

  final changes = <String, Future<void> Function(DerivationEngine)>{
    'identical input replacement': (_) => edRows(edStart, edStart + 1, hr: 60, az: 1),
    'late RR revision': (_) async {
      await (await LocalDb.instance).insert('decoded_rr', {'device_id': '',
        'ts_ms': edStart * 1000, 'rec_ts': edStart, 'rr_ts_ms': edStart * 1000, 'beat_index': 0, 'rr_ms': 900});
    },
    'search lookback revision on previous local day': (_) =>
        edRows(DateTime(2020, 1, 1, 22).millisecondsSinceEpoch ~/ 1000,
          DateTime(2020, 1, 1, 22).millisecondsSinceEpoch ~/ 1000 + 1),
    'store generation with unchanged revisions': (_) async {
      final before = await LocalDb.inputDayFingerprint(edDay);
      await LocalDb.close(); await LocalDb.instance;
      final after = await LocalDb.inputDayFingerprint(edDay);
      expect(after.revisionSum, before.revisionSum);
      expect(after.generation, greaterThan(before.generation));
    },
    'algorithm': (e) async { e.debugStagedSleepCacheRekey(kAlgoVersion - 1); },
    'HR ownership': (_) => edOwnership(signals: ['hr1Hz']),
    'accel ownership': (_) => edOwnership(signals: ['accel1Hz']),
    'PPG ownership': (_) => edOwnership(signals: ['ppgRedIr']),
    'skin-temperature ownership': (_) => edOwnership(signals: ['skinTempRaw']),
    'RR ownership': (_) async {
      await (await LocalDb.instance).insert('device_coverage', {
        'device_id': 'rr-owner', 'signal': 'rrIntervals', 'start_ts': edStart,
        'end_ts': edStart + 600});
      await (await LocalDb.instance).insert('signal_priority', {
        'device_id': 'rr-owner', 'signal': 'rrIntervals', 'rank': 0, 'user_set': 1});
    },
    'priority': (_) async {
      await (await LocalDb.instance).insert('signal_priority', {'signal': 'hr1Hz',
        'device_id': '', 'rank': 4, 'user_set': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
    },
    'family': (_) async { await (await LocalDb.instance).update(
      'decoded_onehz', {'device_family': 'gen5'}); },
    'history at 14 distinct nights': (_) => _history(shift: 60),
    'manual override': (_) => LocalDb.putSleepOverride(dayId: edDay,
        onsetTs: edStart, offsetTs: edStart + 900, source: 'manual'),
    'confirmed wake override': (_) => LocalDb.putSleepOverride(dayId: edDay,
        onsetTs: edStart, offsetTs: edStart + 900, source: 'confirmed'),
    'override onset edit': (_) => LocalDb.putSleepOverride(dayId: edDay,
        onsetTs: edStart + 30, offsetTs: edStart + 900, source: 'manual'),
    'override offset edit': (_) => LocalDb.putSleepOverride(dayId: edDay,
        onsetTs: edStart, offsetTs: edStart + 960, source: 'manual'),
    'override source edit': (_) => LocalDb.putSleepOverride(dayId: edDay,
        onsetTs: edStart, offsetTs: edStart + 900, source: 'rejected'),
    'override removal': (_) => LocalDb.deleteSleepOverride(edDay),
    'vendor source': (_) async { await (await LocalDb.instance).update(
        'vendor_sleep_epoch', {'source': 'miband234'}); },
    'vendor decode revision': (_) async { await (await LocalDb.instance).update(
        'vendor_sleep_epoch', {'decoded_at': 2}); },
    'vendor window': (_) async { await (await LocalDb.instance).update(
        'vendor_sleep_epoch', {'end_ts': edStart + 14460},
        where: 'start_ts = ?', whereArgs: [edStart + 10800]); },
    'vendor stages': (_) => _vendor(stage: 'deep'),
    'vendor device': (_) => _vendor(id: 'vendor-other'),
    'vendor flag': (_) => LocalDb.setCursor('wearable_enabled:garmin', '1'),
    'active wearable': (_) => LocalDb.setCursor('active_wearable', 'garmin-y'),
    'zone': (_) async { edSetZone('Pacific/Auckland'); },
    // Denver and Phoenix agree in winter, but disagree in the summer search
    // window. The separate historical-zone case below pins that distinction.
    for (final field in ['nights', 'hr_floor_p5', 'hr_floor_p25',
      'hr_sleep_median', 'hr_arousal', 'rmssd_med', 'rmssd_mad',
      'enmo_still_cut', 'enmo_move_cut', 'lfhf_med', 'rk_med', 'updated_at_ms'])
      'profile $field': (_) => _profile(field: field),
  };
  for (final entry in changes.entries) {
    test('${entry.key}: miss, exact output, then hit on the new key', () async {
      if (entry.key == 'override removal' || entry.key.startsWith('override ') && entry.key.endsWith(' edit')) {
        await LocalDb.putSleepOverride(dayId: edDay, onsetTs: edStart,
            offsetTs: edStart + 900, source: 'manual');
      }
      if (entry.key == 'priority') await edPriorityOrder(['', 'other']);
      if (entry.key.startsWith('profile ')) await _profile(delta: 0);
      if (entry.key.startsWith('history ')) await _history();
      if (entry.key.startsWith('vendor ') || entry.key == 'active wearable') {
        await _vendor();
        await LocalDb.upsertDevice(id: 'garmin-x', adapterId: 'garmin', label: 'watch');
        await LocalDb.setCursor('active_wearable', 'garmin-x');
        await _vendor(id: 'garmin-x');
      }
      if (entry.key == 'vendor flag' || entry.key == 'active wearable') {
        await (await LocalDb.instance).delete('decoded_onehz');
        await (await LocalDb.instance).delete('vendor_sleep_epoch',
            where: 'device_id = ?', whereArgs: ['']);
      }
      if (entry.key == 'vendor device') {
        await LocalDb.upsertDevice(id: 'vendor-other', adapterId: 'garmin', label: 'new vendor');
        await LocalDb.setCursor('active_wearable', 'vendor-other');
        await LocalDb.setCursor('wearable_enabled:garmin', '1');
        await (await LocalDb.instance).delete('decoded_onehz');
      }
      if (entry.key == 'active wearable') {
        await LocalDb.upsertDevice(id: 'garmin-y', adapterId: 'garmin', label: 'watch2');
        await _vendor(id: 'garmin-y');
        await LocalDb.setCursor('wearable_enabled:garmin', '1');
      }
      final e = DerivationEngine();
      await e.debugSleepCandidate(edDay);
      final count = e.debugStagingComputations;
      await entry.value(e);
      final changed = await e.debugSleepCandidate(edDay);
      expect(e.debugStagingComputations, count + 1,
          reason: 'changed ${entry.key} must invalidate the staged result');
      final cold = DerivationEngine()..debugDisableStagedSleepCache = true;
      expect(jsonEncode(changed.toJson()),
          jsonEncode((await cold.debugSleepCandidate(edDay)).toJson()));
      await e.debugSleepCandidate(edDay);
      expect(e.debugStagingComputations, count + 1,
          reason: 'the replacement entry must now hit');
    });
  }

  test('same present-day zone name/offset cannot hide historical night offsets', () async {
    edSetZone('America/Chihuahua');
    final nowOffset = DateTime.now().timeZoneOffset;
    final nowName = DateTime.now().timeZoneName;
    final historical = DateTime.fromMillisecondsSinceEpoch(edStart * 1000).timeZoneOffset;
    final e = DerivationEngine();
    await e.debugSleepCandidate(edDay);
    final before = e.debugStagingComputations;
    edSetZone('America/Guatemala');
    expect(DateTime.now().timeZoneOffset, nowOffset);
    expect(DateTime.now().timeZoneName, nowName);
    expect(DateTime.fromMillisecondsSinceEpoch(edStart * 1000).timeZoneOffset,
        isNot(historical), reason: 'fixture zones agree now but differed in January 2020');
    final changed = await e.debugSleepCandidate(edDay);
    expect(e.debugStagingComputations, before + 1);
    final cold = await DerivationEngine().debugSleepCandidate(edDay);
    expect(jsonEncode(changed.toJson()), jsonEncode(cold.toJson()));
    await e.debugSleepCandidate(edDay);
    expect(e.debugStagingComputations, before + 1, reason: 'new historical-offset key must hit');
  });

  test('selected derive followed by baseline rescan reuses actual staging work', () async {
    final e = DerivationEngine();
    expect(await e.runDays(edProfile, {edDay}), 1);
    final before = e.debugStagingComputations;
    expect(before, greaterThan(0));
    await LocalDb.setCursor('baseline_sig', 'force-ed2a-rescan');
    expect(await e.rescanRecent(edProfile), greaterThan(0));
    expect(e.debugStagingComputations, before,
        reason: 'baseline recompute must not rerun the unchanged staging worker');
  });

  test('a nonfolding entry cannot satisfy a later mayFold request', () async {
    final e = DerivationEngine();
    final modes = <bool>[];
    e.debugOnStagingWalk = (fold, _, _) => modes.add(fold);
    await e.debugSleepCandidate(edDay);
    expect(modes, [false]);
    final edge = DateTime(2020, 1, 3, 12).millisecondsSinceEpoch ~/ 1000;
    await edRows(edge, edge + 1);
    final changed = await e.debugSleepCandidate(edDay);
    expect(modes, [false, true], reason: 'a hit without an observation cannot suppress a fold');
    final cold = await DerivationEngine().debugSleepCandidate(edDay);
    expect(jsonEncode(changed.toJson()), jsonEncode(cold.toJson()));
    final count = e.debugStagingComputations;
    await e.debugSleepCandidate(edDay);
    expect(e.debugStagingComputations, count, reason: 'fold-capable result is reusable even when observation is absent');
  });

  test('bounded staging cache retains only the most recent two days', () async {
    final e = DerivationEngine()..debugStagedSleepCacheMaxDays = 2;
    for (final day in ['2020-01-01', edDay, '2020-01-03']) {
      await e.debugSleepCandidate(day);
      expect(e.debugStagedSleepCacheSize, lessThanOrEqualTo(2));
    }
    expect(e.debugStagedSleepCacheSize, 2,
        reason: 'three distinct staging keys must populate the bounded cache');
    final count = e.debugStagingComputations;
    await e.debugSleepCandidate('2020-01-03');
    expect(e.debugStagingComputations, count);
    await e.debugSleepCandidate('2020-01-01');
    expect(e.debugStagingComputations, count + 1, reason: 'oldest day was evicted');
  });

  test('existing fixture: cached and uncached derive JSON stays exact after invalidation', () async {
    await edExistingFixture();
    final cached = DerivationEngine();
    final uncached = DerivationEngine()..debugDisableStagedSleepCache = true;
    await edPreparedOutput(cached);
    expect(await edPreparedOutput(cached), await edPreparedOutput(uncached));
    await edRows(edStart, edStart + 1, hr: 87);
    expect(await edPreparedOutput(cached), await edPreparedOutput(uncached));
  });

  test('profile fold bookkeeping remains idempotent (passing guard)', () {
    final p = SleepProfilePolicy.withFoldedDays(
        const ana.SleepUserProfile(nights: 3).toJson(), {}, edDay);
    expect(SleepProfilePolicy.shouldFold(alreadyFolded: {edDay},
        dayId: edDay, hasOverride: false), isFalse);
    expect(SleepProfilePolicy.foldedDays(jsonEncode(p)), {edDay});
  });
}
