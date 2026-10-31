// SLEEP COACH ACROSS A TIME-ZONE CHANGE.
//
// A user flew 7 h west and, at 08:33 local, the Sleep tab read "Target bedtime
// 4:00 PM / Target wake 1:31 AM". The cross-day rollup took the typical wake
// as the median of every past wake INSTANT converted with the phone's CURRENT
// zone, so 08:31 wakes recorded at UTC+2 re-read as 01:31 and the bedtime
// backed off them landed mid-afternoon.
//
// The fix keeps the targets a LOCAL CLOCK schedule: each night is read on the
// clock it was lived on (recovered from the per-day `sleep_onset_sec` scalar,
// which froze the onset's local clock at derive time) and that schedule is
// applied in whatever zone the phone is in now.
//
// These tests build the rows by hand with the history's zone written out
// explicitly (UTC+2, or Europe's CEST→CET), so they assert the same answer in
// ANY runner zone. Under the old code they fail in every zone except the one
// the history was recorded in. Worth running under a few zones, e.g.
//   TZ=Etc/GMT+5 flutter test test/sleep_coach_timezone_test.dart   (UTC−5)
//   TZ=America/New_York flutter test test/sleep_coach_timezone_test.dart
//   TZ=Europe/Amsterdam flutter test test/sleep_coach_timezone_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart'
    show kSleepClockAnchorSec, sleepClockOffsetSec;

/// Epoch seconds for wall-clock [h]:[m] on [y]-[mo]-[d] in a zone at
/// [offsetMin] from UTC.
int _at(int y, int mo, int d, int h, int m, int offsetMin) =>
    DateTime.utc(y, mo, d, h, m).millisecondsSinceEpoch ~/ 1000 -
    offsetMin * 60;

/// What `sleepClockOffsetSec` would have written for [localH]:[localM] —
/// signed seconds either side of 04:00 — had the phone been in that zone.
double _clockAsRecorded(int localH, int localM) {
  var off = localH * 3600 + localM * 60 - kSleepClockAnchorSec;
  if (off > 43200) off -= 86400;
  if (off <= -43200) off += 86400;
  return off.toDouble();
}

String _label(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// One stored day as `day_result` holds it: the sleep window as absolute
/// instants, plus the onset's frozen local clock in `scalars`.
({Map<String, dynamic> row, Map<String, dynamic> payload}) _stored({
  required String day,
  required int onsetSec,
  required int wakeSec,
  required double? onsetClockSec,
}) =>
    (
      row: {'day_id': day, 'finalized': 1},
      payload: {
        'scalars': {
          'efficiency': 95.0,
          'sleep_onset_sec': ?onsetClockSec,
        },
        'sleep': {
          'window': {
            'value': {'onset_ms': onsetSec * 1000, 'offset_ms': wakeSec * 1000},
          },
          'accounting': {
            'value': {'tst_sec': (wakeSec - onsetSec) * 0.95},
          },
        },
      },
    );

/// Three weeks of nights lived at UTC+2: in bed 23:30, up 07:45 (one night
/// falls asleep after midnight, 00:20, so the day boundary is crossed).
List<({Map<String, dynamic> row, Map<String, dynamic> payload})> _europe() {
  const tz = 120;
  final out = <({Map<String, dynamic> row, Map<String, dynamic> payload})>[];
  for (var i = 0; i < 21; i++) {
    // The night of Sep i+1 → the morning of Sep i+2 (labelled by the morning).
    final late = i == 10;
    final onset = late
        ? _at(2026, 9, i + 2, 0, 20, tz)
        : _at(2026, 9, i + 1, 23, 30, tz);
    final wake = _at(2026, 9, i + 2, 7, 45, tz);
    out.add(_stored(
      day: _label(DateTime(2026, 9, i + 2)),
      onsetSec: onset,
      wakeSec: wake,
      onsetClockSec: late ? _clockAsRecorded(0, 20) : _clockAsRecorded(23, 30),
    ));
  }
  return out;
}

List<Map<String, dynamic>> _records(
  List<({Map<String, dynamic> row, Map<String, dynamic> payload})> stored,
) => [
      for (final s in stored)
        DerivationEngine.crossDayInputRecord(s.row, s.payload,
            today: '2026-12-31', imported: const {})!,
    ];

Map<String, dynamic> _coach(List<Map<String, dynamic>> days) =>
    (buildCrossDayBundle(days, const {})['sleep_coach'] as Map)
        .cast<String, dynamic>();

double _min(Map<String, dynamic> coach, String key, String field) =>
    (((coach[key] as Map)['value'] as Map)[field] as num).toDouble();

/// Circular distance in minutes on a 24 h clock.
double _clockDist(double a, double b) {
  final d = (a - b).abs() % 1440;
  return d > 720 ? 1440 - d : d;
}

void main() {
  group('history recorded at UTC+2, phone now elsewhere', () {
    test('targets read ~23:30 / 07:45 local, not 16:00 / 01:31', () {
      final days = _records(_europe());
      final coach = _coach(days);
      final wake = _min(coach, 'wake', 'wake_min_of_day');
      final bed = _min(coach, 'bedtime', 'bedtime_min_of_day');
      final needSec = _min(coach, 'need', 'need_sec');

      // Target wake = the bedtime plus the in-bed time it was backed off, so it
      // lands back on the typical wake: 07:45 on the clock the user lives by.
      expect(_clockDist(wake, 7 * 60 + 45), lessThan(1.0),
          reason: 'target wake $wake min');
      // Bedtime is that wake minus need ÷ efficiency, on the same clock.
      final expectedBed = (7 * 60 + 45 - needSec / 0.95 / 60) % 1440;
      expect(_clockDist(bed, expectedBed), lessThan(1.0));
      // …which for this history is the late-evening bedtime it kept, not a
      // mid-afternoon one.
      expect(_clockDist(bed, 23 * 60 + 30), lessThan(45.0),
          reason: 'target bedtime $bed min');
      expect(_clockDist(bed, 16 * 60), greaterThan(300.0));
      expect(_clockDist(wake, 60 + 31), greaterThan(300.0));
    });

    test('the record carries the shift only when the zone actually differs',
        () {
      final days = _records(_europe());
      final onset = days.first['onset_sec'] as int;
      final hereOffsetMin =
          DateTime.fromMillisecondsSinceEpoch(onset * 1000).timeZoneOffset
              .inMinutes;
      if (hereOffsetMin == 120) {
        // Runner is in the history's own zone: nothing written, old path.
        expect(days.first.containsKey('clock_shift_sec'), isFalse);
      } else {
        expect(days.first['clock_shift_sec'],
            ((120 - hereOffsetMin) * 60) % 86400);
      }
    });

    test('a few nights already lived in the new zone do not move the target',
        () {
      // The first nights after landing are derived in the phone's new zone and
      // carry no shift; read on their own clock they are the same schedule.
      final stored = _europe();
      for (var i = 0; i < 3; i++) {
        final dLocal = DateTime(2026, 9, 23 + i, 23, 30);
        final onset = dLocal.millisecondsSinceEpoch ~/ 1000;
        final wake =
            DateTime(2026, 9, 24 + i, 7, 45).millisecondsSinceEpoch ~/ 1000;
        stored.add(_stored(
          day: _label(DateTime(2026, 9, 24 + i)),
          onsetSec: onset,
          wakeSec: wake,
          onsetClockSec: sleepClockOffsetSec(onset),
        ));
      }
      final coach = _coach(_records(stored));
      expect(_clockDist(_min(coach, 'wake', 'wake_min_of_day'), 7 * 60 + 45),
          lessThan(1.0));
    });
  });

  test('history straddling a DST change keeps its local schedule', () {
    // Europe leaves CEST (UTC+2) for CET (UTC+1) on 25 Oct 2026. The user went
    // to bed at 23:30 and woke at 07:45 on BOTH sides; the instants moved by an
    // hour, the clock did not, and neither should the target.
    final stored = <({Map<String, dynamic> row, Map<String, dynamic> payload})>[];
    for (var i = 0; i < 20; i++) {
      final morning = DateTime(2026, 10, 15 + i);
      final tz = morning.isBefore(DateTime(2026, 10, 25, 12)) ? 120 : 60;
      final night = DateTime(2026, 10, 14 + i);
      stored.add(_stored(
        day: _label(morning),
        onsetSec: _at(night.year, night.month, night.day, 23, 30, tz),
        wakeSec: _at(morning.year, morning.month, morning.day, 7, 45, tz),
        onsetClockSec: _clockAsRecorded(23, 30),
      ));
    }
    final days = _records(stored);
    final coach = _coach(days);
    expect(_clockDist(_min(coach, 'wake', 'wake_min_of_day'), 7 * 60 + 45),
        lessThan(1.0));
  });

  test('a night recorded in the current zone reads exactly as before', () {
    // At home the frozen clock and today's reading agree, so no key is written
    // and the bundle is identical to one built without the scalar at all.
    final withClock =
        <({Map<String, dynamic> row, Map<String, dynamic> payload})>[];
    final without =
        <({Map<String, dynamic> row, Map<String, dynamic> payload})>[];
    for (var i = 0; i < 21; i++) {
      final onset =
          DateTime(2026, 9, i + 1, 23, 10).millisecondsSinceEpoch ~/ 1000;
      final wake =
          DateTime(2026, 9, i + 2, 7, 5).millisecondsSinceEpoch ~/ 1000;
      final day = _label(DateTime(2026, 9, i + 2));
      withClock.add(_stored(
          day: day,
          onsetSec: onset,
          wakeSec: wake,
          onsetClockSec: sleepClockOffsetSec(onset)));
      without.add(
          _stored(day: day, onsetSec: onset, wakeSec: wake, onsetClockSec: null));
    }
    final a = _records(withClock);
    expect(a.any((d) => d.containsKey('clock_shift_sec')), isFalse);
    expect(_coach(a).toString(), _coach(_records(without)).toString());
    expect(_clockDist(_min(_coach(a), 'wake', 'wake_min_of_day'), 7 * 60 + 5),
        lessThan(1.0));
  });

  test('re-deriving a pre-trip night keeps the clock it was lived on', () {
    // A re-derive freezes `sleep_onset_sec` in the phone's zone NOW; carrying
    // the stored row's shift puts it back on the UTC+2 clock, so the cross-day
    // record is the same as before the re-derive, in any runner zone.
    for (final prev in _europe()) {
      final onsetMs = (((prev.payload['sleep'] as Map)['window']
          as Map)['value'] as Map)['onset_ms'] as int;
      final onset = onsetMs ~/ 1000;
      final original =
          (prev.payload['scalars'] as Map)['sleep_onset_sec'] as double;
      final rederived = sleepClockOffsetSec(onset);
      final carried = shiftRecordedClockSec(
          rederived, storedNightClockShiftSec(prev.payload));
      expect(carried, original);

      final again = _stored(
        day: prev.row['day_id'] as String,
        onsetSec: onset,
        wakeSec: onset + 8 * 3600,
        onsetClockSec: carried,
      );
      expect(_records([again]).single['clock_shift_sec'],
          _records([prev]).single['clock_shift_sec']);
    }
  });

  test('a day lived at UTC+2 keeps its heart rate in its own hours', () {
    // One night at UTC+2 plus six minutes of HR at 14:00-14:05 its time. In
    // any runner zone the record bins that HR at 14, not at the phone's hour.
    final night = _europe().first;
    final onsetMs = (((night.payload['sleep'] as Map)['window'] as Map)['value']
        as Map)['onset_ms'] as int;
    final afternoon = onsetMs ~/ 1000 + 14 * 3600 + 30 * 60; // 23:30 + 14:30
    final payload = {
      ...night.payload,
      'series': {
        'hr_curve': [
          for (var i = 0; i < 6; i++) {'t': afternoon + i * 60, 'v': 70 + i},
        ],
      },
    };
    final hourly = _records([(row: night.row, payload: payload)])
        .single['hourly_hr'] as List;
    expect(hourly[14], closeTo(72.5, 1e-9));
    expect([for (var h = 0; h < 24; h++) if (h != 14) hourly[h]],
        everyElement(isNull));
  });

  test('a shifted clock wraps back into ±12 h and null stays null', () {
    expect(shiftRecordedClockSec(43000, 1000), -42400);
    expect(shiftRecordedClockSec(-43000, 86400 - 1000), 42400);
    expect(shiftRecordedClockSec(-16200, 0), -16200);
    expect(shiftRecordedClockSec(null, 7200), isNull);
    expect(storedNightClockShiftSec(null), 0);
    expect(storedNightClockShiftSec(const {'scalars': {}}), 0);
  });

  test('no frozen clock and no onset → no shift, never a guessed one', () {
    expect(recordedClockShiftSec(onsetSec: null, onsetClockSec: -16200), 0);
    expect(recordedClockShiftSec(onsetSec: 1789000000, onsetClockSec: null), 0);
    expect(
        recordedClockShiftSec(
            onsetSec: 1789000000, onsetClockSec: double.nan),
        0);
  });
}
