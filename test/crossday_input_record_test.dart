import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  const today = '2026-09-10';
  const wake = 1789020000;

  Map<String, dynamic> row(String day, {int finalized = 0}) => {
        'day_id': day,
        'finalized': finalized,
        'rhr': 62.0,
        'rmssd': 41.0,
        'readiness': 55.0,
      };
  Map<String, dynamic> payload({bool sleep = true}) => {
        'scalars': {'resp_rate': 15.2, 'skin_temp_z': 0.4},
        if (sleep)
          'sleep': {
            'window': {
              'value': {
                'onset_ms': (wake - 7 * 3600) * 1000,
                'offset_ms': wake * 1000,
              },
            },
          },
      };
  Map<String, dynamic>? rec(Map<String, dynamic> r, Map<String, dynamic> p,
          {int? edge, Set<String> imported = const {}}) =>
      DerivationEngine.crossDayInputRecord(
          r, {...p, 'data_edge_sec': ?edge},
          today: today, imported: imported);

  group('today is unsettled only while its night is still draining', () {
    test('edge well past the wake: settled, alerts can read it', () {
      final r = rec(row(today), payload(), edge: wake + 2 * 3600)!;
      expect(r['unsettled'], isNull);
      expect(r['is_today'], isTrue);
    });

    test('edge still at the wake: unsettled', () {
      final r = rec(row(today), payload(), edge: wake + 600)!;
      expect(r['unsettled'], isTrue);
    });

    test('row derived before the drain caught up stays unsettled', () {
      // The derive saw data only up to the truncated wake. Whatever the edge
      // is now, this row's wake came from that substrate, so it is not settled.
      final r = rec(row(today), payload(), edge: wake)!;
      expect(r['unsettled'], isTrue);
      final noEdge = rec(row(today), payload())!;
      expect(noEdge['unsettled'], isTrue);
    });

    test('no night yet: unsettled', () {
      final r = rec(row(today), payload(sleep: false), edge: wake + 9 * 3600)!;
      expect(r['unsettled'], isTrue);
    });

    test('an older day is never flagged', () {
      final r = rec(row('2026-09-09'), payload(), edge: wake)!;
      expect(r['unsettled'], isNull);
    });
  });

  test('an imported day carries no vendor scores into the rollup', () {
    final r = rec(row('2026-09-01', finalized: 1), payload(),
        edge: wake, imported: {'2026-09-01'})!;
    for (final k in ['rhr', 'rmssd', 'readiness', 'resp_rate', 'skin_temp_z']) {
      expect(r[k], isNull, reason: k);
    }
    // sleep timing is not a vendor score
    expect(r['wake_sec'], wake);

    final own = rec(row('2026-09-02', finalized: 1), payload(),
        edge: wake, imported: {'2026-09-01'})!;
    expect(own['rhr'], 62.0);
  });
}
