import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/health/health_export.dart';

void main() {
  test('health connect workouts carry no energy record', () {
    // A TotalCaloriesBurnedRecord rides in the same atomic insert as the
    // session, and the app can't write that type, so the whole workout failed.
    const r = {'calories': 320.4};
    expect(healthWorkoutEnergyKcal(r, isApplePlatform: false), isNull);
    expect(healthWorkoutEnergyKcal(r, isApplePlatform: true), 320);
  });

  test('today\'s energy buckets stop at now', () {
    final start = DateTime(2026, 8, 5);
    final end = DateTime(2026, 8, 6);
    final now = DateTime(2026, 8, 5, 10, 20);
    final b = healthEnergyBucketBounds(start, end, now);
    expect(b.first, start);
    expect(b.last, now);
    expect(b.length - 1, 11);
    // A past day still gets every hour.
    expect(healthEnergyBucketBounds(start, end, DateTime(2026, 8, 7)).length,
        25);
  });

  test('legacy steps behind the export cursor get purged once', () async {
    final stored = <String, String>{};
    final deletes = <(DateTime, DateTime)>[];
    Future<void> run(String cursor) => purgeLegacyStepsBehindCursor(
      cursor: cursor,
      getCursor: (name) async => stored[name],
      setCursor: (name, value) async => stored[name] = value,
      deleteSteps: (s, e) async {
        deletes.add((s, e));
        return true;
      },
    );

    await run('2026-08-01');
    expect(deletes, hasLength(1));
    expect(deletes.single.$2, DateTime(2026, 8, 2));
    await run('2026-08-03');
    expect(deletes, hasLength(1), reason: 'one-shot');
  });

  test('a first export with no cursor finishes the purge before it writes',
      () async {
    final stored = <String, String>{};
    final deletes = <(DateTime, DateTime)>[];
    Future<void> run(String cursor) => purgeLegacyStepsBehindCursor(
      cursor: cursor,
      getCursor: (name) async => stored[name],
      setCursor: (name, value) async => stored[name] = value,
      deleteSteps: (s, e) async {
        deletes.add((s, e));
        return true;
      },
    );
    await run('');
    expect(deletes, hasLength(1));
    expect(deletes.single.$2.isAfter(DateTime.now()), isTrue);
    // The next pass, cursor advanced over freshly written steps: no purge.
    await run('2026-08-03');
    expect(deletes, hasLength(1));
  });

  test('a purge the store did not confirm is retried, not marked done',
      () async {
    final stored = <String, String>{};
    var attempts = 0;
    Future<bool> run(Future<bool> Function() answer) =>
        purgeLegacyStepsBehindCursor(
          cursor: '2026-08-01',
          getCursor: (name) async => stored[name],
          setCursor: (name, value) async => stored[name] = value,
          deleteSteps: (s, e) {
            attempts++;
            return answer();
          },
        );
    expect(await run(() async => false), isFalse);
    expect(await run(() async => throw StateError('store')), isFalse);
    expect(stored, isEmpty, reason: 'no marker, so step writes stay held');
    expect(await run(() async => true), isTrue);
    expect(await run(() async => true), isTrue);
    expect(attempts, 3, reason: 'done once confirmed');
  });

  test('only strap counter steps are exported', () {
    const span = {'start_ts': 1000, 'end_ts': 4600, 'steps': 30};
    final out = healthStepSpans({
      'steps': {
        'source': 'strap_counter',
        'spans': [span, {'start_ts': 5000, 'end_ts': 5000, 'steps': 3}],
      },
    });
    expect(out, hasLength(1));
    expect(out.single.steps, 30);
    expect(out.single.start.millisecondsSinceEpoch, 1000000);
    // The phone already writes its own steps to the store.
    for (final source in ['phone', 'strap', 'mixed', null]) {
      expect(healthStepSpans({'steps': {'source': source, 'spans': [span]}}),
          isEmpty);
    }
  });
}
