// The nightly skin-temp sample gate is an hour of the family's readings, not
// sixty samples: sixty is a minute of a 1 Hz band but five hours of a ring
// that stores one value every five minutes. A short ring night still gets a
// skin temperature; a band still needs its sixty. The ring's number rests on
// a provisional settle band, and the day bundle says so.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';

void main() {
  Map<String, dynamic> bundle(String family, int samples, int value,
      [List<double>? history]) {
    const t0 = 1780000000;
    const n = 6 * 3600;
    return deriveDayBundle(
      DayBundleInput(
        date: '2026-06-01',
        dayTsSec: [for (var i = 0; i < n; i++) t0 + i],
        dayHr: List<int>.filled(n, 60),
        sleepTsSec: const [],
        sleepHr: const [],
        sleepRrTsMs: const [],
        sleepRrMs: const [],
        sleepSkinTemp: List<int>.filled(samples, value),
        sleepJson: const {},
        hypnoStages: const [],
        sleepOnsetSec: 0,
        sleepOffsetSec: 0,
        profile: const {},
        skinTempAdcHistory:
            history ?? [value - 10.0, value * 1.0, value + 10.0],
        deviceFamily: family,
      ).toJson(),
    );
  }

  Map scalars(Map b) => b['scalars'] as Map;

  test('a 3 h ring night (36 five-minute records) gets a skin temperature, '
      'marked provisional at half confidence', () {
    for (final fam in ['ultrahuman', 'colmi']) {
      final b = bundle(fam, 36, 3530);
      expect(scalars(b)['skin_temp_adc'], 3530, reason: fam);
      expect(scalars(b)['skin_temp_settled_frac'], 1.0, reason: fam);
      final env = (b['wellness'] as Map)['skin_temp'] as Map;
      expect(env['value'], isNot('—'), reason: fam);
      expect(env['provisional'], isTrue, reason: fam);
      expect(env['confidence'], 0.25, reason: fam);
    }
  });

  test('a ring night under an hour of records still has none', () {
    expect(scalars(bundle('ultrahuman', 11, 3530))['skin_temp_adc'], isNull);
    expect(scalars(bundle('ultrahuman', 12, 3530))['skin_temp_adc'], 3530);
  });

  test('a band still needs sixty samples, and is never provisional', () {
    expect(scalars(bundle('gen4', 36, 805))['skin_temp_adc'], isNull);
    expect(scalars(bundle('gen4', 59, 805))['skin_temp_adc'], isNull);
    final b = bundle('gen4', 60, 805);
    expect(scalars(b)['skin_temp_adc'], 805);
    final env = (b['wellness'] as Map)['skin_temp'] as Map;
    expect(env.containsKey('provisional'), isFalse);
    expect(env['confidence'], 0.5);
  });

  test('a ring night 1 °C warm against its own nights reads as a deviation, '
      'one at its own level as none', () {
    const base = [3510.0, 3520.0, 3530.0, 3540.0, 3550.0];
    num? z(int value) =>
        scalars(bundle('ultrahuman', 36, value, base))['skin_temp_z'] as num?;
    expect(z(3530), closeTo(0, 0.01));
    expect(z(3630)!, greaterThan(2));
    expect(z(3430)!, lessThan(-2));
  });
}
