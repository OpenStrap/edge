@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/sleep_profile_policy.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/ed2a_recalc_fixture.dart';

final _mid = DateTime(2020, 1, 2).millisecondsSinceEpoch ~/ 1000;
int _h(int hour) => _mid + hour * 3600;

// Longer previous night, shorter target, real motion and HR contrast. No
// forced/manual window: those deliberately cannot train the profile.
Substrate _night({bool target = true, bool earlierEvening = false}) {
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  for (var t = _h(-36); t < _h(30); t++) {
    final still = (t >= _h(earlierEvening ? -12 : -26) &&
        t < _h(earlierEvening ? -2 : -17)) ||
        (target && t >= _h(-1) && t < _h(5));
    ts.add(t);
    hr.add(still ? 52 + t % 7 : 80 + (t ~/ 60) % 20 + t % 3);
    ax.add(still ? 0 : .3 * math.sin(t * .21));
    ay.add(still ? 0 : .2 * math.cos(t * .13));
    az.add(still ? 1 : 1 + .05 * math.sin(t * .07));
  }
  return Substrate.fromJson({'ts_sec': ts, 'hr': hr, 'ax': ax, 'ay': ay,
    'az': az, 'device_family': 'gen4'});
}

String _observation(ana.SleepNightObservation o) => jsonEncode({
  'epochs': o.epochs, 'hr_floor_p5': o.hrFloorP5, 'hr_floor_p25': o.hrFloorP25,
  'hr_sleep_median': o.hrSleepMedian, 'hr_arousal': o.hrArousal,
  'rmssd_med': o.rmssdMed, 'rmssd_mad': o.rmssdMad,
  'enmo_still_cut': o.enmoStillCut, 'enmo_move_cut': o.enmoMoveCut,
  'lfhf_med': o.lfhfMed, 'rk_med': o.rkMed});

Future<void> _save(Substrate s) async {
  final b = (await LocalDb.instance).batch();
  for (var i = 0; i < s.length; i++) {
    b.insert('decoded_onehz', {'device_id': '', 'ts_ms': s.tsSec[i] * 1000,
      'rec_ts': s.tsSec[i], 'counter': i, 'hr': s.hr[i], 'ax': s.ax[i],
      'ay': s.ay[i], 'az': s.az[i], 'device_family': 'gen4'},
      conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await b.commit(noResult: true);
}

void main() {
  setUpAll(edInit);
  setUp(() => edFresh('ed2b_d36.db'));
  tearDown(() async {
    ana.cardioRecordObservations = false;
    ana.cardioUserProfile = null;
    ana.resetCardioObservations();
    await edDrop();
  });

  for (final target in [true, false]) {
    test('recordTargetOnly: ${target ? "one target observation" : "no target means none"}', () {
      ana.cardioRecordObservations = true;
      ana.resetCardioObservations();
      final sub = _night(target: target);
      // An existing exact restricted walk supplies an independent oracle; the
      // full walk must retain history while excluding its training side effects.
      calendarDays(sub, targetDay: edDay, skipUnusedDays: true);
      final expected = ana.takeCardioObservations().map(_observation).toList();
      expect(expected.length, target ? 1 : 0, reason: 'fixture sanity');
      ana.resetCardioObservations();
      final days = calendarDays(sub, targetDay: edDay, skipUnusedDays: false,
          recordTargetOnly: true);
      expect(days.length, greaterThan(1), reason: 'history walk remains real');
      expect(ana.takeCardioObservations().map(_observation).toList(), expected,
          reason: 'earlier and later walked nights must never train under the target ID');
      expect(ana.cardioRecordObservations, isTrue);
    });
  }

  test('production mayFold worker returns the target observation, never the longest walked night', () async {
    // Production's folding pass must use the same exact target-only walk as
    // the nonfolding path, and report that target's own training input.
    final sub = _night();
    await _save(sub);
    final e = DerivationEngine();
    final range = e.debugTargetDayWindow(edDay);
    final search = await e.debugLoadSubstrate(range.$1, range.$2, day: edDay);
    ana.cardioRecordObservations = true;
    ana.resetCardioObservations();
    prepareSleepSessionCandidate(search, targetDay: edDay, skipUnusedDays: true);
    final target = ana.takeCardioObservations();
    expect(target.length, 1, reason: 'the target has a usable real night');
    final observed = <String?>[];
    e.debugOnStagingWalk = (fold, count, observation) {
      expect(fold, isTrue);
      expect(count, 1, reason: 'target-only folding permits the E15 skip during training');
      observed.add(observation);
    };
    await e.debugSleepCandidate(edDay);
    expect(observed, [_observation(target.single)]);
  });

  test('production absent target never folds the earlier walked evening under its ID', () async {
    await _save(_night(target: false, earlierEvening: true));
    final observations = <String?>[];
    final e = DerivationEngine()..debugOnStagingWalk =
        (fold, _, observation) {
          expect(fold, isTrue);
          observations.add(observation);
        };
    final candidate = await e.debugSleepCandidate(edDay);
    expect(candidate.present, isFalse, reason: 'the only sleep ended before target midnight');
    expect(observations, [null], reason: 'no target observation means no training');
    expect(await LocalDb.baseline('sleep_user_profile'), isNull);
  });

  test('already folded profile and folded_days survive version adoption byte-for-byte (guard)', () async {
    await _save(_night());
    final profile = jsonEncode({...const ana.SleepUserProfile().toJson(),
      'nights': 7, 'folded_days': ['2019-12-31', edDay]});
    await LocalDb.putBaseline('sleep_user_profile', profile);
    final before = (await LocalDb.baseline('sleep_user_profile'))!['payload_json'];
    await DerivationEngine().debugSleepCandidate(edDay);
    expect((await LocalDb.baseline('sleep_user_profile'))!['payload_json'], before,
        reason: 'D36 is forward-only; existing accumulated evidence is not reset or rebuilt');
  });

  test('fold flags restored when segmentation throws (guard)', () {
    for (final initial in [true, false]) {
      ana.cardioRecordObservations = initial;
      expect(() => calendarDays(_night(), targetDay: edDay, recordTargetOnly: true,
          priorSleep: [for (var i = 1; i <= 14; i++)
            (startSec: _h(-24 * i - 1), endSec: _h(-24 * i + 5),
             dayKey: '2019-12-${i.toString().padLeft(2, '0')}')],
          tzOffsetAt: (_) => throw StateError('offset failure')), throwsStateError);
      expect(ana.cardioRecordObservations, initial);
    }
  });

  test('disabled recording remains disabled on successful target walk (guard)', () {
    ana.cardioRecordObservations = false;
    ana.resetCardioObservations();
    calendarDays(_night(), targetDay: edDay, recordTargetOnly: true);
    expect(ana.cardioRecordObservations, isFalse);
    expect(ana.takeCardioObservations(), isEmpty);
  });


  test('actual transactional folds preserve explicit deterministic order and idempotent replay (guard)', () async {
    final inputs = [
      ('2020-01-01', _observation(const ana.SleepNightObservation(
          epochs: 480, hrFloorP5: 51, hrSleepMedian: 56))),
      (edDay, _observation(const ana.SleepNightObservation(
          epochs: 720, hrFloorP5: 58, hrSleepMedian: 63))),
    ];
    final profiles = <String>[];
    for (var repeat = 0; repeat < 2; repeat++) {
      final db = await LocalDb.instance;
      await db.delete('baselines', where: 'key = ?', whereArgs: ['sleep_user_profile']);
      final order = <String>[];
      final e = DerivationEngine()..debugOnProfileFold = order.add;
      for (final input in inputs) {
        await e.debugFoldObservation(input.$1, input.$2);
      }
      expect(order, inputs.map((input) => input.$1).toList());
      final before = (await LocalDb.baseline('sleep_user_profile'))!['payload_json'];
      for (final input in inputs.reversed) {
        await e.debugFoldObservation(input.$1, input.$2);
      }
      expect((await LocalDb.baseline('sleep_user_profile'))!['payload_json'], before,
          reason: 'already folded nights leave the whole profile byte-identical');
      final profile = jsonDecode(before as String) as Map;
      profile.remove('updated_at_ms'); // operational fold timestamp only
      profiles.add(jsonEncode(profile));
    }
    expect(profiles.last, profiles.first);
  });

  test('folded day bookkeeping is deterministic regardless of insertion order (guard)', () {
    final a = SleepProfilePolicy.withFoldedDays({'nights': 8},
        {'2020-01-01', '2019-12-30'}, edDay);
    final b = SleepProfilePolicy.withFoldedDays({'nights': 8},
        {'2019-12-30', '2020-01-01'}, edDay);
    expect(jsonEncode(a), jsonEncode(b));
    expect(a['folded_days'], ['2019-12-30', '2020-01-01', edDay]);
  });
}
