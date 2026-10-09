// THE LOG IS RECOMPUTED FROM THE ROLLUP, so the thing to guard is that it
// reads the same days the notification did and never invents one.
//
// Four detectors fire and exactly one, illness, ever reached a screen. The
// history exists at all because `recent[]` already carries the per-day verdict
// for three of them — nothing new is stored, so the risk is not data loss, it
// is a log that disagrees with the buzz the user got that morning.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/findings.dart';

Map<String, dynamic> _cd(List<Map<String, dynamic>> recent) => {
      'recent': recent,
    };

Map<String, dynamic> _day(String date,
        {num? rhr,
        bool illness = false,
        bool anomaly = false,
        bool temp = false,
        bool unsettled = false}) =>
    {
      'date': date,
      'rhr': rhr,
      'illness': illness,
      'anomaly': anomaly,
      'temp': temp,
      'unsettled': unsettled,
    };

void main() {
  test('an empty or shapeless rollup is an empty log, not a throw', () {
    expect(findingsHistory(const {}), isEmpty);
    expect(findingsHistory(const {'recent': 'nonsense'}), isEmpty);
    expect(findingsHistory(_cd(const [])), isEmpty);
  });

  test('every detector reaches the log, not just illness', () {
    final f = findingsHistory(_cd([
      _day('2026-08-10', illness: true, anomaly: true, temp: true),
    ]), readiness: {
      '2026-08-10': 21
    }, irregularDays: {
      '2026-08-10'
    });
    expect(f.map((e) => e.kind), [
      FindingKind.illness,
      FindingKind.anomaly,
      FindingKind.tempElevated,
      FindingKind.irregularRhythm,
      FindingKind.lowReadiness,
    ]);
    // Detection, never diagnosis — the screen wording carries it.
    expect(f[3].detail, contains('not a diagnosis'));
    expect(f[4].score, 21);
  });

  test('newest day first', () {
    final f = findingsHistory(_cd([
      _day('2026-08-08', illness: true),
      _day('2026-08-09', illness: true),
    ]));
    expect(f.map((e) => e.date), ['2026-08-09', '2026-08-08']);
  });

  test('an unsettled day is not logged', () {
    // A night that is only half drained reads several bpm high. The
    // notification stands down on it; a log that showed the finding at 8 am
    // and dropped it by lunchtime would be worse than one that waits.
    expect(
        findingsHistory(_cd([_day('2026-08-10', illness: true, unsettled: true)])),
        isEmpty);
  });

  test('readiness only counts when there is one, and only when it is low', () {
    final days = [_day('2026-08-10')];
    expect(findingsHistory(_cd(days)), isEmpty);
    expect(findingsHistory(_cd(days), readiness: {'2026-08-10': 71}), isEmpty);
    // 33 is "Take it easy" on the ring, not its lowest band.
    expect(findingsHistory(_cd(days), readiness: {'2026-08-10': 33}), isEmpty);
    final low =
        findingsHistory(_cd(days), readiness: {'2026-08-10': 25}).single;
    expect(low.kind, FindingKind.lowReadiness);
    expect(low.score, 25);
    expect(findingsHistory(_cd(days), readiness: {'2026-08-10': 26}), isEmpty);
  });

  test('a resting-HR shift lands on the day it happened, with its direction',
      () {
    // A noisy fortnight and then a step up. The jitter is not decoration: a
    // perfectly flat baseline has no robust dispersion and the detector
    // deliberately emits nothing rather than fabricate a scale. The dates
    // travel with the values because the series is compacted — a day with no
    // nocturnal RHR is not in it, so an index is not a day.
    final days = <Map<String, dynamic>>[
      for (var i = 1; i <= 14; i++)
        _day('2026-08-${i.toString().padLeft(2, '0')}', rhr: 52 + i % 3),
      for (var i = 15; i <= 20; i++)
        _day('2026-08-$i', rhr: 64 + i % 3),
    ];
    final shifts = findingsHistory(_cd(days))
        .where((f) => f.kind == FindingKind.rhrShift);
    expect(shifts, isNotEmpty);
    expect(shifts.first.risen, isTrue);
    expect(shifts.first.detail, contains('risen'));
    // Nothing before the step is called a shift.
    expect(shifts.every((f) => f.date.compareTo('2026-08-14') > 0), isTrue);
  });

  test('a day with no rhr is skipped by the search, not misdated', () {
    // 9 usable days is under the search's floor, so it must say nothing at all
    // rather than run on too little.
    final days = [
      for (var i = 1; i <= 9; i++)
        _day('2026-08-0$i', rhr: i < 5 ? 50 : 65),
    ];
    expect(
        findingsHistory(_cd(days))
            .where((f) => f.kind == FindingKind.rhrShift),
        isEmpty);
  });
}
