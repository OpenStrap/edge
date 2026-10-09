// Strain's resting-HR reference, and the HRV timeline's clock.
//
// Both were confident-wrong-number bugs on the same seam, fixed in v68:
//
//   • The offloaded second half recomputed the headline strain from
//     `scalars.rhr`, which the pure pipeline is ALLOWED to fall back to daytime
//     HR for (that fallback exists for the general resting-HR card). On a day
//     with no detected sleep that reference ran ~20 bpm high, which shrinks the
//     HR reserve and manufactures strain out of sitting still — and it was then
//     written over `scalars.strain` even on days where the pure pipeline had
//     already abstained. It now reads `scalars.rhr_nocturnal`, and abstains.
//
//   • `series.hrv_timeline` stored `t` as seconds since the first NN beat
//     (`correctRr` re-bases its clock to 0) on a view whose contract says epoch
//     seconds, and emitted its first point after 10 beats (~8 s) on a line
//     documented as rolling 5-min windows.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';

const int _t0 = 1786700000; // a fixed epoch second, local-zone independent

/// A day substrate: 6 h of wear, one hour of it at a workout heart rate.
Substrate _daySub() {
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  for (var i = 0; i < 6 * 3600; i++) {
    ts.add(_t0 + i);
    hr.add(i >= 3600 && i < 7200 ? 130 : 62);
    ax.add(0.01 * ((i % 7) - 3));
    ay.add(0.01 * ((i % 5) - 2));
    az.add(1.0);
  }
  final n = ts.length;
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: const [],
    rrMs: const [],
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
    // Stamped: with no family there is no HR ceiling, so TRIMP has nothing to
    // band against and strain is absent for that reason instead (hr_max.dart).
    deviceFamily: 'gen4',
  );
}

Map<String, dynamic> _runDayActivity({
  required double? restingHr,
  required Profile profile,
  Map<String, dynamic>? seedScalars,
}) {
  final scalars = seedScalars ?? <String, dynamic>{};
  final sub = _daySub();
  DerivationEngine.applyDayActivity(
    bundle: <String, dynamic>{},
    scalars: scalars,
    daySub: sub,
    profile: profile,
    // No sleep on this day — the whole span is waking.
    sleepOnsetSec: 0,
    sleepOffsetSec: 0,
    // Wear/coverage is not what this test measures; the window is just the
    // substrate's own span with the data edge past its end, so `_wearBlock`
    // has a well-formed day to divide by. See wear_coverage_test.dart.
    dayStartSec: sub.tsSec.first,
    dayCalendarEndSec: sub.tsSec.last + 1,
    dataNowSec: sub.tsSec.last + 1,
    restingHr: restingHr,
    // A settled week of prior quiet levels, so the resting-HR gate is the only
    // thing deciding presence here (strain_quiet_level_test covers the level).
    quietHrrHistory: List<double>.filled(7, 0.20),
  );
  return scalars;
}

void main() {
  const profile = Profile(ageYears: 35, sex: 'm', weightKg: 75, heightCm: 178);

  group('strain needs a resting HR that is actually resting', () {
    test('a nocturnal resting HR produces a strain', () {
      final scalars = _runDayActivity(restingHr: 55, profile: profile);
      expect(scalars['strain'], isNotNull);
      expect(scalars['strain'] as num, greaterThan(0));
    });

    test('no nocturnal and no user-entered resting HR → strain is ABSENT', () {
      // This is the day the bug shipped a number for: no sleep detected, so the
      // only "resting" HR available was the daytime fallback.
      final scalars = _runDayActivity(restingHr: null, profile: profile);
      expect(scalars.containsKey('strain'), isTrue,
          reason: 'the key is written so a stale value cannot survive');
      expect(scalars['strain'], isNull);
    });

    test('a user-entered resting HR is still enough', () {
      final scalars = _runDayActivity(
        restingHr: null,
        profile: const Profile(
            ageYears: 35,
            sex: 'm',
            weightKg: 75,
            heightCm: 178,
            restingHrManual: 58),
      );
      expect(scalars['strain'], isNotNull);
    });

    test('an abstaining day ERASES a previously written strain', () {
      // 5.9988879878856 is a real stored value from 2026-08-09, computed off a
      // daytime "resting" HR of 84.36 bpm on a day whose own clinical envelope
      // said "—". `if (strain != null)` used to leave exactly this standing.
      final scalars = _runDayActivity(
        restingHr: null,
        profile: profile,
        seedScalars: <String, dynamic>{'strain': 5.9988879878856},
      );
      expect(scalars['strain'], isNull);
    });
  });

  group('hrv_timeline is on the epoch clock', () {
    // 30 minutes of beats averaging exactly 1000 ms (so the beat clock and the
    // declared window are the same 1800 s), mildly variable so RMSSD > 0.
    final rrMs = <double>[];
    final rrTsMs = <double>[];
    var t = _t0 * 1000.0;
    for (var i = 0; i < 1800; i++) {
      final rr = 1000.0 + ((i % 5) - 2) * 12.0;
      t += rr;
      rrMs.add(rr);
      rrTsMs.add(t);
    }
    final onset = _t0;
    final offset = _t0 + 1800;
    final tsSec = <int>[for (var i = 0; i < 1800; i++) _t0 + i];
    final hr = <int>[for (var i = 0; i < 1800; i++) 58];

    final bundle = deriveDayBundle(DayBundleInput(
      date: '2026-08-15',
      dayTsSec: tsSec,
      dayHr: hr,
      sleepTsSec: tsSec,
      sleepHr: hr,
      sleepRrTsMs: rrTsMs,
      sleepRrMs: rrMs,
      sleepSkinTemp: List<int>.filled(1800, 0),
      sleepJson: {
        'tst_sec': 1800,
        'in_bed_sec': 1800,
        'window': {'onset_ms': onset * 1000, 'offset_ms': offset * 1000},
      },
      hypnoStages: List<String>.filled(1800, 'nrem'),
      sleepOnsetSec: onset,
      sleepOffsetSec: offset,
      profile: const {'age': 35, 'sex': 'm', 'weight_kg': 75, 'height_cm': 178},
      deviceFamily: 'gen4',
    ).toJson());

    final timeline = ((bundle['series'] as Map)['hrv_timeline'] as List)
        .cast<Map>();

    test('t is epoch seconds inside the night, not seconds-since-beat-one', () {
      expect(timeline, isNotEmpty);
      for (final p in timeline) {
        final ts = (p['t'] as num).toInt();
        // The old code wrote 7, 8, 9… here. Anything on the real clock is
        // inside the window (±1 beat of slack at each end).
        expect(ts, greaterThanOrEqualTo(onset - 2));
        expect(ts, lessThanOrEqualTo(offset + 2));
      }
    });

    test('the first point has a full 5-minute window behind it', () {
      // It used to be an RMSSD over 10 beats (~8 s) drawn on the same line as
      // the genuine 5-min windows, with nothing marking it as the noisier
      // sample it is.
      expect((timeline.first['t'] as num).toInt() - onset,
          greaterThanOrEqualTo(300));
    });
  });
}
