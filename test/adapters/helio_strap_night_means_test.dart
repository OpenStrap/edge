// The strap's RMSSD, breathing-rate and SpO2 rows fill device slots that name
// the NIGHT's value (`kDeviceValueSlot`: hrv_avg -> rmssd, ...). They used to
// be calendar-day means, so waking-hours readings were shown as the night's.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/helio_strap.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

int _ms(int day, int h, [int m = 0]) =>
    DateTime(2026, 10, day, h, m).millisecondsSinceEpoch;

Huami2021SleepSession _night(int startMs, int endMs, {bool nap = false}) =>
    Huami2021SleepSession(
      sessionStartMs: startMs,
      isNap: nap,
      avgHr: 0,
      score: 0,
      sleepStartMin: 0,
      sleepEndMin: 0,
      remMin: 0,
      lightMin: 0,
      deepMin: 0,
      wakeMin: 0,
      stages: [Huami2021Stage(startMs, endMs, kHuami2021StageLight)],
    );

void main() {
  final night = _night(_ms(3, 23), _ms(4, 7));

  test('the mean runs over the staged night only, on its wake date', () {
    final rows = HelioStrapAdapter.nightMeans([
      night,
    ], {
      'hrv_avg': [
        (_ms(3, 15), 20), // afternoon: not the night's
        (_ms(4, 1), 60),
        (_ms(4, 3), 70),
        (_ms(4, 12), 15), // after wake
      ],
    });
    final hrv = rows.single;
    expect(hrv.vendorKey, 'hrv_avg');
    expect(hrv.value, 65);
    expect(hrv.unit, 'ms');
    expect(hrv.at, DateTime(2026, 10, 4),
        reason: 'a night begun at 23:00 is filed under the day it ended');
  });

  test('no reading inside a staged night: no row, never a day mean', () {
    expect(
      HelioStrapAdapter.nightMeans([night], {
        'respiration_avg': [(_ms(4, 14), 16)],
        'spo2_avg': [],
      }),
      isEmpty,
    );
    expect(
      HelioStrapAdapter.nightMeans(const [], {
        'hrv_avg': [(_ms(4, 2), 60)],
      }),
      isEmpty,
      reason: 'no staged night at all',
    );
  });

  test('a nap is not a night', () {
    expect(
      HelioStrapAdapter.nightMeans([
        _night(_ms(4, 14), _ms(4, 15), nap: true),
      ], {
        'hrv_avg': [(_ms(4, 14, 30), 50)],
      }),
      isEmpty,
    );
  });

  test('a night begun before the fetch window is not used, a whole one is',
      () {
    final cut = _night(_ms(1, 23), _ms(2, 7)); // window starts Oct 2 00:00
    final nap = _night(_ms(1, 23, 30), _ms(2, 0, 30), nap: true);
    expect(
        HelioStrapAdapter.wholeSessions(
            [cut, nap, night], DateTime(2026, 10, 2).millisecondsSinceEpoch),
        [night]);
  });
}
