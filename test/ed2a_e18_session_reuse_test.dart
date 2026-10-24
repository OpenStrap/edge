@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/recent_slice.dart';
import 'package:openstrap_edge/data/restore_classification.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/ed2a_recalc_fixture.dart';

Future<void> _light(DerivationEngine e) async {
  expect(await e.run(edProfile), greaterThan(0), reason: 'light pass must reach the real derive');
  expect(e.snapshot()['last_error'], isNull);
}

Future<void> _sessionEdit(Map<String, Object?> patch) async {
  await (await LocalDb.instance).update('sessions', patch,
      where: 'id = ?', whereArgs: ['s1']);
}

void main() {
  setUpAll(edInit);
  setUp(() async {
    await edFresh('ed2a_e18.db');
    await edRows(edStart, edStart + 1200);
    await edSession();
    // These worker-level tests must reach the worker even after main's
    // day fingerprint settles. The integration test below keeps both enabled.
    DerivationEngine.debugDeriveEveryDay = true;
  });
  tearDown(() async {
    DerivationEngine.debugDeriveEveryDay = false;
    await edDrop();
  });

  test('session revisions upgrade from 58 and repair without backfilling sessions', () async {
    var db = await LocalDb.instance;
    final sessions = await db.query('sessions');
    for (final event in ['ai', 'au', 'ad']) {
      await db.execute('DROP TRIGGER sessions_ceiling_$event');
    }
    await db.execute('DROP TABLE session_ceiling_rev');
    await db.setVersion(58);
    await LocalDb.close();
    db = await LocalDb.instance;
    expect(await db.getVersion(), 59);
    expect(await db.query('sessions'), sessions);
    expect(await db.query('session_ceiling_rev'), isEmpty,
        reason: 'upgrade never scans or backfills existing sessions');
    await _sessionEdit({'type': 'run'});
    expect(await LocalDb.sessionCeilingRevision(), 1);
    await LocalDb.repairOpenSchemaForTest(db);
    await LocalDb.repairOpenSchemaForTest(db);
    expect(await LocalDb.sessionCeilingRevision(), 1);
    await LocalDb.setSessionHrr('s1', 20);
    expect(await LocalDb.sessionCeilingRevision(), 1,
        reason: 'derived-only writes do not invalidate input identity');
    await expectLater(db.transaction((txn) async {
      await txn.update('sessions', {'type': 'bike'});
      throw StateError('rollback');
    }), throwsStateError);
    expect(await LocalDb.sessionCeilingRevision(), 1);
    expect((await db.query('sessions')).single['type'], 'run');
  });

  test('session revisions travel in slices, rebuild on restore, and empty on wipe', () async {
    final db = await LocalDb.instance;
    expect(kRestoreClassification['session_ceiling_rev'], RestoreClass.rebuildable);
    expect(kSliceTables['session_ceiling_rev']?.$1, SliceKeep.all);
    expect(LocalDb.restoreTablesForTest, isNot(contains('session_ceiling_rev')));
    expect(await db.query('session_ceiling_rev'), hasLength(1));
    expect(await db.query('input_rev'), isNotEmpty);
    final generation = LocalDb.storeGeneration;
    await LocalDb.wipeAll();
    for (final table in await LocalDb.tableNames()) {
      expect(await db.query(table, limit: 1), isEmpty, reason: table);
    }
    expect(LocalDb.storeGeneration, greaterThan(generation));
    await edSession();
    expect(await LocalDb.sessionCeilingRevision(), 1,
        reason: 'wipe preserves working triggers');
  });

  test('main skips settled days and changed samples still replace reused ceilings', () async {
    DerivationEngine.debugDeriveEveryDay = false;
    final e = DerivationEngine();
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        final derived = await e.run(edProfile);
        expect(e.snapshot()['last_error'], isNull);
        if (derived == 0 && e.lastRunUnchangedDays == 1) return;
      }
      fail('main fingerprint never settled');
    }
    await settle();
    final count = e.debugCeilingComputed;
    expect(count, 1);
    final first = await edStored(edDay);
    expect(await e.run(edProfile), 0);
    expect(e.lastRunUnchangedDays, 1);
    expect(e.debugCeilingComputed, count);
    expect(await edStored(edDay), first);
    await edRows(edStart, edStart + 1200, hr: 160);
    expect(await e.run(edProfile), 1,
        reason: 'changed input must defeat main skip and the old ceiling key');
    expect(e.debugCeilingComputed, count + 1);
    final changed = await edStored(edDay);
    final payload = jsonDecode((await LocalDb.dayResult(edDay))!['payload_json'] as String) as Map;
    expect(payload['scalars']['hr_ceiling_bpm'], 160);
    await settle();
    final cold = DerivationEngine()..debugDisableSessionReuse = true;
    expect(await cold.runDays(edProfile, {edDay}), 1);
    expect(await edStored(edDay), changed);
  });

  test('finished session ceiling is scanned once across unchanged light passes', () async {
    final e = DerivationEngine();
    await _light(e);
    expect(e.debugCeilingComputed, 1);
    final payload = jsonDecode((await LocalDb.dayResult(edDay))!['payload_json'] as String) as Map;
    expect(payload['scalars']['hr_ceiling_bpm'], 170,
        reason: 'motion fixture must contain a real held ceiling');
    final first = await edStored(edDay);
    await _light(e);
    expect(await edStored(edDay), first);
    expect(e.debugCeilingComputed, 1, reason: 'a hit must bypass sessionHrCeiling');
  });

  final edits = <String, Future<void> Function(DerivationEngine)>{
    'decoded sample revision (identical REPLACE)': (_) => edRows(edStart + 30, edStart + 31),
    'decoded sample revision (changed HR)': (_) => edRows(edStart + 30, edStart + 300, hr: 160),
    'late RR input revision': (_) async {
      final t = edStart + 30;
      await (await LocalDb.instance).insert('decoded_rr', {'device_id': '',
        'ts_ms': t * 1000, 'rec_ts': t, 'rr_ts_ms': t * 1000, 'beat_index': 0, 'rr_ms': 900});
    },
    'session revision (identical REPLACE)': (_) => edSession(),
    'session revision (identical UPDATE)': (_) => _sessionEdit({'type': 'run'}),
    'session identity': (_) => _sessionEdit({'id': 's2'}),
    'session type': (_) => _sessionEdit({'type': 'bike'}),
    'session start': (_) => _sessionEdit({'start_ts': edStart + 1}),
    'session end': (_) => _sessionEdit({'end_ts': edStart + 1000}),
    'clipped sample window': (_) async {
      await (await LocalDb.instance).delete('decoded_onehz',
          where: 'rec_ts < ?', whereArgs: [edStart + 10]);
    },
    'family': (_) async { await (await LocalDb.instance).update(
        'decoded_onehz', {'device_family': 'gen5'}); },
    'HR ownership': (_) async {
      // The primary needs coverage too: as the only covering candidate,
      // `other` would own the whole window and leave the day without HR.
      await (await LocalDb.instance).insert('device_coverage', {'device_id': '',
        'signal': 'hr1Hz', 'start_ts': edStart, 'end_ts': edStart + 1200});
      await edOwnership(signals: ['hr1Hz']);
    },
    'accel ownership': (_) async {
      final db = await LocalDb.instance;
      await db.insert('device_coverage', {'device_id': 'other', 'signal': 'accel1Hz',
        'start_ts': edStart, 'end_ts': edStart + 600});
      await db.insert('signal_priority', {'device_id': 'other', 'signal': 'accel1Hz',
        'rank': 0, 'user_set': 1});
    },
    'priority without changed input revisions': (_) async {
      await (await LocalDb.instance).insert('signal_priority', {'signal': 'hr1Hz',
        'device_id': '', 'rank': 2, 'user_set': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
    },
    'store generation': (_) async { await LocalDb.close(); await LocalDb.instance; },
    'algorithm': (e) async { e.debugSessionCacheRekey(kAlgoVersion - 1); },
  };
  for (final edit in edits.entries) {
    test('${edit.key}: miss, exact result, then reuse new key', () async {
      if (edit.key.startsWith('priority ')) await edPriorityOrder(['', 'other']);
      final e = DerivationEngine();
      await _light(e);
      final count = e.debugCeilingComputed;
      expect(count, 1);
      await edit.value(e);
      await _light(e);
      expect(e.debugCeilingComputed, count + 1, reason: 'changed ${edit.key} must rescan');
      final warm = await edStored(edDay);
      final cold = DerivationEngine()..debugDisableSessionReuse = true;
      expect(await cold.runDays(edProfile, {edDay}), 1);
      expect(await edStored(edDay), warm,
          reason: 'includes the full metric envelope and unrounded winning session');
      final after = e.debugCeilingComputed;
      await _light(e);
      expect(e.debugCeilingComputed, after, reason: 'new key should now hit');
    });
  }

  test('an absent ceiling is reusable without inventing a number', () async {
    await edRows(edStart, edStart + 1200, az: 1);
    final e = DerivationEngine();
    await _light(e);
    final first = await edStored(edDay);
    final payload = jsonDecode((await LocalDb.dayResult(edDay))!['payload_json'] as String) as Map;
    expect(payload['hr_ceiling']['value'], '—');
    expect(payload['scalars']['hr_ceiling_bpm'], isNull);
    await _light(e);
    expect(await edStored(edDay), first);
    expect(e.debugCeilingComputed, 1, reason: 'absence is a cached result too');
  });

  test('live sessions always recompute, including done to live transition (guard)', () async {
    final e = DerivationEngine();
    await _light(e);
    await _sessionEdit({'status': 'live'});
    final before = e.debugCeilingComputed;
    await _light(e);
    expect(e.debugCeilingComputed, before + 1);
    await _light(e);
    expect(e.debugCeilingComputed, before + 2);
    await _sessionEdit({'status': 'done'});
    await _light(e);
    expect(e.debugCeilingComputed, before + 3, reason: 'return to done must not resurrect stale entry');
  });

  for (final mode in ['heavy', 'force', 'selected']) {
    test('$mode pass always recomputes (guard)', () async {
      final e = DerivationEngine();
      await _light(e);
      final count = e.debugCeilingComputed;
      final done = switch (mode) {
        'heavy' => await e.run(edProfile, heavy: true),
        'force' => await e.run(edProfile, force: true),
        _ => await e.runDays(edProfile, {edDay}),
      };
      expect(done, greaterThan(0));
      expect(e.debugCeilingComputed, greaterThan(count));
    });
  }

  test('session removal does not keep its former ceiling (guard)', () async {
    final e = DerivationEngine();
    await _light(e);
    await (await LocalDb.instance).delete('sessions', where: 'id = ?', whereArgs: ['s1']);
    await _light(e);
    final got = jsonDecode((await LocalDb.dayResult(edDay))!['payload_json'] as String) as Map;
    expect(got['hr_ceiling']['value'], '—');
    expect(got['scalars']['hr_ceiling_bpm'], isNull);
  });

  test('existing fixture: reuse and forced output byte equality after invalidation (guard)', () async {
    await edExistingFixture();
    final e = DerivationEngine();
    final cold = DerivationEngine()..debugDisableSessionReuse = true;
    await _light(e);
    await _light(e);
    final before = await edStored(edDay);
    await cold.runDays(edProfile, {edDay});
    expect(await edStored(edDay), before);
    await edRows(edStart + 30, edStart + 300, hr: 160);
    await _light(e);
    final changed = await edStored(edDay);
    await cold.runDays(edProfile, {edDay});
    expect(await edStored(edDay), changed);
  });
}
