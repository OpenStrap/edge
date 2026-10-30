// A sleep correction has to reach the derived day: it must not be dropped
// because another derive pass holds the latch, and the morning readiness pin
// must not keep showing the uncorrected night.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:openstrap_edge/state/app_state.dart';

/// One decoded band second at noon on [day], so the day has substrate for a
/// forced re-derive to reach.
Future<void> _seedDay(String day) async {
  final d = DateTime.parse(day);
  final ts = DateTime(d.year, d.month, d.day, 12).millisecondsSinceEpoch ~/ 1000;
  await (await LocalDb.instance).insert(
    'decoded_onehz',
    {
      'device_id': '',
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': ts % 100000,
      'hr': 60,
      'ax': 0.0,
      'ay': -0.5,
      'az': 0.98,
      'device_family': 'gen4',
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_sleep_override_rederive_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an edit made while another derive pass runs waits for it', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await _seedDay(todayLabel());
    DerivationEngine.debugRunning = true; // a drain pass / rescan in flight
    addTearDown(() => DerivationEngine.debugRunning = false);

    var done = false;
    // A sleep edit; nap edits go through the durable review jobs instead.
    final edit = app
        .setSleepOverride(todayLabel(), DateTime(2026, 9, 30, 0, 30),
            DateTime(2026, 9, 30, 7))
        .then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(done, isFalse,
        reason: 'run() would have returned 0 and the edit was lost');

    DerivationEngine.debugRunning = false;
    await edit;
    expect(done, isTrue);
  });

  test('a pass already running when the edit lands can\'t re-pin the old night',
      () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    DerivationEngine.debugRunning = true; // a drain pass deriving today
    addTearDown(() => DerivationEngine.debugRunning = false);

    final day = todayLabel();
    await _seedDay(day);
    await LocalDb.setFrozenHeadline(day, 45);
    final edit = app.setSleepOverride(
      day,
      DateTime(2026, 9, 30, 0, 30),
      DateTime(2026, 9, 30, 7),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await LocalDb.frozenHeadline(), isNull);

    // The in-flight pass prepared today from the old window and pins it as
    // it finishes; the force pass's nextFrozenHeadline would then hold it.
    await LocalDb.setFrozenHeadline(day, 45);
    DerivationEngine.debugRunning = false;
    await edit;
    expect(await LocalDb.frozenHeadline(), isNull);
  });

  test('an edit doesn\'t wait for a health export already running', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await _seedDay('2026-09-20');
    final exporting = Completer<void>();
    final running = HealthExporter.shared.debugRunLocked(
      () => exporting.future,
    );
    addTearDown(() async {
      if (!exporting.isCompleted) exporting.complete();
      await running;
    });

    var done = false;
    final edit = app
        .setSleepOverride(
          '2026-09-20',
          DateTime(2026, 9, 19, 23),
          DateTime(2026, 9, 20, 7),
        )
        .then((_) => done = true);
    for (var i = 0; i < 40 && !done; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(done, isTrue, reason: 'the sleep sheet spins until the export ends');
    expect(app.reanalyzing, isFalse);

    exporting.complete();
    await running;
    await edit;
  });

  test('correcting the pinned day releases the morning pin', () async {
    // A pin is only ever set after its day's result is written, and a pin
    // whose day has no result is not read.
    await LocalDb.putDayResult(
      dayId: '2026-09-30',
      algoVersion: kAlgoVersion,
      payloadJson: '{}',
      windowJson: '{}',
    );
    await LocalDb.setFrozenHeadline('2026-09-30', 45);
    await LocalDb.putSleepOverride(
      dayId: '2026-09-29',
      onsetTs: 1000,
      offsetTs: 2000,
      source: 'manual',
    );
    expect((await LocalDb.frozenHeadline())?.value, 45,
        reason: 'another day\'s edit leaves today\'s pin alone');

    await LocalDb.putSleepOverride(
      dayId: '2026-09-30',
      onsetTs: 1000,
      offsetTs: 2000,
      source: 'manual',
    );
    expect(await LocalDb.frozenHeadline(), isNull);

    await LocalDb.setFrozenHeadline('2026-09-30', 62);
    await LocalDb.deleteSleepOverride('2026-09-30');
    expect(await LocalDb.frozenHeadline(), isNull);
  });

  test('a correction on a night whose recordings were pruned is refused, '
      'not stored', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    // No decoded rows for this day: the force re-derive can't reach it, so a
    // stored override would never show and "Re-analyze everything" couldn't
    // apply it either.
    const day = '2026-08-01';
    expect(await app.sleepCorrectable(day), isFalse);
    await expectLater(
      app.setSleepOverride(
          day, DateTime(2026, 7, 31, 23), DateTime(2026, 8, 1, 7)),
      throwsA(isA<SleepCorrectionUnavailable>()),
    );
    expect(await LocalDb.getSleepOverride(day), isNull);
    expect(app.reanalyzing, isFalse);

    // An override stored back when the day still had raw stays put: deleting
    // it would leave the derived night showing the user's window anyway.
    await LocalDb.putSleepOverride(
      dayId: day,
      onsetTs: 1000,
      offsetTs: 2000,
      source: 'manual',
    );
    await expectLater(
      app.clearSleepOverride(day),
      throwsA(isA<SleepCorrectionUnavailable>()),
    );
    expect(await LocalDb.getSleepOverride(day), isNotNull);
    await LocalDb.deleteSleepOverride(day);

    await _seedDay(day);
    expect(await app.sleepCorrectable(day), isTrue);
  });

  test('on the oldest kept night only a correction the prune leaves whole is '
      'offered or stored', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    // The prune cuts on local midnight: the day keeps its own rows but the
    // evening before is gone, and the stored night came from the whole window.
    const day = '2026-08-10';
    final midnight = DateTime(2026, 8, 10).millisecondsSinceEpoch ~/ 1000;
    await _seedDay(day);
    await LocalDb.setCursor('decoded_pruned_before', '$midnight');
    addTearDown(() async => (await LocalDb.instance).delete('sync_cursor',
        where: 'name = ?', whereArgs: ['decoded_pruned_before']));
    await LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: '{}',
      windowJson: '{}',
      rhr: 52,
    );

    // Back to automatic / confirming a bedtime from the evening before would
    // be declined by the derive and keep the stored night.
    expect(await app.sleepCorrectable(day), isFalse);
    expect(
        await app.sleepCorrectable(day,
            sleepSource: 'confirmed', onsetSec: midnight - 3600),
        isFalse);
    // Not sleep and a bedtime after midnight still land.
    expect(await app.sleepCorrectable(day, sleepSource: 'rejected'), isTrue);
    expect(
        await app.sleepCorrectable(day,
            sleepSource: 'manual', onsetSec: midnight + 1800),
        isTrue);

    await expectLater(
      app.setSleepOverride(
          day, DateTime(2026, 8, 9, 23), DateTime(2026, 8, 10, 7)),
      throwsA(isA<SleepCorrectionUnavailable>()
          .having((e) => e.eveningPruned, 'eveningPruned', isTrue)),
    );
    expect(await LocalDb.getSleepOverride(day), isNull);

    await LocalDb.putSleepOverride(
      dayId: day,
      onsetTs: midnight + 1800,
      offsetTs: midnight + 7 * 3600,
      source: 'manual',
    );
    await expectLater(
      app.clearSleepOverride(day),
      throwsA(isA<SleepCorrectionUnavailable>()
          .having((e) => e.eveningPruned, 'eveningPruned', isTrue)),
    );
    expect(await LocalDb.getSleepOverride(day), isNotNull,
        reason: 'refused before the row was deleted');
    await LocalDb.deleteSleepOverride(day);
  });

  test('the prune guard spares a rejected night and keeps a user window on '
      'its own onset', () {
    const day = '2026-08-10';
    final midnight = DateTime(2026, 8, 10).millisecondsSinceEpoch ~/ 1000;
    expect(DerivationEngine.sleepWindowTruncatedByPrune(day, midnight), isTrue);
    expect(
        DerivationEngine.sleepWindowTruncatedByPrune(day, midnight,
            sleepSource: 'rejected'),
        isFalse);
    expect(
        DerivationEngine.sleepWindowTruncatedByPrune(day, midnight,
            sleepSource: 'manual', sleepOnsetSec: midnight + 60),
        isFalse);
    expect(
        DerivationEngine.sleepWindowTruncatedByPrune(day, midnight,
            sleepSource: 'confirmed', sleepOnsetSec: midnight - 60),
        isTrue);
    expect(DerivationEngine.sleepWindowTruncatedByPrune(day, null), isFalse);
  });

  test('a user window that staged to nothing (onset 0) is judged on the '
      "day's lookback, not as cut by every prune", () {
    const day = '2026-08-12';
    final cut = DateTime(2026, 8, 10).millisecondsSinceEpoch ~/ 1000;
    for (final source in ['manual', 'confirmed']) {
      expect(
          DerivationEngine.sleepWindowTruncatedByPrune(day, cut,
              sleepSource: source, sleepOnsetSec: 0),
          isFalse,
          reason: source);
    }
  });
}
