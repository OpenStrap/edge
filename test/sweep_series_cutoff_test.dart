// collectSweepSeries cuts history at the newest algo-version break, but only
// breaks up to the day being read count. A past day on the What changed
// stepper used to take a LATER bump as its cutoff and come back with zero
// days of history for every metric.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ai/briefing_engine.dart';
import 'package:openstrap_edge/data/local_repository.dart';

int _t(String date) => DateTime.parse('$date 12:00:00').millisecondsSinceEpoch ~/ 1000;

class _Repo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      {
        'points': [
          for (var d = 1; d <= 30; d++)
            {'t': _t('2026-09-${d.toString().padLeft(2, '0')}'), 'v': 50 + d % 3},
          {'t': _t('2026-10-01'), 'v': 55},
        ],
        'algo_breaks': [
          {'t': _t('2026-09-05'), 'from': 1, 'to': 2},
          {'t': _t('2026-10-01'), 'from': 2, 'to': 3},
        ],
      };
}

void main() {
  test('a past day keeps its history before a later version bump', () async {
    final s = await collectSweepSeries(_Repo(), DateTime(2026, 9, 25, 12));
    expect(s, isNotEmpty);
    // 2026-09-05 .. 2026-09-24: the earlier break still applies, the
    // 2026-10-01 one is after the day and must not.
    expect(s.first.history.length, 20);
  });

  test('the newest break still cuts when it is on or before the day', () async {
    final s = await collectSweepSeries(_Repo(), DateTime(2026, 10, 1, 12));
    expect(s.first.history, isEmpty);
  });
}
