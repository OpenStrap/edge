// Steps and strain for the current day are a running total. The sweep runs from
// midday and arms the bedtime notification with its headline, so a 13:00 step
// count compared against full days read as "the lowest in 60 days" and was
// delivered hours later, after the user had walked the rest of the day.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ai/briefing_engine.dart';
import 'package:openstrap_edge/ai/nightly_sweep.dart';
import 'package:openstrap_edge/data/local_repository.dart';

int _t(DateTime d) => DateTime(d.year, d.month, d.day, 12).millisecondsSinceEpoch ~/ 1000;

class _Repo extends LocalRepository {
  _Repo(this.today);
  final double today;

  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async {
    if (metric != 'steps') return {'points': const []};
    final end = DateTime(2026, 10, 1);
    return {
      'points': [
        for (var i = 60; i >= 1; i--)
          {'t': _t(end.subtract(Duration(days: i))), 'v': 7000.0 + (i % 10) * 500},
        {'t': _t(end), 'v': today},
      ],
    };
  }
}

void main() {
  final day = DateTime(2026, 10, 1, 13);

  test('a running total is not reported as the lowest in N days', () async {
    final s = await collectSweepSeries(_Repo(3100), day, wallNow: day);
    expect(s.single.partial, isTrue);
    expect(sweepFindings(s), isEmpty);
  });

  test('a running total already above the window is still a finding', () async {
    final s = await collectSweepSeries(_Repo(30000), day, wallNow: day);
    final f = sweepFindings(s);
    expect(f.single.high, isTrue);
  });

  test('a finished day keeps its low finding', () async {
    final s = await collectSweepSeries(_Repo(3100), day,
        wallNow: DateTime(2026, 10, 2, 9));
    expect(s.single.partial, isFalse);
    final f = sweepFindings(s);
    expect(f.single.high, isFalse);
    expect(f.single.text, contains('the lowest in 60 days'));
  });
}
