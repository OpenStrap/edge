// The substrate archive codec: lossless round trip of every column kind,
// the float32 choice, never-throw decoding, the merge rules and the
// fingerprint the verify-before-delete path depends on. Pure, no database.

import 'dart:io' show ZLibCodec;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/substrate_archive_codec.dart';

ArchiveTable _table(List<Map<String, Object?>> rows) =>
    (ArchiveTableBuilder()..addRows(rows)).build();

ArchiveBucket _bucket(
  List<Map<String, Object?>> onehz, [
  List<Map<String, Object?>> rr = const [],
]) => ArchiveBucket(_table(onehz), _table(rr));

/// Every value identical — same runtime type and same bits/contents.
void _expectSameRows(ArchiveTable a, ArchiveTable b) {
  expect(b.rowCount, a.rowCount);
  expect(b.columns.keys.toList(), a.columns.keys.toList());
  for (var i = 0; i < a.rowCount; i++) {
    final ra = a.rowAt(i), rb = b.rowAt(i);
    for (final k in ra.keys) {
      final x = ra[k], y = rb[k];
      expect(
        identical(x.runtimeType, y.runtimeType),
        isTrue,
        reason: 'row $i col $k: ${x.runtimeType} vs ${y.runtimeType}',
      );
      if (x is double && y is double) {
        final bx = ByteData(8)..setFloat64(0, x);
        final by = ByteData(8)..setFloat64(0, y);
        expect(by.getInt64(0), bx.getInt64(0), reason: 'row $i col $k');
      } else {
        expect(y, x, reason: 'row $i col $k');
      }
    }
  }
}

void main() {
  test('round-trips every column kind bit-exactly', () {
    const big = 1 << 62;
    const near53 = (1 << 53) + 1;
    final rows = <Map<String, Object?>>[
      {
        'rec_ts': 1900000000,
        'ints': big,
        'f64': 0.1,
        'f32': -0.15020000934600830,
        'txt': 'é\u{1F600}',
        'mixed': 7,
        'allnull': null,
        'edges': null,
      },
      {
        'rec_ts': 1900000001,
        'ints': -big,
        'f64': -0.0,
        'f32': 0.5,
        'txt': null,
        'mixed': 2.5,
        'allnull': null,
        'edges': 3,
      },
      {
        'rec_ts': 1900000002,
        'ints': near53,
        'f64': 1e-310,
        'f32': -0.25,
        'txt': 'é\u{1F600}',
        'mixed': 'x',
        'allnull': null,
        'edges': 4,
      },
      {
        'rec_ts': 1900000003,
        'ints': -near53,
        'f64': 3.4028234663852886e38,
        'f32': -0.0,
        'txt': 'abc',
        'mixed': Uint8List.fromList([1, 2, 3]),
        'allnull': null,
        'edges': null,
      },
    ];
    final b = _bucket(rows, [
      {'rec_ts': 1900000000, 'beat_index': 0, 'rr_ms': 812},
    ]);
    final cols = b.onehz.columns;
    expect(cols['ints']!.kind, ArchiveKind.integer);
    expect(cols['f64']!.kind, ArchiveKind.f64);
    expect(cols['f32']!.kind, ArchiveKind.f32);
    expect(cols['txt']!.kind, ArchiveKind.text);
    expect(cols['mixed']!.kind, ArchiveKind.variant);
    expect(cols['allnull']!.kind, ArchiveKind.none);

    final back = SubstrateArchiveCodec.decode(SubstrateArchiveCodec.encode(b))!;
    _expectSameRows(b.onehz, back.onehz);
    _expectSameRows(b.rr, back.rr);
    // The NULL at rows 0 and n-1 is NULL, not 0.
    expect(back.onehz.valueAt('edges', 0), isNull);
    expect(back.onehz.valueAt('edges', 3), isNull);
    // A column the blob never had reads as NULL.
    expect(back.onehz.valueAt('no_such_column', 1), isNull);
  });

  test('chooses F32 only when every value round-trips through float32', () {
    expect(
      _table([
        {'v': 0.1},
      ]).columns['v']!.kind,
      ArchiveKind.f64,
    );
    expect(
      _table([
        {'v': 0.5},
        {'v': -0.25},
      ]).columns['v']!.kind,
      ArchiveKind.f32,
    );
  });

  /// The wire kind byte written for column [name] — the byte right after
  /// its name in the (inflated) column directory.
  int wireKind(Uint8List blob, String name) {
    final raw = Uint8List.fromList(ZLibCodec().decode(blob));
    final needle = name.codeUnits;
    for (var i = 0; i + needle.length < raw.length; i++) {
      var hit = true;
      for (var j = 0; j < needle.length && hit; j++) {
        hit = raw[i + j] == needle[j];
      }
      if (hit) return raw[i + needle.length];
    }
    throw StateError('column $name not found');
  }

  test('exact short decimals are stored as scaled integers, bit-exactly', () {
    final rows = <Map<String, Object?>>[
      for (var i = 0; i < 500; i++)
        {
          'rec_ts': 1900000000 + i,
          // What a decoder rounding to 4 / 2 places writes.
          'ax': ((i * 37 % 2001) - 1000) / 10000,
          'temp': 33 + (i % 50) / 100,
          // One value off the decimal grid keeps the column on byte planes.
          'near': i == 250 ? 0.1 + 0.2 : i / 10,
          // -0.0 has no integer numerator: also byte planes.
          'negzero': i == 3 ? -0.0 : i / 4 + 0.1,
          'sparse': i.isEven ? null : i / 1000,
        },
    ];
    final b = _bucket(rows);
    final blob = SubstrateArchiveCodec.encode(b);
    expect(wireKind(blob, 'ax'), ArchiveKind.decimal);
    expect(wireKind(blob, 'temp'), ArchiveKind.decimal);
    expect(wireKind(blob, 'sparse'), ArchiveKind.decimal);
    expect(wireKind(blob, 'near'), ArchiveKind.f64);
    expect(wireKind(blob, 'negzero'), ArchiveKind.f64);
    final back = SubstrateArchiveCodec.decode(blob)!;
    _expectSameRows(b.onehz, back.onehz);
    expect(
      SubstrateArchiveCodec.fingerprint(back),
      SubstrateArchiveCodec.fingerprint(b),
    );
  });

  double bitsStep(double v, int delta) {
    final bd = ByteData(8)..setFloat64(0, v);
    bd.setInt64(0, bd.getInt64(0) + delta);
    return bd.getFloat64(0);
  }

  test('edge doubles fall back whole and round-trip bit-identically', () {
    final edges = <double>[
      -0.0,
      double.nan,
      double.infinity,
      double.negativeInfinity,
      5e-324, // smallest subnormal
      1e-310,
      9007199254740991.0, // 2^53 - 1
      9007199254740994.0, // 2^53 + 2 (2^53 + 1 is not a double)
      0.1 + 0.2,
      bitsStep(0.1234, 1), // just above 1234 / 10^4
      bitsStep(0.1234, -1), // just below
      0.1234,
    ];
    final rows = <Map<String, Object?>>[
      for (var i = 0; i < edges.length; i++)
        {'rec_ts': 1900000000 + i, 'edge': edges[i], 'grid': i / 100},
    ];
    final b = _bucket(rows);
    final blob = SubstrateArchiveCodec.encode(b);
    expect(wireKind(blob, 'edge'), ArchiveKind.f64);
    expect(wireKind(blob, 'grid'), ArchiveKind.decimal);
    final back = SubstrateArchiveCodec.decode(blob)!;
    _expectSameRows(b.onehz, back.onehz);
    // Each edge alone in an otherwise decimal column drags the whole column
    // back to byte planes — never a partially-scaled column.
    for (final e in edges.where((e) => e != 0.1234)) {
      final col = _bucket([
        for (var i = 0; i < 20; i++)
          {'rec_ts': 1900000000 + i, 'v': i == 7 ? e : i / 10000},
      ]);
      final enc = SubstrateArchiveCodec.encode(col);
      expect(wireKind(enc, 'v'), ArchiveKind.f64, reason: '$e');
      _expectSameRows(col.onehz, SubstrateArchiveCodec.decode(enc)!.onehz);
    }
  });

  test('randomized round trip is bit-identical (fixed seed)', () {
    final rnd = Random(20261002);
    for (var round = 0; round < 20; round++) {
      final k = 1 + rnd.nextInt(6);
      final p = [1, 10, 100, 1000, 10000, 100000, 1000000][k];
      Object? cell(int kind) {
        if (rnd.nextInt(10) == 0) return null;
        switch (kind) {
          case 0: // on the decimal grid
            return (rnd.nextInt(2000001) - 1000000) / p;
          case 1: // arbitrary double, raw bits
            final bd = ByteData(8)
              ..setUint32(0, rnd.nextInt(1 << 32))
              ..setUint32(4, rnd.nextInt(1 << 32));
            return bd.getFloat64(0);
          case 2: // full-range 64-bit int
            return (rnd.nextInt(1 << 32) << 32) ^ rnd.nextInt(1 << 32);
          case 3:
            return String.fromCharCodes([
              for (var c = 0; c < rnd.nextInt(6); c++)
                0x20 + rnd.nextInt(0x2000),
            ]);
          default: // mixed storage classes
            return cell(rnd.nextInt(4));
        }
      }

      final rows = <Map<String, Object?>>[
        for (var i = 0; i < 300; i++)
          {
            'rec_ts': 1900000000 + i,
            'dec': cell(0),
            'dbl': cell(1),
            'int': cell(2),
            'txt': cell(3),
            'mix': cell(4),
          },
      ];
      final b = _bucket(rows);
      final back = SubstrateArchiveCodec.decode(
        SubstrateArchiveCodec.encode(b),
      )!;
      _expectSameRows(b.onehz, back.onehz);
      expect(
        SubstrateArchiveCodec.fingerprint(back),
        SubstrateArchiveCodec.fingerprint(b),
      );
    }
  });

  test('an unknown wire kind refuses the whole blob', () {
    final blob = SubstrateArchiveCodec.encode(
      _bucket([
        for (var i = 0; i < 10; i++) {'rec_ts': 1900000000 + i, 'zz': i / 10},
      ]),
    );
    final raw = Uint8List.fromList(ZLibCodec().decode(blob));
    final at = String.fromCharCodes(raw).indexOf('zz') + 2;
    expect(raw[at], ArchiveKind.decimal);
    raw[at] = 99;
    expect(
      SubstrateArchiveCodec.decode(Uint8List.fromList(ZLibCodec().encode(raw))),
      isNull,
    );
  });

  test('unknown formatVersion or truncated blob decodes to null', () {
    final b = _bucket([
      for (var i = 0; i < 50; i++) {'rec_ts': 1900000000 + i, 'hr': 60 + i % 7},
    ]);
    final blob = SubstrateArchiveCodec.encode(b);
    expect(SubstrateArchiveCodec.decode(blob), isNotNull);
    // The version byte sits right after 'OSA1', inside the deflate stream.
    final raw = Uint8List.fromList(ZLibCodec().decode(blob));
    expect(raw[4], SubstrateArchiveCodec.formatVersion);
    raw[4] = 0x7F;
    expect(
      SubstrateArchiveCodec.decode(Uint8List.fromList(ZLibCodec().encode(raw))),
      isNull,
    );
    expect(
      SubstrateArchiveCodec.decode(Uint8List.sublistView(blob, 0, 10)),
      isNull,
    );
    expect(SubstrateArchiveCodec.decode(blob, codec: 99), isNull);
    expect(SubstrateArchiveCodec.decode(Uint8List(0)), isNull);
  });

  test('merge: winner row replaces loser per ts_ms; an rr second in winner '
      'replaces all loser beats', () {
    const x = 1900000000;
    final loser = _bucket(
      [
        {'rec_ts': x, 'counter': 1, 'ts_ms': x * 1000, 'hr': 70},
        {'rec_ts': x + 1, 'counter': 2, 'ts_ms': (x + 1) * 1000, 'hr': 71},
      ],
      [
        for (final (i, rr) in const [(0, 700), (1, 710), (2, 720)])
          {'rec_ts': x, 'beat_index': i, 'ts_ms': x * 1000, 'rr_ms': rr},
        {
          'rec_ts': x + 1,
          'beat_index': 0,
          'ts_ms': (x + 1) * 1000,
          'rr_ms': 800,
        },
      ],
    );
    final winner = _bucket(
      [
        {'rec_ts': x, 'counter': 9, 'ts_ms': x * 1000, 'hr': 99},
      ],
      [
        {'rec_ts': x, 'beat_index': 0, 'ts_ms': x * 1000, 'rr_ms': 500},
      ],
    );
    final m = SubstrateArchiveCodec.merge(winner, loser);
    expect(m.onehz.rowCount, 2);
    expect(m.onehz.rowAt(0), containsPair('hr', 99));
    expect(m.onehz.rowAt(1), containsPair('hr', 71));
    final beatsAtX = [
      for (var i = 0; i < m.rr.rowCount; i++)
        if (m.rr.valueAt('ts_ms', i) == x * 1000) m.rr.valueAt('rr_ms', i),
    ];
    expect(beatsAtX, [500]);
    // The other second's beats are untouched.
    expect(m.rr.rowCount, 2);
  });

  test('merge: a winner second with a 1 Hz row and NO beats clears the '
      "loser's beats", () {
    // The live write clears a second's beats whenever it writes the 1 Hz
    // row, so 3 beats re-written to 0 must stay 0 — not come back from the
    // older copy.
    const x = 1900000000;
    final loser = _bucket(
      [
        {'rec_ts': x, 'counter': 1, 'ts_ms': x * 1000, 'hr': 70},
      ],
      [
        for (final (i, rr) in const [(0, 700), (1, 710), (2, 720)])
          {'rec_ts': x, 'beat_index': i, 'ts_ms': x * 1000, 'rr_ms': rr},
        // A beat-only second the winner does not mention survives.
        {'rec_ts': x + 9, 'beat_index': 0, 'ts_ms': (x + 9) * 1000, 'rr_ms': 1},
      ],
    );
    final winner = _bucket([
      {'rec_ts': x, 'counter': 1, 'ts_ms': x * 1000, 'hr': 71},
    ]);
    final m = SubstrateArchiveCodec.merge(winner, loser);
    expect(
      [for (var i = 0; i < m.rr.rowCount; i++) m.rr.valueAt('ts_ms', i)],
      [(x + 9) * 1000],
    );
  });

  test('the builder converts per page and joins pages losslessly', () {
    final builder = ArchiveTableBuilder()
      ..addRows([
        for (var i = 0; i < 3; i++) {'rec_ts': i, 'hr': 60 + i},
      ])
      ..addRows([
        for (var i = 3; i < 5; i++) {'rec_ts': i, 'hr': 60.5, 'late': 'x'},
      ]);
    expect(builder.pages, hasLength(2));
    final t = builder.build();
    expect(t.rowCount, 5);
    expect(
      [for (var i = 0; i < 5; i++) t.valueAt('hr', i)],
      [60, 61, 62, 60.5, 60.5],
    );
    expect(t.columns['hr']!.kind, ArchiveKind.variant);
    expect(t.valueAt('late', 0), isNull);
    expect(t.valueAt('late', 4), 'x');
  });

  test('merge sorts rows and unions columns', () {
    final a = _bucket([
      {'rec_ts': 5, 'counter': 0, 'ts_ms': 5000, 'hr': 1},
    ]);
    final b = _bucket([
      {'rec_ts': 3, 'counter': 0, 'ts_ms': 3000, 'extra': 'old'},
    ]);
    final m = SubstrateArchiveCodec.merge(a, b);
    expect(
      [m.onehz.valueAt('rec_ts', 0), m.onehz.valueAt('rec_ts', 1)],
      [3, 5],
    );
    expect(m.onehz.valueAt('hr', 0), isNull);
    expect(m.onehz.valueAt('extra', 0), 'old');
    expect(m.onehz.valueAt('extra', 1), isNull);
  });

  test('fingerprint differs when any single value differs', () {
    List<Map<String, Object?>> rows() => [
      for (var i = 0; i < 10; i++)
        {'rec_ts': 1900000000 + i, 'hr': 60, 'ax': 0.5, 'src': 'band'},
    ];
    final base = _bucket(rows());
    final fp = SubstrateArchiveCodec.fingerprint(base);
    expect(SubstrateArchiveCodec.fingerprint(_bucket(rows())), fp);
    for (final changed in <Object?>[61, 60.0, '60', null]) {
      final r = rows();
      r[4]['hr'] = changed;
      expect(
        SubstrateArchiveCodec.fingerprint(_bucket(r)),
        isNot(fp),
        reason: 'hr -> $changed',
      );
    }
    // The fingerprint survives the encode/decode round trip.
    final back = SubstrateArchiveCodec.decode(
      SubstrateArchiveCodec.encode(base),
    )!;
    expect(SubstrateArchiveCodec.fingerprint(back), fp);
  });

  test('encodeMergeVerify throws on a corrupted encode, never returns it', () {
    final b = _bucket([
      for (var i = 0; i < 200; i++)
        {'rec_ts': 1900000000 + i, 'hr': 60 + i % 9},
    ]);
    expect(
      () => SubstrateArchiveCodec.encodeMergeVerify(b, corruptForTest: true),
      throwsStateError,
    );
    final ok = SubstrateArchiveCodec.encodeMergeVerify(b);
    expect(ok.onehzRows, 200);
    expect(ok.fromTs, 1900000000);
    expect(ok.toTs, 1900000199);
  });

  test('encodeMergeVerify refuses to overwrite an unreadable bucket', () {
    final b = _bucket([
      {'rec_ts': 1900000000, 'ts_ms': 1900000000000},
    ]);
    final blob = SubstrateArchiveCodec.encode(b);
    expect(
      () => SubstrateArchiveCodec.encodeMergeVerify(
        b,
        existing: blob,
        existingCodec: 2,
      ),
      throwsStateError,
    );
  });

  test('dropRanges removes exactly the rows in [start, end)', () {
    final b = _bucket(
      [
        for (var i = 0; i < 10; i++)
          {'rec_ts': 100 + i, 'ts_ms': (100 + i) * 1000},
      ],
      [
        {'rec_ts': 104, 'beat_index': 0, 'ts_ms': 104000, 'rr_ms': 900},
        {'rec_ts': 108, 'beat_index': 0, 'ts_ms': 108000, 'rr_ms': 910},
      ],
    );
    final w = SubstrateArchiveCodec.dropRanges(b, const [
      (103, 106),
      (200, 300),
    ])!;
    final back = SubstrateArchiveCodec.decode(w.blob)!;
    expect(
      [
        for (var i = 0; i < back.onehz.rowCount; i++)
          back.onehz.valueAt('rec_ts', i),
      ],
      [100, 101, 102, 106, 107, 108, 109],
    );
    expect(back.rr.rowCount, 1);
    expect(SubstrateArchiveCodec.dropRanges(b, const [(500, 600)]), isNull);
    expect(
      () => SubstrateArchiveCodec.dropRanges(b, const [
        (103, 106),
      ], corruptForTest: true),
      throwsStateError,
    );
  });
}
