// Which recorded observation belongs to the night a derive chose. The search
// window also stages the day before's sessions; the longest observation of all
// is not necessarily the chosen night's.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';

ana.SleepNightObservation _o(int epochs, int? start, int? end) =>
    ana.SleepNightObservation(epochs: epochs, startTsSec: start, endTsSec: end);

void main() {
  test('takes the observation staged over the night, not the longest one', () {
    final dayBefore = _o(900, 1000, 28000); // longer, but another day
    final night = _o(500, 40000, 58000);
    expect(observationOfNight([dayBefore, night], 40500, 57500), same(night));
    expect(observationOfNight([night, dayBefore], 40500, 57500), same(night));
  });

  test('of two overlapping windows, the one overlapping the night most wins', () {
    final partial = _o(300, 30000, 41000);
    final whole = _o(500, 40000, 58000);
    expect(observationOfNight([partial, whole], 40500, 57500), same(whole));
  });

  test('no observation overlapping the night folds nothing', () {
    expect(observationOfNight([_o(900, 1000, 28000)], 40500, 57500), isNull);
    expect(observationOfNight(const [], 40500, 57500), isNull);
  });

  test('an observation with no window never matches', () {
    expect(observationOfNight([_o(900, null, null)], 40500, 57500), isNull);
    expect(observationOfNight([_o(900, 40000, null)], 40500, 57500), isNull);
  });
}
