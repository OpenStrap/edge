@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/ed2a_recalc_fixture.dart';

List<({int startSec, int endSec, String dayKey})> _history(int distinct,
    {bool duplicates = false}) => [
  for (var i = 0; i < (duplicates ? 30 : distinct); i++)
    (startSec: DateTime(2019, 12, 1 + i % distinct, 1).millisecondsSinceEpoch ~/ 1000,
     endSec: DateTime(2019, 12, 1 + i % distinct, 7).millisecondsSinceEpoch ~/ 1000,
     dayKey: dayLabelOf(DateTime(2019, 12, 1 + i % distinct))),
];

PreparedDerivationPayload _walk(Substrate sub, {required bool skip,
    List<({int startSec, int endSec, String dayKey})> history = const [],
    SleepWindowOverride? override}) {
  debugSegmentedDayCount = 0;
  return prepareDerivationPayload(sub, targetDay: edDay,
      priorSleep: history, override: override, skipUnusedDays: skip);
}

void main() {
  setUpAll(edInit);
  setUp(() => edFresh("ed2a_e15.db"));
  tearDown(() async {
    debugStageEveryWalkedDay = false;
    debugSegmentedDayCount = 0;
    ana.cardioRecordObservations = false;
    ana.cardioUserProfile = null;
    ana.resetCardioObservations();
    await edDrop();
  });

  // Two local days, with enough seconds for the segmentation body on each.
  final sub = edSmallSub(start: DateTime(2020, 1, 1, 22).millisecondsSinceEpoch ~/ 1000,
      count: 10 * 3600);
  for (final h in [0, 1, 12]) {
    test('$h stored nights cannot reach 14: skip earlier day, equal target JSON', () {
      final history = _history(h);
      final full = _walk(sub, skip: false, history: history);
      expect(debugSegmentedDayCount, 2);
      final fast = _walk(sub, skip: true, history: history);
      expect(jsonEncode(fast.toJson()), jsonEncode(full.toJson()));
      expect(jsonEncode(edBundle(fast.days.single)),
          jsonEncode(edBundle(full.days.single)));
      expect(debugSegmentedDayCount, 1,
          reason: '$h distinct stored nights + one earlier day is below 14');
    });
  }

  test('30 rows with only 2 distinct night keys still permit the skip', () {
    final history = _history(2, duplicates: true);
    final full = _walk(sub, skip: false, history: history);
    final fast = _walk(sub, skip: true, history: history);
    expect(jsonEncode(fast.toJson()), jsonEncode(full.toJson()));
    expect(debugSegmentedDayCount, 1, reason: 'count distinct nights, not rows');
  });

  for (final h in [13, 14, 15]) {
    test('$h stored nights may reach 14: preserve full earlier walk (guard)', () {
      final full = _walk(sub, skip: false, history: _history(h));
      final fast = _walk(sub, skip: true, history: _history(h));
      expect(debugSegmentedDayCount, 2,
          reason: '13 prior nights plus one walked night can reach the prior threshold');
      expect(jsonEncode(fast.toJson()), jsonEncode(full.toJson()));
      expect(jsonEncode(edBundle(fast.days.single)), jsonEncode(edBundle(full.days.single)));
    });
  }

  test('override on an earlier day preserves its history contribution (guard)', () {
    final override = SleepWindowOverride(dayId: '2020-01-01',
      onsetSec: sub.tsSec.first, offsetSec: sub.tsSec.first + 3600, source: 'manual');
    final full = _walk(sub, skip: false, override: override);
    final fast = _walk(sub, skip: true, override: override);
    expect(debugSegmentedDayCount, 2);
    expect(jsonEncode(fast.toJson()), jsonEncode(full.toJson()));
  });

  test('full-walk control preserves upstream observations (guard)', () {
    ana.cardioRecordObservations = true;
    ana.resetCardioObservations();
    final full = _walk(sub, skip: false);
    final fullEpochs = [for (final o in ana.takeCardioObservations()) o.epochs];
    ana.resetCardioObservations();
    debugStageEveryWalkedDay = true;
    final forced = _walk(sub, skip: true);
    expect(debugSegmentedDayCount, 2);
    expect(jsonEncode(forced.toJson()), jsonEncode(full.toJson()));
    expect([for (final o in ana.takeCardioObservations()) o.epochs], fullEpochs);
  });

  test('production nonfolding worker actually requests the restricted skip', () async {
    await edFresh('ed2a_e15_nonfold.db');
    await edRows(sub.tsSec.first, sub.tsSec.last + 1, hr: 55, az: 1);
    final walked = <(bool, int)>[];
    final e = DerivationEngine()..debugOnStagingWalk =
        (fold, count, _) => walked.add((fold, count));
    final got = await e.debugSleepCandidate(edDay);
    final full = DerivationEngine()..debugDisableTargetDaySkip = true;
    expect(jsonEncode(got.toJson()),
        jsonEncode((await full.debugSleepCandidate(edDay)).toJson()));
    expect(walked, [(false, 1)],
        reason: 'nonfolding production staging must skip the irrelevant earlier day');
  });

  test('mayFold always walks earlier days and folds once (guard; D36 excluded)', () async {
    await edFresh('ed2a_e15_fold.db');
    await edRows(sub.tsSec.first, sub.tsSec.last + 1, hr: 55, az: 1);
    final edge = DateTime(2020, 1, 3, 12).millisecondsSinceEpoch ~/ 1000;
    await edRows(edge, edge + 1);
    final search = await DerivationEngine().debugLoadSubstrate(
        sub.tsSec.first, sub.tsSec.last, day: edDay);
    ana.cardioUserProfile = null;
    ana.cardioRecordObservations = true;
    ana.resetCardioObservations();
    final full = prepareSleepSessionCandidate(search, targetDay: edDay, skipUnusedDays: false);
    final observations = ana.takeCardioObservations()
      ..sort((a, b) => b.epochs.compareTo(a.epochs));
    expect(observations, isNotEmpty);
    final o = observations.first;
    final fullObservation = jsonEncode({'epochs': o.epochs,
      'hr_floor_p5': o.hrFloorP5, 'hr_floor_p25': o.hrFloorP25,
      'hr_sleep_median': o.hrSleepMedian, 'hr_arousal': o.hrArousal,
      'rmssd_med': o.rmssdMed, 'rmssd_mad': o.rmssdMad,
      'enmo_still_cut': o.enmoStillCut, 'enmo_move_cut': o.enmoMoveCut,
      'lfhf_med': o.lfhfMed, 'rk_med': o.rkMed});
    final walked = <(bool, int, String?)>[];
    final e = DerivationEngine()..debugOnStagingWalk =
        (fold, count, obs) => walked.add((fold, count, obs));
    final candidate = await e.debugSleepCandidate(edDay);
    expect(jsonEncode(candidate.toJson()), jsonEncode(full.toJson()));
    expect(walked.single.$3, fullObservation, reason: "preserve the full walk's actual fold input");
    expect(walked.single.$1, isTrue, reason: 'fixture reaches a folding pass');
    expect(walked.single.$2, 2,
        reason: 'the longest observation can still belong to the earlier day upstream');
    expect(walked.single.$3, isNotNull, reason: 'fixture must produce a real observation');
    final profile = (await LocalDb.baseline('sleep_user_profile'))!['payload_json'];
    final p = jsonDecode(profile as String) as Map;
    expect(p['nights'], 1);
    expect(p['folded_days'], contains(edDay));
    await e.debugSleepCandidate(edDay);
    expect((await LocalDb.baseline('sleep_user_profile'))!['payload_json'], profile,
        reason: 'repeated staging must preserve every profile byte');
  });

  test('existing fixture has exact target output with skip on and off (guard)', () async {
    await edFresh('ed2a_e15_fixture.db');
    await edExistingFixture();
    final e = DerivationEngine();
    final sub = await e.debugLoadSubstrate(1577880000, 1578038400, day: edDay);
    final full = _walk(sub, skip: false);
    final fast = _walk(sub, skip: true);
    expect(jsonEncode(fast.toJson()), jsonEncode(full.toJson()));
    expect(jsonEncode(edBundle(fast.days.single)), jsonEncode(edBundle(full.days.single)));
  });
}
