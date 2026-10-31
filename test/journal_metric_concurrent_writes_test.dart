// Every journal_metric write replaces the whole day, so two callers that each
// read the day and write it back on the same date used to interleave
// read/read/write/write, and the second write erased the first one's field.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_actions.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'journal_metric_concurrent_writes_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });
  tearDownAll(() => LocalDb.close());

  test('two coach writes on one day both survive', () async {
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    const date = '2026-10-16';
    await Future.wait([
      CoachActions.logJournalFields(repo, {
        'date': date,
        'fields': {'water_ml': 250},
      }),
      CoachActions.logJournalFields(repo, {
        'date': date,
        'fields': {'mood': 4},
      }),
    ]);
    final day = await LocalDb.journalMetricsForDay(date);
    expect(day.keys.toSet(), {'water_ml', 'mood'});
  });

  test('a water tap and a journal save on one day both survive, across '
      'separate repository instances', () async {
    final gestureRepo = LocalRepositoryImpl(getProfileMap: () => const {});
    final screenRepo = LocalRepositoryImpl(getProfileMap: () => const {});
    const date = '2026-10-17';
    final spec = kJournalFieldsByKey['water_ml']!;
    await Future.wait([
      gestureRepo.editJournalMetrics(date, (day) {
        final now = day['water_ml']?.value ?? 0;
        day['water_ml'] = JournalMetricValue(now + spec.step);
      }),
      screenRepo.editJournalMetrics(date, (day) {
        day['mood'] = const JournalMetricValue(4);
      }),
      gestureRepo.editJournalMetrics(date, (day) {
        final now = day['water_ml']?.value ?? 0;
        day['water_ml'] = JournalMetricValue(now + spec.step);
      }),
    ]);
    final day = await LocalDb.journalMetricsForDay(date);
    expect(day.keys.toSet(), {'water_ml', 'mood'});
    expect(day['water_ml']!.value, spec.step * 2);
  });

  test('a throwing edit does not wedge later writes', () async {
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    const date = '2026-10-15';
    await expectLater(
      repo.editJournalMetrics(date, (_) => throw StateError('boom')),
      throwsStateError,
    );
    await repo.editJournalMetrics(date, (day) {
      day['mood'] = const JournalMetricValue(3);
    });
    final day = await LocalDb.journalMetricsForDay(date);
    expect(day.keys, ['mood']);
  });
}
