// When a day's offloaded second half fails, the previous result's detail is
// carried into the fresh headline-only bundle so a re-derive never blanks it.
//
// The fresh bundle comes straight out of `deriveDayBundle`, whose `series` and
// `scalars` map literals are inferred as maps of curves and of doubles. The
// previous row is read back the way production reads it (`SeriesCodec`): a
// curve the codec left unencoded — an empty one, or one of fewer than
// `minPoints` samples — comes back a `List<dynamic>`, and writing it into the
// typed map threw, failing the whole re-derive instead of recovering.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/series_codec.dart';

const int _t0 = 1786699980; // a fixed epoch second on a minute boundary

/// A fresh headline-only bundle, as isolate 1 hands it back.
Map<String, dynamic> _freshBundle() {
  final ts = <int>[for (var i = 0; i < 2 * 3600; i++) _t0 + i];
  final hr = <int>[for (var i = 0; i < 2 * 3600; i++) 62 + (i % 5)];
  return deriveDayBundle(DayBundleInput(
    date: dayLabelOf(DateTime.fromMillisecondsSinceEpoch(_t0 * 1000)),
    dayTsSec: ts,
    dayHr: hr,
    sleepTsSec: const [],
    sleepHr: const [],
    sleepRrTsMs: const [],
    sleepRrMs: const [],
    sleepSkinTemp: const [],
    sleepJson: const {},
    hypnoStages: const [],
    sleepOnsetSec: 0,
    sleepOffsetSec: 0,
    profile: const {'age': 35, 'sex': 'm', 'weight_kg': 75, 'height_cm': 178},
    deviceFamily: 'gen4',
  ).toJson());
}

/// The previous COMPLETE row — the second half's curves, blocks and scalars on
/// top of a headline bundle — stored and read back through `SeriesCodec`, as
/// `_derivePreparedDay` reads it.
Map<String, dynamic> _storedCompleteRow() {
  final row = jsonDecode(jsonEncode(_freshBundle())) as Map<String, dynamic>;
  final series = row['series'] as Map;
  // Long enough for the codec to encode: decodes back typed.
  series['hrv_day'] = [
    for (var i = 0; i < 6; i++) {'t': _t0 + i * 300, 'v': 40.0 + i},
  ];
  // No skin temperature that day: an empty curve, which the codec leaves as
  // it is and which decodes back as a plain `List<dynamic>`.
  series['skin_temp_day'] = <Object>[];
  (row['scalars'] as Map)['nap_min'] = 25.0;
  // A whole-number scalar an older writer stored as an int.
  (row['scalars'] as Map)['awakenings_floor'] = 3;
  row['naps'] = [
    {'start': _t0, 'end': _t0 + 1200},
  ];
  return SeriesCodec.decodePayloadJson(
    SeriesCodec.encodePayloadJson(jsonEncode(row)),
  )!;
}

void main() {
  test('a failed second half carries a complete row\'s detail forward', () {
    final prev = _storedCompleteRow();
    expect((prev['series'] as Map)['skin_temp_day'], isA<List<dynamic>>());
    final next = _freshBundle();
    final freshHr = (next['series'] as Map)['hr_curve'];
    for (final key in const ['nap_min', 'awakenings_floor']) {
      expect((next['scalars'] as Map).containsKey(key), isFalse,
          reason: 'only the second half writes $key');
    }

    late bool carried;
    expect(() => carried = DerivationEngine.carryForwardDetail(prev, next),
        returnsNormally);
    expect(carried, isTrue);

    final series = next['series'] as Map;
    expect(series['hrv_day'], (prev['series'] as Map)['hrv_day']);
    expect(series['skin_temp_day'], isEmpty);
    expect(next['naps'], prev['naps']);
    expect((next['scalars'] as Map)['nap_min'], 25.0);
    expect((next['scalars'] as Map)['awakenings_floor'], 3);
    // A freshly computed curve always wins over the carried one.
    expect(series['hr_curve'], same(freshHr));
    // And the recovered bundle still serializes for `putDayResult`.
    expect(() => jsonEncode(next), returnsNormally);
  });

  test('nothing to carry leaves the fresh maps untouched', () {
    final next = _freshBundle();
    final scalars = next['scalars'];
    final series = next['series'];
    final prev = SeriesCodec.decodePayloadJson(
      SeriesCodec.encodePayloadJson(jsonEncode(_freshBundle())),
    )!;
    expect(DerivationEngine.carryForwardDetail(prev, next), isFalse);
    expect(next['scalars'], same(scalars));
    expect(next['series'], same(series));
  });

  // A retimed or rejected night re-derives the day. If that pass's second half
  // fails, the previous row's sleep blocks describe the OLD night and must not
  // be grafted onto the new window.
  group('a changed night does not carry the old night\'s sleep blocks', () {
    Map<String, dynamic> withWindow(Map<String, dynamic> b, int? on, int? off) {
      final sleep = Map<String, dynamic>.from(b['sleep'] as Map);
      sleep['window'] = {
        'value': on == null ? '\u2014' : {'onset_ms': on, 'offset_ms': off},
      };
      return b..['sleep'] = sleep;
    }

    const oldOn = 1786750200 * 1000, oldOff = 1786775400 * 1000;
    Map<String, dynamic> prevRow() {
      final prev = withWindow(_storedCompleteRow(), oldOn, oldOff);
      prev['sleep_periods'] = {
        'periods': [
          {'is_main': true, 'onset_ts': oldOn ~/ 1000, 'wake_ts': oldOff ~/ 1000},
        ],
      };
      prev['restlessness'] = {'value': 0.2};
      prev['hr_ceiling'] = {'value': 170};
      return prev;
    }

    for (final (label, on, off) in [
      ('retimed', 1786744800 * 1000, 1786777200 * 1000),
      ('rejected', null, null),
    ]) {
      test(label, () {
        final prev = prevRow();
        final next = withWindow(_freshBundle(), on, off);
        final moved = DerivationEngine.sleepWindowChanged(prev, next);
        expect(moved, isTrue);
        expect(
            DerivationEngine.carryForwardDetail(prev, next, carrySleep: !moved),
            isTrue);
        for (final k in DerivationEngine.kSleepOwnedDetailKeys) {
          expect(next.containsKey(k), isFalse, reason: k);
        }
        expect((next['scalars'] as Map).containsKey('nap_min'), isFalse);
        // Detail that does not hang off the night still comes across.
        expect(next['hr_ceiling'], prev['hr_ceiling']);
        expect((next['series'] as Map)['hrv_day'],
            (prev['series'] as Map)['hrv_day']);

        final outcome = DerivationEngine.recoveryOutcome(
          recovered: true,
          prevPartial: false,
          prevVersion: kAlgoVersion,
          prevFinalized: true,
          finalizedByAge: false,
          sleepMoved: moved,
        );
        expect(outcome.partial, isTrue);
        expect(outcome.finalized, isFalse);
      });
    }

    test('the same night still carries its sleep blocks', () {
      final prev = prevRow();
      final next = withWindow(_freshBundle(), oldOn, oldOff);
      expect(DerivationEngine.sleepWindowChanged(prev, next), isFalse);
      DerivationEngine.carryForwardDetail(prev, next);
      expect(next['sleep_periods'], prev['sleep_periods']);
      expect(next['naps'], prev['naps']);
      expect((next['scalars'] as Map)['nap_min'], 25.0);
    });

    test('no night either side is no change', () {
      expect(
          DerivationEngine.sleepWindowChanged(
              withWindow(_storedCompleteRow(), null, null),
              withWindow(_freshBundle(), null, null)),
          isFalse);
    });
  });
}
