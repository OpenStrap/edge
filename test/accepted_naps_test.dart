import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/accepted_naps.dart';
import 'package:openstrap_edge/compute/nap_edits.dart';

Map<String, dynamic> bundle({bool mainSleep = true}) => {
  if (mainSleep)
    'sleep': {
      'window': {
        'value': {'onset_ms': 0, 'offset_ms': 8 * 3600 * 1000},
      },
    },
  'naps': {'value': <Map<String, dynamic>>[], 'assessment_complete': true},
  'sleep_periods': {
    'assessment_complete': true,
    'periods': [
      if (mainSleep) {'is_main': true, 'duration_min': 360},
    ],
  },
};

NapEdit nap(int start, int end, {String source = 'legacy'}) => NapEdit(
  kind: NapEditKind.added,
  startSec: start,
  endSec: end,
  snapshot: source == 'manual' ? null : {'source': source, 'duration_min': 120},
);

void main() {
  test('a legacy continuation is not also credited as a nap', () {
    final day = bundle();
    final edit = nap(6 * 3600, 8 * 3600);
    composeAcceptedNaps(day, [edit]);

    expect(day['naps']['value'], isEmpty);
    expect(day['scalars']['nap_min'], 0);
    expect(day['sleep_periods']['periods'], hasLength(1));
    expect(day['sleep_periods']['total_asleep_min'], 360);
    composeAcceptedNaps(day, [edit]);
    expect(day['scalars']['nap_min'], 0);
    expect(day['sleep_periods']['total_asleep_min'], 360);

    // Keep the stored decision: a later correction that removes the main
    // window can expose this original snapshot again.
    final withoutMain = bundle(mainSleep: false);
    composeAcceptedNaps(withoutMain, [edit]);
    expect(withoutMain['naps']['value'], hasLength(1));
    expect(withoutMain['scalars']['nap_min'], 120);
  });

  for (final bounds in [
    (-3600, 3600),
    (7 * 3600, 9 * 3600),
    (-3600, 9 * 3600),
  ]) {
    test(
      'a partially overlapping legacy nap keeps its recorded duration: $bounds',
      () {
        final day = bundle();
        final edit = nap(bounds.$1, bounds.$2);
        composeAcceptedNaps(day, [edit]);
        expect(day['naps']['value'], hasLength(1));
        expect(day['scalars']['nap_min'], 120);
        expect(day['sleep_periods']['total_asleep_min'], 480);
        composeAcceptedNaps(day, [edit]);
        expect(day['scalars']['nap_min'], 120);
        expect(day['sleep_periods']['total_asleep_min'], 480);
      },
    );
  }

  test('legacy naps adjoining the main window stay separate', () {
    final day = bundle();
    composeAcceptedNaps(day, [nap(-7200, 0), nap(8 * 3600, 10 * 3600)]);
    expect(day['naps']['value'], hasLength(2));
    expect(day['scalars']['nap_min'], 240);
    expect(day['sleep_periods']['total_asleep_min'], 600);
  });

  for (final window in [
    <String, dynamic>{},
    {'onset_ms': 1000, 'offset_ms': 0},
    {'onset_ms': 'unknown', 'offset_ms': 8 * 3600 * 1000},
  ]) {
    test('invalid main window preserves the legacy nap: $window', () {
      final day = bundle();
      day['sleep'] = {
        'window': {'value': window},
      };
      composeAcceptedNaps(day, [nap(6 * 3600, 8 * 3600)]);
      expect(day['naps']['value'], hasLength(1));
    });
  }

  for (final source in ['manual', 'confirmed']) {
    test('a corrected window preserves a $source nap decision', () {
      final day = bundle();
      composeAcceptedNaps(day, [nap(6 * 3600, 8 * 3600, source: source)]);
      expect(day['naps']['value'], hasLength(1));
      expect(day['scalars']['nap_min'], 120);
    });
  }
}
