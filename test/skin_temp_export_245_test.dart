import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:openstrap_edge/health/health_measurement_import.dart';

HealthDataPoint _temp(double c, {required String sourceId}) => HealthDataPoint(
      uuid: 't-$sourceId',
      value: NumericHealthValue(numericValue: c),
      type: HealthDataType.BODY_TEMPERATURE,
      unit: HealthDataUnit.DEGREE_CELSIUS,
      dateFrom: DateTime(2026, 8, 1, 3),
      dateTo: DateTime(2026, 8, 1, 3),
      sourceId: sourceId,
      sourcePlatform: HealthPlatformType.googleHealthConnect,
      sourceDeviceId: 'dev',
      sourceName: sourceId,
    );

void main() {
  group('healthSkinTempCelsius', () {
    test('WHOOP 5 centi-degrees become °C', () {
      expect(healthSkinTempCelsius(3412.345, 'gen5'), 34.12);
    });

    test('a WHOOP 4 raw count is never a temperature', () {
      expect(healthSkinTempCelsius(31000, 'gen4'), isNull);
      // Even one that happens to land in range after /100.
      expect(healthSkinTempCelsius(3400, 'gen4'), isNull);
    });

    test('unknown family, absent mean, implausible value: nothing', () {
      expect(healthSkinTempCelsius(3400, null), isNull);
      expect(healthSkinTempCelsius(null, 'gen5'), isNull);
      expect(healthSkinTempCelsius(1500, 'gen5'), isNull);
      expect(healthSkinTempCelsius(4500, 'gen5'), isNull);
    });
  });

  test('the importer never reads our own temperature back as a thermometer',
      () {
    final rows = rowsFrom([
      _temp(34.1, sourceId: 'wtf.openstrap.openstrap_edge'),
      _temp(36.8, sourceId: 'com.thermometer'),
    ], ownId: 'wtf.openstrap.openstrap_edge');
    expect(rows.map((r) => r['value']), [36.8]);
  });

  test('Health Connect write permission is declared', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest,
        contains('android.permission.health.WRITE_BODY_TEMPERATURE'));
  });
}
