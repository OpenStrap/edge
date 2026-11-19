import 'dart:convert';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/series_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';

import 'support/ed2a_recalc_fixture.dart';

void main() {
  setUpAll(edInit);
  setUp(() async {
    await edFresh('hmm_flag_cache.db');
    await edRows(edStart, edStart + 120, hr: 60, az: 1);
  });
  tearDown(edDrop);

  // why: the actual engine must persist the captured choice and replace old provenance.
  // # catches: wiring the flag into debug preparation but not the bundle worker.
  test('toggling re-derives only selected nights and clears stored fallback', () async {
    await edRows(edStart, edStart + 600, hr: 55, az: 1);
    await LocalDb.putSleepOverride(dayId: edDay, onsetTs: edStart,
      offsetTs: edStart + 600, source: 'manual');
    await LocalDb.putDayResult(dayId: '2019-01-01', algoVersion: kAlgoVersion,
      payloadJson: '{"date":"2019-01-01","sentinel":42}', windowJson: '{}');
    final e = DerivationEngine();
    final prefs = await SharedPreferences.getInstance();
    Future<Map<String, dynamic>> sleep() async {
      final row = await LocalDb.dayResult(edDay);
      final payload = SeriesCodec.decodePayloadJson(row!['payload_json'] as String)!;
      return (payload['sleep'] as Map).cast<String, dynamic>();
    }
    expect(await e.runDays(edProfile, {edDay}), 1);
    final cardio = await sleep();
    expect(cardio.containsKey('staging_method'), isFalse);
    await prefs.setBool(kSleepHmmStagesPref, true);
    expect(await e.runDays(edProfile, {edDay}), 1);
    final fallback = await sleep();
    expect(fallback['staging_effective_method'], 'cardio');
    expect(fallback['staging_fallback'], 'hmm_unavailable');
    await prefs.setBool(kSleepHmmStagesPref, false);
    expect(await e.runDays(edProfile, {edDay}), 1);
    final off = await sleep();
    expect(off.containsKey('staging_method'), isFalse);
    expect(off.containsKey('staging_fallback'), isFalse);
    final other = await LocalDb.dayResult('2019-01-01');
    expect(jsonDecode(other!['payload_json'] as String),
      {'date': '2019-01-01', 'sentinel': 42});
  });

  // why: imported substrate uses a separate preparation path into the same worker.
  // # catches: defaulting imports to cardio after moving the flag into prepared input.
  test('imported days carry the enabled flag into the bundle worker', () async {
    await (await SharedPreferences.getInstance()).setBool(kSleepHmmStagesPref, true);
    final choices = <Object?>[];
    final e = DerivationEngine()..debugOnNightBundle = (input, _) {
      choices.add(input['use_hmm_stages']);
    };
    expect(await e.deriveImportedDays(edSmallSub(count: 120), edProfile, {edDay}), 1);
    expect(choices, [true]);
  });

  // why: HMM worker inputs and cached candidates must agree on one flag value.
  // # catches: reading the flag only after preparation or omitting it from the key.
  test('toggle invalidates requested nights once and preserves unrelated cache hits', () async {
    final e = DerivationEngine();
    for (final day in [edDay, '2020-01-03']) {
      final prepared = await e.debugPrepareDay(day);
      expect(prepared!.toJson()['use_hmm_stages'] ?? false, isFalse);
    }
    final initial = e.debugStagingComputations;
    expect(initial, 2);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('unrelated_preference', true);
    await e.debugPrepareDay(edDay);
    expect(e.debugStagingComputations, initial);
    await prefs.setBool(kSleepHmmStagesPref, true);
    final prepared = await e.debugPrepareDay(edDay);
    expect(prepared!.toJson()['use_hmm_stages'], true);
    final restored = PreparedDerivationDay.fromJson(prepared.toJson());
    expect(restored.toJson()['use_hmm_stages'], true);
    expect(e.debugStagingComputations, initial + 1);
    await e.debugPrepareDay(edDay);
    expect(e.debugStagingComputations, initial + 1);
    await e.debugPrepareDay('2020-01-03');
    expect(e.debugStagingComputations, initial + 2);
    await prefs.setBool(kSleepHmmStagesPref, false);
    final off = await e.debugPrepareDay(edDay);
    expect(off!.toJson()['use_hmm_stages'] ?? false, isFalse);
    expect(e.debugStagingComputations, initial + 3);
    await e.debugPrepareDay(edDay);
    expect(e.debugStagingComputations, initial + 3);
  });
}
