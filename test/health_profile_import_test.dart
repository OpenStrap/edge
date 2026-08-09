// Reading body metrics from the platform health store.
//
// Two things carry the weight here. The merge policy differs per field on
// purpose — weight and height are adopted because they drift, while age and
// sex only fill a gap because they do not, and overwriting a value the user
// deliberately set from another app's record would be presumptuous. And the
// requested type set is built PER PLATFORM: sex and date of birth exist only
// on Apple, and asking Health Connect for them is the issue #184 shape again.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openstrap_edge/health/health_profile_import.dart';

/// Records the window each read asks for, so the platform-specific limits can
/// be asserted without a health store.
class _RecordingHealth implements Health {
  _RecordingHealth(this.windows);
  final List<(DateTime, DateTime)> windows;

  @override
  Future<void> configure() async {}

  @override
  Future<List<HealthDataPoint>> getHealthDataFromTypes({
    required List<HealthDataType> types,
    required DateTime startTime,
    required DateTime endTime,
    List<RecordingMethod> recordingMethodsToFilter = const [],
  }) async {
    windows.add((startTime, endTime));
    return const [];
  }

  // Only the two members the importer actually calls are implemented. Anything
  // else reaching this stub means `read()` changed shape, and that should fail
  // loudly rather than quietly returning null.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

HealthDataPoint _point(HealthDataType type, num value, DateTime at) =>
    HealthDataPoint(
      uuid: '$type-$value',
      value: NumericHealthValue(numericValue: value),
      type: type,
      unit: HealthDataUnit.NO_UNIT,
      dateFrom: at,
      dateTo: at,
      sourcePlatform: HealthPlatformType.appleHealth,
      sourceDeviceId: 'test',
      sourceId: 'test',
      sourceName: 'test',
    );

void main() {
  group('requested types', () {
    test('Apple asks for sex and date of birth', () {
      final t = HealthProfileImporter(isApple: true).types;
      expect(t, contains(HealthDataType.GENDER));
      expect(t, contains(HealthDataType.BIRTH_DATE));
    });

    test('Android asks for neither — Health Connect has no such record', () {
      // Requesting an unsupported type throws before the platform channel,
      // which is exactly how issue #184 lost every strength workout.
      final t = HealthProfileImporter(isApple: false).types;
      expect(t, isNot(contains(HealthDataType.GENDER)));
      expect(t, isNot(contains(HealthDataType.BIRTH_DATE)));
      expect(t, contains(HealthDataType.WEIGHT));
      expect(t, contains(HealthDataType.HEIGHT));
    });
  });

  group('the read window', () {
    test('Android asks only for what Health Connect will give', () {
      // Health Connect caps third-party reads at 30 days unless the user grants
      // READ_HEALTH_DATA_HISTORY, and the pinned health 11.1.1 has no API to
      // request it — so a ten-year window would return the same 30 days while
      // implying otherwise.
      final windows = <(DateTime, DateTime)>[];
      final importer = HealthProfileImporter(
        isApple: false,
        health: _RecordingHealth(windows),
      );
      // The read is wrapped in its own try/catch, so a stub that returns
      // nothing still exercises the window calculation.
      return importer.read(now: DateTime(2026, 8, 9)).then((_) {
        expect(windows, hasLength(1));
        expect(
          windows.single.$2.difference(windows.single.$1).inDays,
          30,
        );
      });
    });

    test('Apple asks for a year, not a decade', () {
      final windows = <(DateTime, DateTime)>[];
      final importer = HealthProfileImporter(
        isApple: true,
        health: _RecordingHealth(windows),
      );
      return importer.read(now: DateTime(2026, 8, 9)).then((_) {
        expect(windows, hasLength(1));
        // Wide enough to find a value someone records occasionally, narrow
        // enough that an ancient reading cannot overwrite a current profile.
        // Pinned exactly: a year-difference check passes for any date in 2025.
        expect(windows.single.$1, DateTime(2025, 8, 9));
      });
    });
  });

  group('reading a snapshot', () {
    final importer = HealthProfileImporter(isApple: true);
    final now = DateTime(2026, 8, 9);

    test('takes the newest value per type', () {
      final snap = importer.snapshotFrom([
        _point(HealthDataType.WEIGHT, 80, DateTime(2026, 1, 1)),
        _point(HealthDataType.WEIGHT, 74, DateTime(2026, 7, 1)),
        _point(HealthDataType.WEIGHT, 77, DateTime(2026, 4, 1)),
      ], now: now);
      expect(snap.weightKg, 74);
    });

    test('converts height from metres to centimetres', () {
      final snap = importer.snapshotFrom([
        _point(HealthDataType.HEIGHT, 1.78, DateTime(2026, 1, 1)),
      ], now: now);
      expect(snap.heightCm, closeTo(178, 0.001));
    });

    test('turns a date of birth into an age, respecting the birthday', () {
      final beforeBirthday = importer.snapshotFrom([
        _point(
          HealthDataType.BIRTH_DATE,
          DateTime(1990, 12, 25).millisecondsSinceEpoch,
          DateTime(2026, 1, 1),
        ),
      ], now: now);
      expect(beforeBirthday.ageYears, 35);

      final afterBirthday = importer.snapshotFrom([
        _point(
          HealthDataType.BIRTH_DATE,
          DateTime(1990, 1, 5).millisecondsSinceEpoch,
          DateTime(2026, 1, 1),
        ),
      ], now: now);
      expect(afterBirthday.ageYears, 36);
    });

    test('maps only the two sexes the formulas have constants for', () {
      HealthProfileSnapshot withGender(int raw) => importer.snapshotFrom([
        _point(HealthDataType.GENDER, raw, DateTime(2026, 1, 1)),
      ], now: now);

      expect(withGender(1).sex, 'f');
      expect(withGender(2).sex, 'm');
      // 0 = not set, 3 = other. Every formula downstream carries one constant
      // per sex and nothing sensible for a third, so no answer beats a guess.
      expect(withGender(0).sex, isNull);
      expect(withGender(3).sex, isNull);
    });

    test('rejects an implausible reading rather than adopting it', () {
      // These land straight in the calorie formula without review.
      final zero = importer.snapshotFrom([
        _point(HealthDataType.WEIGHT, 0, DateTime(2026, 1, 1)),
        _point(HealthDataType.HEIGHT, 0, DateTime(2026, 1, 1)),
      ], now: now);
      expect(zero.weightKg, isNull);
      expect(zero.heightCm, isNull);

      final absurd = importer.snapshotFrom([
        _point(HealthDataType.WEIGHT, 900, DateTime(2026, 1, 1)),
        _point(HealthDataType.HEIGHT, 9, DateTime(2026, 1, 1)),
      ], now: now);
      expect(absurd.weightKg, isNull);
      expect(absurd.heightCm, isNull);
    });

    test('an empty store is empty, not zeroes', () {
      const empty = HealthProfileSnapshot();
      expect(empty.isEmpty, isTrue);
      expect(empty.weightKg, isNull);
      expect(importer.snapshotFrom(const [], now: now).isEmpty, isTrue);
    });

    test('reports what it found', () {
      final snap = importer.snapshotFrom([
        _point(HealthDataType.WEIGHT, 74, DateTime(2026, 1, 1)),
        _point(HealthDataType.HEIGHT, 1.78, DateTime(2026, 1, 1)),
      ], now: now);
      expect(snap.found, ['weight', 'height']);
    });
  });

  group('mergeHealthProfile', () {
    const snap = HealthProfileSnapshot(
      weightKg: 74,
      heightCm: 178,
      ageYears: 36,
      sex: 'm',
    );

    test('fills an empty profile completely', () {
      final out = mergeHealthProfile(null, snap);
      expect(out['weight_kg'], 74);
      expect(out['height_cm'], 178);
      expect(out['age'], 36);
      expect(out['sex'], 'm');
    });

    test('weight and height are overwritten — that is the point', () {
      final out = mergeHealthProfile(
        {'weight_kg': 80.0, 'height_cm': 175.0},
        snap,
      );
      expect(out['weight_kg'], 74);
      expect(out['height_cm'], 178);
    });

    test('age and sex only fill a gap', () {
      // Neither drifts, so a value already there is a deliberate choice and
      // another app's record does not get to override it.
      final out = mergeHealthProfile({'age': 40, 'sex': 'f'}, snap);
      expect(out['age'], 40);
      expect(out['sex'], 'f');
    });

    test('an absent field never clears an existing one', () {
      final out = mergeHealthProfile(
        {'weight_kg': 80.0, 'age': 40},
        const HealthProfileSnapshot(heightCm: 178),
      );
      expect(out['weight_kg'], 80.0);
      expect(out['age'], 40);
      expect(out['height_cm'], 178);
    });

    test('unrelated profile fields survive', () {
      final out = mergeHealthProfile({'name': 'Sam'}, snap);
      expect(out['name'], 'Sam');
    });

    test('does not mutate the map it was given', () {
      final before = <String, dynamic>{'weight_kg': 80.0};
      mergeHealthProfile(before, snap);
      expect(before['weight_kg'], 80.0);
    });
  });

  group('healthProfileChanges', () {
    test('names only what actually changes', () {
      final changes = healthProfileChanges(
        {'weight_kg': 80.0, 'height_cm': 178.0, 'age': 40, 'sex': 'f'},
        const HealthProfileSnapshot(
          weightKg: 74,
          heightCm: 178,
          ageYears: 36,
          sex: 'm',
        ),
      );
      // Height matches, and age/sex are already set so they are not touched.
      expect(changes, ['weight']);
    });

    test('is empty when the profile already matches', () {
      // Otherwise the UI would report an import that did nothing.
      expect(
        healthProfileChanges(
          {'weight_kg': 74.0},
          const HealthProfileSnapshot(weightKg: 74),
        ),
        isEmpty,
      );
    });
  });


  test('Android declares the read permissions the import needs', () {
    // Health Connect silently returns NOTHING for an undeclared permission
    // rather than failing, so a missing line here is indistinguishable from an
    // empty health store — the import would just never work on Android and
    // nobody would know why.
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    for (final perm in ['READ_WEIGHT', 'READ_HEIGHT']) {
      expect(
        manifest,
        contains('android.permission.health.$perm'),
        reason: '$perm is requested by HealthProfileImporter',
      );
    }
    // And no write counterparts: this app reads body metrics, it does not
    // write them back.
    for (final perm in ['WRITE_WEIGHT', 'WRITE_HEIGHT']) {
      expect(manifest, isNot(contains('android.permission.health.$perm')));
    }
  });
}
