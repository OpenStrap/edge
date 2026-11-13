// A stored age the profile forms would now refuse (a birth year typed into the
// age box, or 0) gives no HRmax estimate, so strain, calories and the ceiling
// are absent. The reason on those figures has to name the age: it used to fall
// through to `unknown_device_family`, which the screens render as "these
// recordings are not stamped with which strap made them" on a correctly
// stamped WHOOP day, and nothing pointed at the profile.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';

const int _t0 = 1786699980;

/// 300 waking minutes at 62 bpm then 60 at 130, one sample per second.
Substrate _sub() {
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  var i = 0;
  for (final (mins, bpm) in const [(300, 62), (60, 130)]) {
    for (var s = 0; s < mins * 60; s++, i++) {
      ts.add(_t0 + i);
      hr.add(bpm);
      ax.add(0.01 * ((i % 7) - 3));
      ay.add(0.01 * ((i % 5) - 2));
      az.add(1.0);
    }
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
    deviceFamily: 'gen4',
  );
}

Map<String, dynamic> _engineNotes(int age) {
  final sub = _sub();
  final scalars = <String, dynamic>{};
  final bundle = <String, dynamic>{};
  DerivationEngine.applyDayActivity(
    bundle: bundle,
    scalars: scalars,
    daySub: sub,
    profile:
        Profile(ageYears: age, sex: 'm', weightKg: 75, heightCm: 178),
    sleepOnsetSec: 0,
    sleepOffsetSec: 0,
    dayStartSec: sub.tsSec.first,
    dayCalendarEndSec: sub.tsSec.last + 1,
    dataNowSec: sub.tsSec.last + 1,
    restingHr: 55,
    quietHrrHistory: List.filled(7, 0.20),
  );
  expect(scalars['strain'], isNull);
  return (bundle['absent_notes'] as Map).cast<String, dynamic>();
}

Map<String, dynamic> _pipelineNotes(int age) {
  final sub = _sub();
  final bundle = deriveDayBundle(DayBundleInput(
    date: '2026-08-15',
    dayTsSec: sub.tsSec,
    dayHr: sub.hr,
    sleepTsSec: const [],
    sleepHr: const [],
    sleepRrTsMs: const [],
    sleepRrMs: const [],
    sleepSkinTemp: const [],
    sleepJson: const {},
    hypnoStages: const [],
    sleepOnsetSec: 0,
    sleepOffsetSec: 0,
    profile: {
      'age': age,
      'sex': 'm',
      'weight_kg': 75,
      'height_cm': 178,
      'resting_hr': 55,
    },
    deviceFamily: 'gen4',
    quietHrrHistory: List.filled(7, 0.20),
  ).toJson());
  return (bundle['absent_notes'] as Map).cast<String, dynamic>();
}

void main() {
  for (final age in const [1990, 0]) {
    group('stored age $age on a stamped gen4 day', () {
      test('the engine half names the age, not the strap', () {
        final notes = _engineNotes(age);
        expect(notes['strain'], 'need_input:name=age');
        expect(notes['calories'], 'need_input:name=age');
        for (final n in notes.values) {
          expect(n as String, isNot(startsWith('unknown_device_family')));
        }
      });

      test('the pure pipeline names the age, not the strap', () {
        final notes = _pipelineNotes(age);
        expect(notes['strain'], 'need_input:name=age');
        expect(notes['max_hr_used'], 'need_input:name=age');
        expect(notes['calories'], 'need_input:name=age');
        for (final n in notes.values) {
          expect(n as String, isNot(startsWith('unknown_device_family')));
        }
      });
    });
  }
}
