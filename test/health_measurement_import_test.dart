import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openstrap_edge/health/health_measurement_import.dart';

HealthDataPoint _p(
  HealthDataType type,
  num value, {
  String uuid = 'u1',
  String source = 'Omron Connect',
}) =>
    HealthDataPoint(
      uuid: uuid,
      value: NumericHealthValue(numericValue: value),
      type: type,
      unit: HealthDataUnit.MILLIMETER_OF_MERCURY,
      dateFrom: DateTime(2026, 8, 1, 9),
      dateTo: DateTime(2026, 8, 1, 9),
      sourceId: 'src',
      sourcePlatform: HealthPlatformType.appleHealth,
      sourceDeviceId: 'dev',
      sourceName: source,
    );

void main() {
  test('a cuff reading keeps the cuff\'s name', () {
    final rows = rowsFrom([_p(HealthDataType.BLOOD_PRESSURE_SYSTOLIC, 128)]);
    expect(rows.single['kind'], kKindSystolic);
    expect(rows.single['value'], 128.0);
    // The source is the whole point: a reading we cannot attribute is a
    // reading we cannot honestly show.
    expect(rows.single['source'], 'Omron Connect');
  });

  test('an out-of-range reading is DROPPED, never clamped', () {
    // 400 mmHg is a cuff error, not a blood pressure. Clamping it to 300 would
    // put a fabricated measurement in a table of other people's measurements.
    final rows = rowsFrom([
      _p(HealthDataType.BLOOD_PRESSURE_SYSTOLIC, 400, uuid: 'bad'),
      _p(HealthDataType.BLOOD_PRESSURE_SYSTOLIC, 118, uuid: 'good'),
    ]);
    expect(rows.map((r) => r['uuid']), ['good']);
  });

  test('a record with no uuid is skipped rather than given a synthetic key',
      () {
    final rows = rowsFrom([
      _p(HealthDataType.BLOOD_GLUCOSE, 95, uuid: ''),
    ]);
    expect(rows, isEmpty);
  });

  test('the same uuid twice lands once', () {
    final rows = rowsFrom([
      _p(HealthDataType.BLOOD_GLUCOSE, 95, uuid: 'g'),
      _p(HealthDataType.BLOOD_GLUCOSE, 95, uuid: 'g'),
    ]);
    expect(rows.length, 1);
  });

  test('one blood-pressure record id keeps both halves', () {
    // Health Connect: systolic and diastolic come from one record, one id.
    final rows = rowsFrom([
      _p(HealthDataType.BLOOD_PRESSURE_SYSTOLIC, 120, uuid: 'bp'),
      _p(HealthDataType.BLOOD_PRESSURE_DIASTOLIC, 80, uuid: 'bp'),
    ]);
    expect(rows.map((r) => r['kind']), [kKindSystolic, kKindDiastolic]);
    expect(rows.map((r) => r['uuid']).toSet(), hasLength(2),
        reason: 'the table is keyed on uuid; a shared key overwrites a half');
    expect(rows.first['uuid'], 'bp',
        reason: 'existing systolic rows keep their key');
  });

  test('a type we do not import is ignored, not mis-filed', () {
    final rows = rowsFrom([_p(HealthDataType.HEART_RATE, 60, uuid: 'h')]);
    expect(rows, isEmpty);
  });

  test('an unnamed source still gets a name, never an empty one', () {
    final rows = rowsFrom([
      _p(HealthDataType.BODY_TEMPERATURE, 36.8, uuid: 't', source: '  '),
    ]);
    expect(rows.single['source'], 'Unknown app');
  });
}
