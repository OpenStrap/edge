// A calendar day's own sleep is the night that ENDED that morning. Tonight's
// sleep, begun before midnight, belongs to tomorrow, and used to be counted
// here as waking time: every minute of it paid strain's waking allowance, so
// strain fell while the user slept.
//
// Also the stored-window reader the midsleep prior uses: it only accepted a
// `value` envelope that no writer produces.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';

const int _t0 = 1786700000;

/// 9 h of wear: an hour of exercise, then quiet, then asleep from 6 h on.
Substrate _daySub() {
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  for (var i = 0; i < 9 * 3600; i++) {
    ts.add(_t0 + i);
    hr.add(i >= 3600 && i < 7200 ? 130 : (i >= 6 * 3600 ? 52 : 62));
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
    deviceFamily: 'gen4',
  );
}

double _strain({int tonight = 0}) {
  final scalars = <String, dynamic>{};
  final sub = _daySub();
  DerivationEngine.applyDayActivity(
    bundle: <String, dynamic>{},
    scalars: scalars,
    daySub: sub,
    profile:
        const Profile(ageYears: 35, sex: 'm', weightKg: 75, heightCm: 178),
    sleepOnsetSec: 0,
    sleepOffsetSec: 0,
    dayStartSec: sub.tsSec.first,
    dayCalendarEndSec: sub.tsSec.last + 1,
    dataNowSec: sub.tsSec.last + 1,
    restingHr: 50,
    tonightSleepOnsetSec: tonight,
  );
  return (scalars['strain'] as num).toDouble();
}

void main() {
  test('falling asleep before midnight does not lower the day\'s strain', () {
    final awake = _strain();
    final asleep = _strain(tonight: _t0 + 6 * 3600);
    // Three hours asleep no longer pay the waking allowance.
    expect(asleep, greaterThan(awake));
  });

  group('tonightSleep', () {
    const dayStart = 1000000, dayEnd = dayStart + 86400;
    test('a night begun this evening is tonight\'s', () {
      final next = (startSec: dayEnd - 3600, endSec: dayEnd + 6 * 3600);
      expect(
        DerivationEngine.tonightSleep(next,
            dayStartSec: dayStart, dayEndSec: dayEnd, sleepOffsetSec: 0),
        next,
      );
    });
    test('a night begun after midnight is not', () {
      expect(
        DerivationEngine.tonightSleep(
            (startSec: dayEnd + 600, endSec: dayEnd + 7 * 3600),
            dayStartSec: dayStart,
            dayEndSec: dayEnd,
            sleepOffsetSec: 0),
        isNull,
      );
    });
  });

  group('storedWindowSpan', () {
    test('reads the bare SleepWindow.toJson() every writer stores', () {
      final raw = jsonEncode({
        'onset_idx': 0,
        'offset_idx': 100,
        'onset_ms': 1786700000000,
        'offset_ms': 1786728800000,
        'spt_sec': 28800,
      });
      expect(DerivationEngine.storedWindowSpan(raw),
          (startSec: 1786700000, endSec: 1786728800));
    });
    test('a night with no sleep holds no window', () {
      expect(DerivationEngine.storedWindowSpan(jsonEncode({'value': '—'})),
          isNull);
      expect(DerivationEngine.storedWindowSpan('{}'), isNull);
    });
  });
}
