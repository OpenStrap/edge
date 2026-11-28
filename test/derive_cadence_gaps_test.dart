// Wear, day peak/trough and the sleep restlessness blocks on inputs that are
// not a gapless 1 Hz strap: a 5-minute wearable, a minute wearable, and a
// night with a hole in it.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';

const _profile = Profile(ageYears: 35, sex: 'm', weightKg: 75, heightCm: 178);

Substrate _sub(
  List<int> ts, {
  required String family,
  List<int>? hr,
  List<(double, double, double)>? accel,
}) {
  final n = ts.length;
  return Substrate(
    tsSec: ts,
    hr: hr ?? List<int>.filled(n, 60),
    rrTsMs: const [],
    rrMs: const [],
    ax: [for (var i = 0; i < n; i++) accel?[i].$1 ?? 0.0],
    ay: [for (var i = 0; i < n; i++) accel?[i].$2 ?? 0.0],
    az: [for (var i = 0; i < n; i++) accel?[i].$3 ?? 1.0],
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
    deviceFamily: family,
  );
}

Map<String, dynamic> _day(Substrate sub, int dayStart) {
  final bundle = <String, dynamic>{};
  DerivationEngine.applyDayActivity(
    bundle: bundle,
    scalars: <String, dynamic>{},
    daySub: sub,
    profile: _profile,
    sleepOnsetSec: 0,
    sleepOffsetSec: 0,
    dayStartSec: dayStart,
    dayCalendarEndSec: dayStart + 86400,
    dataNowSec: dayStart + 86400,
  );
  return bundle;
}

void main() {
  final dayStart = DateTime(2026, 8, 10).millisecondsSinceEpoch ~/ 1000;

  test('a ring worn all day at 5-min cadence is worn all day', () {
    final ts = [for (var t = dayStart; t < dayStart + 86400; t += 300) t];
    final wear = (_day(_sub(ts, family: 'oura'), dayStart)['wear'] as Map);
    expect(wear['coverage_pct'], 100);
    expect(wear['longest_off_min'], 0);
    expect((wear['segments'] as List).where((s) => s['on'] == true), hasLength(1));
  });

  test('a minute wearable keeps a 2-min effort as the day peak', () {
    final ts = [for (var t = dayStart; t < dayStart + 3600; t += 60) t];
    final hr = [for (var i = 0; i < ts.length; i++) i >= 20 && i < 22 ? 150 : 70];
    final stats = _day(_sub(ts, family: 'garmin', hr: hr), dayStart)['hr_stats'];
    expect(stats['max'], 150);
  });

  test('restlessness does not carry a still run across a recording hole', () {
    final ts = [
      for (var t = 0; t < 20 * 60; t++) dayStart + t,
      for (var t = 0; t < 20 * 60; t++) dayStart + 7200 + t,
    ];
    final r = DerivationEngine.restlessness(_sub(ts, family: 'gen4'));
    expect(r['longest_still_min'], 20);
  });

  test('restlessness map reads a still night as still', () {
    // A still wrist whose norm sits at 1.03 g (the gen4 offset).
    final ts = [for (var t = 0; t < 3600; t++) dayStart + t];
    final accel = [for (final _ in ts) (0.0, 0.0, 1.03)];
    final map = DerivationEngine.restlessnessMap(
        _sub(ts, family: 'gen4', accel: accel));
    expect(map, isNotEmpty);
    for (final b in map) {
      expect(b['density'], lessThan(0.05));
    }
  });
}
