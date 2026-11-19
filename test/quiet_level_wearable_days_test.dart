// A day only the active wearable saw is still a pending earlier day for the
// quiet-level repass: it can still produce a level, so a later day blocked on
// one is neither "proven unreachable" nor un-owed.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/ed2a_recalc_fixture.dart';

const _watch = ('garmin-a', 'garmin');

void main() {
  setUpAll(edInit);
  setUp(() async {
    await edFresh('quiet_wearable_days.db');
    await LocalDb.upsertDevice(
        id: _watch.$1, adapterId: _watch.$2, label: 'Watch A');
    await LocalDb.setCursor(kActiveWearableCursor, _watch.$1);
    await LocalDb.setCursor(wearableEnabledCursor(_watch.$2), '1');
    await edRows(edStart, edStart + 1200,
        id: _watch.$1, family: _watch.$2, source: _watch.$2, hr: 70, az: 0);
  });
  tearDown(edDrop);

  test('an underived wearable-only day keeps a later day reachable and owed',
      () async {
    for (final d in const ['2019-12-30', '2019-12-31']) {
      await LocalDb.putDayResult(
        dayId: d,
        algoVersion: kAlgoVersion,
        payloadJson: '{"date":"$d"}',
        windowJson: '{}',
        finalized: true,
        source: 'band',
        series: {'quiet_hrr': 0.2},
      );
    }
    final engine = DerivationEngine();
    const blocked = {
      'scalars': {'strain': null},
      'absent_notes': {'strain': 'need_baseline:have=2,need=3'},
    };
    // Two levels in hand plus edDay (wearable-only, not derived yet) = three.
    expect(await engine.debugQuietLevelUnreachable('2020-01-03'), isFalse);
    expect(await engine.debugQuietRepassOwed('2020-01-03', blocked), isTrue);
  });
}
