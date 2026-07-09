// Regression coverage for the "steps mismatch" bug: getDayStrain (the Body/
// strain-detail screen's data source) used to route steps through the SAME
// _bundleForDate fallback as strain/zones/HR — which, for TODAY specifically,
// falls back to the latest COMPLETE day's bundle when today's own row hasn't
// been derived yet. That's the right UX for strain/sleep/HRV ("show last
// night's finished result while today settles"), but it's actively wrong for
// steps: it silently showed a DIFFERENT day's step count as "today's steps"
// instead of today's own in-progress estimate.
//
// Fix: getDayStrain now sources steps from wake_day_features (today's interim
// estimate — same source getToday() uses for the Today screen) whenever
// today's own day_result row doesn't exist yet, instead of falling through to
// whatever _bundleForDate happened to return.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_day_strain_steps_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  final repo = LocalRepositoryImpl(getProfileMap: () => null);
  final today = todayLabel();
  final yesterday = dayLabelOf(DateTime.now().subtract(const Duration(days: 1)));

  test(
      "when today's own day_result is missing, getDayStrain's steps come "
      'from wake_day_features, NOT a fallback to a prior complete day', () async {
    // Yesterday's finalized bundle exists and has a real (different) steps
    // figure — this is what the old code would have silently surfaced as
    // "today's steps" via _bundleForDate's latest-complete-day fallback.
    await LocalDb.putDayResult(
      dayId: yesterday,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'scalars': {'strain': 8.0, 'steps': 9999},
      }),
      windowJson: '{}',
      finalized: true,
    );

    // Today has NO day_result row yet (derivation hasn't run), but DOES have
    // an interim wake_day_features estimate — the honest "so far today" number.
    await LocalDb.putWakeDayFeatures(
      dayId: today,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({'steps': 321}),
    );

    final strain = await repo.getDayStrain(today);

    expect(
      strain['steps'],
      321,
      reason: 'must use today\'s own interim estimate (wake_day_features), '
          'never a different day\'s finalized step count',
    );
    expect(strain['steps'], isNot(9999));
  });

  test(
      "once today's own day_result exists, getDayStrain's steps come from "
      "today's own bundle again (the fallback path is bypassed)", () async {
    await LocalDb.putDayResult(
      dayId: today,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({
        'scalars': {'strain': 5.0, 'steps': 4321},
      }),
      windowJson: '{}',
      finalized: true,
    );

    final strain = await repo.getDayStrain(today);
    expect(strain['steps'], 4321);
  });

  test(
      'a genuine historical date with no bundle at all returns an honest '
      'empty shape (no fallback, no wake_day_features substitution)', () async {
    final strain = await repo.getDayStrain('2020-01-01');
    expect(strain, isEmpty);
  });
}
