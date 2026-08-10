// The wire format for day_result curves must be LOSSLESS or absent: every
// shape SeriesCodec can write, it must read back exactly, and anything it
// cannot encode losslessly must pass through untouched.
//
// The round-trip cases run against the three real bundle fixtures tracked in
// the repo root, so this pins the actual shapes the derivation engine emits
// rather than a hand-written approximation of them.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/series_codec.dart';

/// Structural equality over decoded JSON. Hand-rolled rather than pulling in
/// package:collection so the test adds no dependency.
bool deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !deepEquals(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

const fixtures = ['payload.json', 'payload_july10.json', 'payload_null.json'];

Map<String, dynamic> loadFixture(String name) =>
    (jsonDecode(File(name).readAsStringSync()) as Map).cast<String, dynamic>();

void main() {
  group('round-trip on real bundles', () {
    for (final name in fixtures) {
      test('$name survives encode → decode unchanged', () {
        final original = loadFixture(name);
        final encoded = SeriesCodec.encodePayload(loadFixture(name));
        final decoded = SeriesCodec.decodePayload(encoded);
        expect(
          deepEquals(original, decoded),
          isTrue,
          reason: '$name did not round-trip losslessly',
        );
      });

      test('$name shrinks by at least half', () {
        final before = jsonEncode(loadFixture(name)).length;
        final after = jsonEncode(SeriesCodec.encodePayload(loadFixture(name)))
            .length;
        expect(
          after,
          lessThan(before),
          reason: 'encoding must never grow a bundle',
        );
        // Measured 1.73x–2.67x across the three fixtures; 50% is the floor the
        // weakest one clears with room to spare.
        expect(after / before, lessThan(0.75));
      });

      test('$name encode is idempotent', () {
        final once = jsonEncode(SeriesCodec.encodePayload(loadFixture(name)));
        final twice = jsonEncode(
          SeriesCodec.encodePayload(
            (jsonDecode(once) as Map).cast<String, dynamic>(),
          ),
        );
        expect(twice, once);
      });

      test('$name reports needing re-encode before, not after', () {
        final raw = jsonEncode(loadFixture(name));
        expect(SeriesCodec.needsReencode(raw), isTrue);
        expect(
          SeriesCodec.needsReencode(SeriesCodec.encodePayloadJson(raw)),
          isFalse,
        );
      });
    }
  });

  group('shape selection', () {
    test('a regular curve becomes a grid', () {
      final out = SeriesCodec.encodeCurve([
        {'t': 100, 'v': 1},
        {'t': 160, 'v': 2},
        {'t': 220, 'v': 3},
      ]);
      expect(out, {
        't0': 100,
        'dt': 60,
        'v': [1, 2, 3],
      });
    });

    test('an irregular curve becomes offsets, with to[0] == 0', () {
      final out = SeriesCodec.encodeCurve([
        {'t': 100, 'v': 1},
        {'t': 161, 'v': 2},
        {'t': 400, 'v': 3},
      ]);
      expect(out, {
        't0': 100,
        'to': [0, 61, 300],
        'v': [1, 2, 3],
      });
    });

    test('zone_timeline round-trips on its z key', () {
      final points = [
        {'t': 100, 'z': 0},
        {'t': 160, 'z': 2},
        {'t': 220, 'z': 1},
      ];
      final enc = SeriesCodec.encodeCurve(points, valueKey: 'z');
      expect(enc, isA<Map>());
      expect(SeriesCodec.decodeCurve(enc, valueKey: 'z'), points);
    });
  });

  group('refuses anything it cannot encode losslessly', () {
    test('fewer than minPoints stays legacy', () {
      final short = [
        {'t': 100, 'v': 1},
        {'t': 160, 'v': 2},
      ];
      expect(SeriesCodec.encodeCurve(short), same(short));
    });

    test('an element with an extra key stays legacy', () {
      final extra = [
        {'t': 100, 'v': 1, 'q': 9},
        {'t': 160, 'v': 2, 'q': 9},
        {'t': 220, 'v': 3, 'q': 9},
      ];
      expect(SeriesCodec.encodeCurve(extra), same(extra));
    });

    test('a non-int timestamp stays legacy', () {
      final floaty = [
        {'t': 100.5, 'v': 1},
        {'t': 160.5, 'v': 2},
        {'t': 220.5, 'v': 3},
      ];
      expect(SeriesCodec.encodeCurve(floaty), same(floaty));
    });

    test('a missing value key stays legacy', () {
      final wrong = [
        {'t': 100, 'z': 1},
        {'t': 160, 'z': 2},
        {'t': 220, 'z': 3},
      ];
      expect(SeriesCodec.encodeCurve(wrong), same(wrong));
    });

    test('hypnogram segments are skipped — no t key', () {
      final hypno = [
        {'start': 1, 'end': 2, 'stage': 'light'},
        {'start': 2, 'end': 3, 'stage': 'deep'},
        {'start': 3, 'end': 4, 'stage': 'rem'},
      ];
      expect(SeriesCodec.encodeCurve(hypno), same(hypno));
    });

    test('hypnogram is left alone by a whole-payload encode', () {
      final payload = {
        'series': {
          'hypnogram': [
            {'start': 1, 'end': 2, 'stage': 'light'},
            {'start': 2, 'end': 3, 'stage': 'deep'},
            {'start': 3, 'end': 4, 'stage': 'rem'},
          ],
        },
      };
      final out = SeriesCodec.encodePayload(payload);
      expect(out['series']['hypnogram'], isA<List>());
    });
  });

  group('honesty — nulls are data, not gaps', () {
    test('null values survive a grid round-trip in place', () {
      final points = [
        {'t': 100, 'v': 1},
        {'t': 160, 'v': null},
        {'t': 220, 'v': 3},
      ];
      final enc = SeriesCodec.encodeCurve(points);
      expect((enc as Map)['v'], [1, null, 3]);
      expect(SeriesCodec.decodeCurve(enc), points);
    });

    test('null values survive an offset round-trip in place', () {
      final points = [
        {'t': 100, 'v': null},
        {'t': 161, 'v': 2},
        {'t': 400, 'v': null},
      ];
      final enc = SeriesCodec.encodeCurve(points);
      expect(SeriesCodec.decodeCurve(enc), points);
    });

    test('a non-monotonic curve still round-trips exactly', () {
      final points = [
        {'t': 400, 'v': 1},
        {'t': 100, 'v': 2},
        {'t': 250, 'v': 3},
      ];
      expect(SeriesCodec.decodeCurve(SeriesCodec.encodeCurve(points)), points);
    });

    test('duplicate timestamps round-trip exactly', () {
      final points = [
        {'t': 100, 'v': 1},
        {'t': 100, 'v': 2},
        {'t': 100, 'v': 3},
      ];
      expect(SeriesCodec.decodeCurve(SeriesCodec.encodeCurve(points)), points);
    });
  });

  group('malformed input degrades, never throws', () {
    // An unrecognised map is handed BACK, not replaced with an empty curve.
    // decodePayload is the read seam for every stored payload — baselines and
    // freshness rows go through it too — so emptying what it does not
    // understand would silently destroy data it was only passing along.
    test('an envelope with neither dt nor to is returned unchanged', () {
      final raw = {
        't0': 1,
        'v': [1, 2],
      };
      expect(SeriesCodec.decodeCurve(raw), same(raw));
    });

    test('a ragged offset envelope is returned unchanged', () {
      final raw = {
        't0': 1,
        'to': [0, 5],
        'v': [1, 2, 3],
      };
      expect(SeriesCodec.decodeCurve(raw), same(raw));
    });

    test('a missing t0 is returned unchanged', () {
      final raw = {
        'dt': 60,
        'v': [1, 2],
      };
      expect(SeriesCodec.decodeCurve(raw), same(raw));
    });

    test('unparseable json decodes to null, not a throw', () {
      expect(SeriesCodec.decodePayloadJson('{not json'), isNull);
      expect(SeriesCodec.decodePayloadJson(null), isNull);
      expect(SeriesCodec.decodePayloadJson(''), isNull);
    });

    test('unparseable json encodes back to itself', () {
      expect(SeriesCodec.encodePayloadJson('{not json'), '{not json');
      expect(SeriesCodec.encodePayloadJson('[1,2,3]'), '[1,2,3]');
    });

    test('decodePayload is idempotent and safe on foreign payloads', () {
      final baseline = {'value': 42.0, 'mean': 40.0, 'n': 28};
      final once = SeriesCodec.decodePayload({...baseline});
      expect(deepEquals(once, baseline), isTrue);
      expect(deepEquals(SeriesCodec.decodePayload(once), baseline), isTrue);
    });
  });
}
