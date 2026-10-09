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
}
