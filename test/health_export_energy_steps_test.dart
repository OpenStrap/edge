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
}
