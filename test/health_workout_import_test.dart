// The pure halves of the workout import: what survives filtering, and what a
// route payload turns into. Both are the places a bad record becomes a wrong
// number on a screen or a line drawn through the Gulf of Guinea.

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openstrap_edge/health/health_workout_import.dart';

HealthDataPoint _w({
  String uuid = 'w1',
  String source = 'Strava',
  HealthWorkoutActivityType type = HealthWorkoutActivityType.RUNNING,
  DateTime? from,
  DateTime? to,
  int? energy,
  int? distance,
  int? steps,
}) =>
    HealthDataPoint(
      uuid: uuid,
      value: WorkoutHealthValue(
        workoutActivityType: type,
        totalEnergyBurned: energy,
        totalDistance: distance,
        totalSteps: steps,
      ),
      type: HealthDataType.WORKOUT,
      unit: HealthDataUnit.NO_UNIT,
      dateFrom: from ?? DateTime(2026, 8, 1, 9),
      dateTo: to ?? DateTime(2026, 8, 1, 10),
      sourceId: 'src',
      sourcePlatform: HealthPlatformType.appleHealth,
      sourceDeviceId: 'dev',
      sourceName: source,
    );

void main() {
  group('workoutsFrom', () {
    test('keeps the recording app\'s name', () {
      final w = workoutsFrom([_w(energy: 512, distance: 8200)]).single;
      expect(w.kind, 'RUNNING');
      // The whole claim is "we did not measure this — they did".
      expect(w.source, 'Strava');
      expect(w.energyKcal, 512.0);
      expect(w.distanceM, 8200.0);
    });

    test('absent energy and distance stay absent, never zero', () {
      // A "0.0 km" under a run is a wrong number, not a missing one.
      final w = workoutsFrom([_w()]).single;
      expect(w.energyKcal, isNull);
      expect(w.distanceM, isNull);
      expect(w.steps, isNull);
    });

    test('a workout with no uuid is skipped, not given a synthetic key', () {
      // A minted key re-inserts the same run on every import.
      expect(workoutsFrom([_w(uuid: '')]), isEmpty);
    });

    test('the same uuid twice yields one row', () {
      expect(workoutsFrom([_w(), _w()]).length, 1);
    });

    test('a workout that ends before it starts is dropped', () {
      final rows = workoutsFrom([
        _w(uuid: 'bad', from: DateTime(2026, 8, 1, 10), to: DateTime(2026, 8, 1, 9)),
        _w(uuid: 'good'),
      ]);
      expect(rows.single.uuid, 'good');
    });

    test('a workout longer than a day is dropped', () {
      // A forgotten "stop" is not a 40-hour run.
      final rows = workoutsFrom([
        _w(
          uuid: 'stuck',
          from: DateTime(2026, 8, 1),
          to: DateTime(2026, 8, 2, 16),
        ),
      ]);
      expect(rows, isEmpty);
    });

    test('an unnamed source still gets attributed', () {
      expect(workoutsFrom([_w(source: '  ')]).single.source, 'Unknown app');
    });
  });

  group('routeRowsFrom', () {
    Map<String, Object?> payload(List<Object?> pts) => {
          'uuid': 'w1',
          'points': pts,
        };

    test('carries session_id itself — appendRoutePoints does not add it', () {
      // LocalDb.appendRoutePoints inserts the maps verbatim; a row without
      // session_id is unreachable by every reader of workout_route.
      final rows = routeRowsFrom(payload([
        [51.5, -0.12, 12.0, 1000],
      ]));
      expect(rows.single['session_id'], 'w1');
      expect(rows.single['seq'], 0);
      expect(rows.single['lat'], 51.5);
      expect(rows.single['ts_ms'], 1000);
    });

    test('seq is dense and ordered after a bad point is dropped', () {
      final rows = routeRowsFrom(payload([
        [51.5, -0.12, 12.0, 1000],
        [999.0, -0.12, 12.0, 2000], // impossible latitude
        [51.6, -0.13, 12.0, 3000],
      ]));
      expect(rows.map((r) => r['seq']), [0, 1]);
      expect(rows.map((r) => r['ts_ms']), [1000, 3000]);
    });

    test('a NaN coordinate is skipped — NaN comparisons are always false', () {
      // lat.abs() > 90 is false for NaN, so the range guard alone lets it
      // through; this needs its own isNaN check.
      expect(routeRowsFrom(payload([
        [double.nan, -0.12, 12.0, 1000],
      ])), isEmpty);
      expect(routeRowsFrom(payload([
        [51.5, double.nan, 12.0, 1000],
      ])), isEmpty);
    });

    test('a null coordinate is skipped, never defaulted to zero', () {
      // (0, 0) is a real place and would draw a line to it.
      expect(routeRowsFrom(payload([
        [null, -0.12, 12.0, 1000],
      ])), isEmpty);
    });

    test('a payload with no uuid yields nothing', () {
      // There would be nothing to key the rows under.
      expect(
        routeRowsFrom({
          'points': [
            [51.5, -0.12, 12.0, 1000],
          ]
        }),
        isEmpty,
      );
    });

    test('malformed payloads are empty, not a throw', () {
      expect(routeRowsFrom(null), isEmpty);
      expect(routeRowsFrom('nope'), isEmpty);
      expect(routeRowsFrom(payload(const [])), isEmpty);
      expect(routeRowsFrom(payload([1, 'x'])), isEmpty);
    });

    test('altitude is optional', () {
      final rows = routeRowsFrom(payload([
        [51.5, -0.12, null, 1000],
      ]));
      expect(rows.single['alt'], isNull);
    });
  });
}
