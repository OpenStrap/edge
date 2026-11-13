// A WHOOP export names its activities in WHOOP's own words ("Weightlifting",
// "Mountain Biking"). Stored as-is, those rows reached Apple Health / Health
// Connect as OTHER and found no catalogue entry in the workout list.

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:openstrap_edge/import/whoop_import.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';

void main() {
  test('WHOOP names are stored as catalogue keys', () {
    const cases = {
      'Weightlifting': 'weight_training',
      'Strength Trainer': 'weight_training',
      'Functional Fitness': 'functional',
      'Mountain Biking': 'mountain_biking',
      'Spin': 'indoor_bike',
      'Hiking/Rucking': 'hiking',
      'Rock Climbing': 'climbing',
      ' Running ': 'running',
    };
    cases.forEach((whoop, key) {
      final stored = WhoopImporter.activityTypeKey(whoop);
      expect(stored, key, reason: whoop);
      expect(activityByName(stored)?.typeKey, key, reason: whoop);
    });
    expect(WhoopImporter.activityTypeKey('  '), 'other');
  });

  test('imported strength and cycling reach the health store typed', () {
    for (final ios in [true, false]) {
      final strength = ios
          ? HealthWorkoutActivityType.TRADITIONAL_STRENGTH_TRAINING
          : HealthWorkoutActivityType.STRENGTH_TRAINING;
      expect(
          healthActivityForType(
              WhoopImporter.activityTypeKey('Weightlifting'), ios: ios),
          strength);
      expect(
          healthActivityForType(
              WhoopImporter.activityTypeKey('Mountain Biking'), ios: ios),
          HealthWorkoutActivityType.BIKING);
    }
  });

  test('an imported pickleball session is a catalogue sport', () {
    final key = WhoopImporter.activityTypeKey('Pickleball');
    expect(activityByName(key)?.name, 'Pickleball');
    expect(healthActivityForType(key, ios: true),
        HealthWorkoutActivityType.PICKLEBALL);
    // Health Connect has no pickleball type.
    expect(healthActivityForType(key, ios: false),
        HealthWorkoutActivityType.TENNIS);
  });

  test('rows stored with the raw WHOOP name still map', () {
    // The importer never rewrites a session it already holds, so rows from
    // an earlier import keep the old spelling.
    for (final ios in [true, false]) {
      final strength = ios
          ? HealthWorkoutActivityType.TRADITIONAL_STRENGTH_TRAINING
          : HealthWorkoutActivityType.STRENGTH_TRAINING;
      expect(healthActivityForType('weightlifting', ios: ios), strength);
      expect(healthActivityForType('strength trainer', ios: ios), strength);
      expect(healthActivityForType('mountain biking', ios: ios),
          HealthWorkoutActivityType.BIKING);
      expect(healthActivityForType('spin', ios: ios),
          HealthWorkoutActivityType.BIKING);
      expect(healthActivityForType('hiking/rucking', ios: ios),
          HealthWorkoutActivityType.HIKING);
      expect(healthActivityForType('rock climbing', ios: ios),
          HealthWorkoutActivityType.ROCK_CLIMBING);
    }
  });
}
