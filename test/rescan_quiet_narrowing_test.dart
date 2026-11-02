// A rescan triggered only by the quiet level re-prices just the days whose
// strain window holds a level that moved.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  List<List<Object>> entries(Map<String, double> m) => [
        for (final e in (m.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key))))
          [e.key, e.value],
      ];

  test('a value that moved is a change, and only that one', () {
    final before = entries({
      '2026-07-01': .10,
      '2026-07-02': .15,
      '2026-07-03': .20,
    });
    final after = entries({
      '2026-07-01': .10,
      '2026-07-02': .25,
      '2026-07-03': .20,
    });
    expect(DerivationEngine.changedQuietDates(before, after), {'2026-07-02'});
  });

  test('a new level and a removed one are changes', () {
    final before = entries({'2026-07-01': .10, '2026-07-02': .15});
    final after = entries({'2026-07-01': .10, '2026-07-03': .30});
    expect(DerivationEngine.changedQuietDates(before, after),
        {'2026-07-02', '2026-07-03'});
  });

  test('an entry that slid off the older end is not a change', () {
    final before = entries({'2026-07-01': .10, '2026-07-02': .15});
    final after = entries({'2026-07-02': .15, '2026-07-03': .30});
    expect(DerivationEngine.changedQuietDates(before, after), {'2026-07-03'});
  });

  test('nothing stored yet means rescan everything', () {
    expect(DerivationEngine.changedQuietDates(null, const []), isNull);
  });
}
