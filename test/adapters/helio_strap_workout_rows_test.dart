import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/helio_strap.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

void main() {
  Map<String, num> keys(Huami2021Workout w) => {
        for (final o in helioWorkoutObservations(w)) o.vendorKey!: o.value,
      };

  test('absent workout fields are dropped, not published as 0', () {
    final rows = keys(const Huami2021Workout(
        startMs: 1780000000000, durationSec: 0, sportType: 1,
        calories: 0, avgHr: 0, maxHr: 0, minHr: 0));
    expect(rows, {'workout_sport_type': 1});
  });

  test('reported workout fields all come through', () {
    final rows = keys(const Huami2021Workout(
        startMs: 1780000000000, durationSec: 1800, sportType: 1,
        calories: 250, avgHr: 140, maxHr: 170, minHr: 95));
    expect(rows, {
      'workout_sport_type': 1,
      'workout_duration_sec': 1800,
      'workout_calories': 250,
      'workout_avg_hr': 140,
      'workout_max_hr': 170,
      'workout_min_hr': 95,
    });
  });
}
