// Lossless, columnar, compressed copy of one (device_id, utc_day) bucket of
// the decoded substrate (`decoded_onehz` + `decoded_rr`).
//
// PURE and isolate-safe: no Flutter, no sqflite. Native VM only — integer
// deltas, zigzag and the fingerprint all rely on 64-bit wrapping int
// arithmetic, which the web does not have.
//
// WHY COLUMNAR. A day is ~86 400 rows of ~27 columns, and adjacent values in
// one column are nearly equal (a timestamp that steps by 1, a heart rate that
// moves by a few bpm, a device id that never changes). Laid out column by
// column, each column becomes a run of small, repetitive numbers that a
// general-purpose compressor shrinks far better than interleaved rows — the
// column-store argument of Abadi, Madden & Ferreira, "Integrating compression
// and execution in column-oriented database systems" (SIGMOD 2006):
//   * integers: delta against the previous non-NULL value, zigzag so a small
//     negative step stays small, LEB128-style varint;
//   * doubles: the IEEE-754 bytes split into byte planes (all byte-0s, then
//     all byte-1s, ...), so the slowly-changing sign/exponent bytes of a
//     sensor series sit next to each other — the same observation Gorilla
//     (Pelkonen et al., VLDB 2015) builds its XOR encoding on. Stored as
//     4-byte floats only when EVERY value round-trips through float32
//     bit-exactly, which is the case for anything the band sent as a float32;
//   * doubles that are exact short decimals — a decoder that rounds an
//     accelerometer reading to 4 places produces values that are pure noise
//     to the byte planes — as the integers `n` of `n / 10^k`, delta-varint
//     coded like any integer column. Chosen only when EVERY value of the
//     column reproduces bit-exactly from its integer; otherwise byte planes;
//   * text: a dictionary plus varint indices;
//   * anything else, including a column whose values do not share one SQLite
//     storage class (SQLite types per VALUE, not per column): a tagged
//     per-value encoding. Nothing is ever coerced.
// The whole buffer is then DEFLATE-compressed (zlib, RFC 1950/1951).
//
// SELF-DESCRIBING. The blob carries its own column directory, so a column
// added to the live table later is archived without anyone editing this file,
// and a blob that predates a column decodes that column as NULL.

import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

/// Storage kind of one archived column. These are the bytes written into the
/// blob — never renumber them.
abstract final class ArchiveKind {
  static const int none = 0; // every value NULL — no payload
  static const int integer = 1; // zigzag delta varints
  static const int f64 = 2; // 8 byte planes
  static const int f32 = 3; // 4 byte planes, only when float32 is bit-exact
  static const int text = 4; // dictionary + varint indices
  static const int variant = 5; // tagged per-value
  // f64 that are all exactly n / 10^k: u8 k, then n as zigzag delta varints.
  // A WIRE kind only — it decodes to an [f64] column.
  static const int decimal = 6;
}

/// One column of an [ArchiveTable]: a kind, an optional NULL bitmap and one
/// typed array of exactly `rowCount` slots (NULL slots hold a placeholder).
class ArchiveColumn {
  ArchiveColumn._(
    this.kind,
    this.rowCount, {
    this.nulls,
    this.ints,
    this.doubles,
    this.dict,
    this.codes,
    this.values,
  });

  final int kind;
  final int rowCount;

  /// Bit `i` set ⇒ row `i` is NULL. Null when the column has no NULL at all.
  final Uint8List? nulls;
  final Int64List? ints; // integer
  final Float64List? doubles; // f64 and f32 (f32 values are float32-exact)
  final List<String>? dict; // text
  final Int32List? codes; // text: index into [dict]
  final List<Object?>? values; // variant

  bool isNull(int row) {
    if (kind == ArchiveKind.none) return true;
    final n = nulls;
    return n != null && (n[row >> 3] >> (row & 7)) & 1 == 1;
  }

  Object? valueAt(int row) {
    if (isNull(row)) return null;
    switch (kind) {
      case ArchiveKind.integer:
        return ints![row];
      case ArchiveKind.f64:
      case ArchiveKind.f32:
        return doubles![row];
      case ArchiveKind.text:
        return dict![codes![row]];
      default:
        return values![row];
    }
  }

  /// Picks the narrowest kind that holds [vals] exactly. See the file header.
  factory ArchiveColumn.fromValues(List<Object?> vals) {
    final n = vals.length;
    var nullCount = 0;
    var allInt = true, allDouble = true, allString = true;
    for (final v in vals) {
      if (v == null) {
        nullCount++;
      } else {
        if (v is! int) allInt = false;
        if (v is! double) allDouble = false;
        if (v is! String) allString = false;
      }
    }
    if (nullCount == n) return ArchiveColumn._(ArchiveKind.none, n);
    Uint8List? nulls;
    if (nullCount > 0) {
      nulls = Uint8List((n + 7) >> 3);
      for (var i = 0; i < n; i++) {
        if (vals[i] == null) nulls[i >> 3] |= 1 << (i & 7);
      }
    }
    if (allInt) {
      final a = Int64List(n);
      for (var i = 0; i < n; i++) {
        final v = vals[i];
        if (v != null) a[i] = v as int;
      }
      return ArchiveColumn._(ArchiveKind.integer, n, nulls: nulls, ints: a);
    }
    if (allDouble) {
      final a = Float64List(n);
      var f32 = true;
      for (var i = 0; i < n; i++) {
        final v = vals[i];
        if (v == null) continue;
        a[i] = v as double;
        if (f32 && !_f32Exact(v)) f32 = false;
      }
      return ArchiveColumn._(
        f32 ? ArchiveKind.f32 : ArchiveKind.f64,
        n,
        nulls: nulls,
        doubles: a,
      );
    }
    if (allString) {
      final index = <String, int>{};
      final dict = <String>[];
      final codes = Int32List(n);
      for (var i = 0; i < n; i++) {
        final v = vals[i];
        if (v == null) continue;
        codes[i] = index.putIfAbsent(v as String, () {
          dict.add(v);
          return dict.length - 1;
        });
      }
      return ArchiveColumn._(
        ArchiveKind.text,
        n,
        nulls: nulls,
        dict: dict,
        codes: codes,
      );
    }
    return ArchiveColumn._(
      ArchiveKind.variant,
      n,
      nulls: nulls,
      values: List<Object?>.of(vals, growable: false),
    );
  }
}

/// One table's rows for one bucket, column by column, in archive row order.
class ArchiveTable {
  ArchiveTable(this.rowCount, this.columns);

  static final ArchiveTable empty = ArchiveTable(
    0,
    const <String, ArchiveColumn>{},
  );

  final int rowCount;

  /// Column name → column, in encode order.
  final Map<String, ArchiveColumn> columns;

  /// NULL when the row's value is NULL or the column is absent from the blob.
  Object? valueAt(String column, int row) => columns[column]?.valueAt(row);

  /// Row [row] as the map sqflite would have returned. [only] projects (and
  /// orders) the columns; a name the blob lacks maps to NULL.
  Map<String, Object?> rowAt(int row, [List<String>? only]) => {
    for (final c in only ?? columns.keys) c: valueAt(c, row),
  };

  /// [pages] joined end to end; a column missing from a page is NULL there.
  static ArchiveTable concat(List<ArchiveTable> pages) {
    if (pages.isEmpty) return empty;
    if (pages.length == 1) return pages.single;
    final names = <String>{for (final t in pages) ...t.columns.keys}.toList();
    return _gather([
      for (final t in pages)
        for (var i = 0; i < t.rowCount; i++) (t, i),
    ], names);
  }

  /// The rows for which [keep] is true, order preserved.
  ArchiveTable where(bool Function(int row) keep) {
    final picked = <int>[
      for (var i = 0; i < rowCount; i++)
        if (keep(i)) i,
    ];
    return _gather([for (final i in picked) (this, i)], columns.keys.toList());
  }
}

/// The two tables of one (device_id, utc_day) bucket.
class ArchiveBucket {
  const ArchiveBucket(this.onehz, this.rr);

  static final ArchiveBucket empty = ArchiveBucket(
    ArchiveTable.empty,
    ArchiveTable.empty,
  );

  final ArchiveTable onehz;
  final ArchiveTable rr;
}

/// Builds an [ArchiveTable] page by page from sqflite row maps.
///
/// EACH PAGE IS CONVERTED AS IT ARRIVES — to typed columns, kinds chosen per
/// page by [ArchiveColumn.fromValues] — and the row maps are dropped. A
/// caller on the UI isolate therefore never holds more than one page of
/// boxed values, and never converts a whole day in one synchronous step:
/// joining the pages ([ArchiveTable.concat]) is left to whoever calls
/// [build], which the archive does inside a worker isolate via [pages].
class ArchiveTableBuilder {
  final List<ArchiveTable> _pages = [];
  int _rows = 0;

  int get rowCount => _rows;

  /// The converted pages, in arrival order — cheap to send to an isolate.
  List<ArchiveTable> get pages => List.unmodifiable(_pages);

  void addRows(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) return;
    final cols = <String, List<Object?>>{};
    for (var i = 0; i < rows.length; i++) {
      for (final e in rows[i].entries) {
        (cols[e.key] ??= List<Object?>.filled(rows.length, null))[i] = e.value;
      }
    }
    _pages.add(
      ArchiveTable(rows.length, {
        for (final e in cols.entries) e.key: ArchiveColumn.fromValues(e.value),
      }),
    );
    _rows += rows.length;
  }

  ArchiveTable build() => ArchiveTable.concat(_pages);
}

/// The output of [SubstrateArchiveCodec.encodeMergeVerify]: a blob that has
/// already been decoded again and matched against what it was built from.
class ArchiveWrite {
  const ArchiveWrite({
    required this.blob,
    required this.rawBytes,
    required this.fingerprint,
    required this.onehzRows,
    required this.rrRows,
    required this.fromTs,
    required this.toTs,
  });

  final Uint8List blob;
  final int rawBytes;
  final int fingerprint;
  final int onehzRows;
  final int rrRows;

  /// Min / max `rec_ts` across both tables; null only for an empty bucket.
  final int? fromTs;
  final int? toTs;

  bool get isEmpty => onehzRows == 0 && rrRows == 0;

  /// No rows at all (nothing to write).
  ArchiveWrite.empty()
    : blob = Uint8List(0),
      rawBytes = 0,
      fingerprint = 0,
      onehzRows = 0,
      rrRows = 0,
      fromTs = null,
      toTs = null;
}

abstract final class SubstrateArchiveCodec {
  /// `substrate_archive.codec` for blobs this file writes.
  static const int codecId = 1;

  /// The byte after the magic.
  static const int formatVersion = 1;

  static const List<int> _magic = [0x4F, 0x53, 0x41, 0x31]; // 'OSA1'

  /// Row order inside a bucket. `ts_ms` last makes the order total: it is the
  /// per-device primary key.
  static const List<String> onehzOrder = ['rec_ts', 'counter', 'ts_ms'];
  static const List<String> rrOrder = ['rec_ts', 'beat_index', 'ts_ms'];

  static Uint8List encode(ArchiveBucket b) =>
      _deflate(_serialize(b), corrupt: false);

  /// Null on an unknown [codec] / format version or on any corruption. Never
  /// throws to callers.
  static ArchiveBucket? decode(Uint8List blob, {int codec = codecId}) {
    if (codec != codecId) return null;
    try {
      final raw = ZLibCodec().decode(blob);
      return _deserialize(raw is Uint8List ? raw : Uint8List.fromList(raw));
    } catch (_) {
      return null;
    }
  }

  /// FNV-1a 64 over a canonical serialization: columns by name, rows in
  /// order, a type tag and the exact value bytes. Independent of the storage
  /// kind chosen, so an f32 column and the doubles it came from agree.
  static int fingerprint(ArchiveBucket b) {
    final h = _Fnv();
    for (final t in [b.onehz, b.rr]) {
      h.uvarint(t.rowCount);
      final names = t.columns.keys.toList()..sort();
      h.uvarint(names.length);
      for (final name in names) {
        h.text(name);
        final c = t.columns[name]!;
        for (var r = 0; r < t.rowCount; r++) {
          h.value(c.valueAt(r));
        }
      }
    }
    return h.hash;
  }

  /// Union of two buckets of the same (device_id, utc_day), sorted.
  ///
  /// `decoded_onehz`: [winner]'s row wins per `ts_ms`, matching the live
  /// table's newest-wins REPLACE.
  ///
  /// `decoded_rr`: a second [winner] has EITHER a 1 Hz row OR beats for owns
  /// that second's whole beat set, and every [loser] beat at it is dropped —
  /// including when the winner's set is EMPTY. That is the live write rule:
  /// writing a second's 1 Hz row clears its beats first (`_queueRrBeats`), so
  /// a re-written second with no beats really has none. Taking the loser's
  /// beats there would resurrect beats the live table deliberately cleared;
  /// taking some of each would splice two beat series.
  static ArchiveBucket merge(ArchiveBucket winner, ArchiveBucket loser) {
    final winnerSeconds = <Object?>{
      for (final t in [winner.onehz, winner.rr])
        for (var i = 0; i < t.rowCount; i++) t.valueAt('ts_ms', i),
    };
    return ArchiveBucket(
      _mergeTable(winner.onehz, loser.onehz, onehzOrder, null),
      _mergeTable(winner.rr, loser.rr, rrOrder, winnerSeconds),
    );
  }

  /// Merge [incoming] over [existing] (incoming wins), encode, then DECODE
  /// THE BLOB AGAIN and check it against the merged rows: fingerprint and row
  /// counts. Throws on any mismatch, so a caller deleting live rows only ever
  /// does so against a blob that has been read back. A codec bug costs
  /// storage, never data.
  ///
  /// [existing] that cannot be decoded (unknown [existingCodec], corruption)
  /// throws rather than being overwritten.
  static ArchiveWrite encodeMergeVerify(
    ArchiveBucket incoming, {
    Uint8List? existing,
    int existingCodec = codecId,
    bool corruptForTest = false,
  }) {
    var base = ArchiveBucket.empty;
    if (existing != null) {
      base =
          decode(existing, codec: existingCodec) ??
          (throw StateError('existing archive bucket is unreadable'));
    }
    final merged = merge(incoming, base);
    if (merged.onehz.rowCount < incoming.onehz.rowCount ||
        merged.rr.rowCount < incoming.rr.rowCount) {
      throw StateError('merge lost incoming rows');
    }
    return _writeVerified(merged, corrupt: corruptForTest);
  }

  /// [b] with every row whose `rec_ts` lies in any `[start, end)` of [ranges]
  /// removed, re-encoded and verified. Null when nothing in [b] was in range.
  static ArchiveWrite? dropRanges(
    ArchiveBucket b,
    List<(int, int)> ranges, {
    bool corruptForTest = false,
  }) {
    bool outside(ArchiveTable t, int r) {
      final ts = t.valueAt('rec_ts', r);
      if (ts is! int) return true;
      for (final (start, end) in ranges) {
        if (ts >= start && ts < end) return false;
      }
      return true;
    }

    final kept = ArchiveBucket(
      b.onehz.where((r) => outside(b.onehz, r)),
      b.rr.where((r) => outside(b.rr, r)),
    );
    if (kept.onehz.rowCount == b.onehz.rowCount &&
        kept.rr.rowCount == b.rr.rowCount) {
      return null;
    }
    return _writeVerified(kept, corrupt: corruptForTest);
  }

  /// [b] cut down to the rows whose `rec_ts` lies in any `[start, end)` of
  /// [ranges], re-encoded and verified. Null when no row is in range. The
  /// inverse of [dropRanges]: used to export exactly the selected days.
  static ArchiveWrite? keepRanges(ArchiveBucket b, List<(int, int)> ranges) {
    bool inside(ArchiveTable t, int r) {
      final ts = t.valueAt('rec_ts', r);
      if (ts is! int) return false;
      for (final (start, end) in ranges) {
        if (ts >= start && ts < end) return true;
      }
      return false;
    }

    final kept = ArchiveBucket(
      b.onehz.where((r) => inside(b.onehz, r)),
      b.rr.where((r) => inside(b.rr, r)),
    );
    if (kept.onehz.rowCount == 0 && kept.rr.rowCount == 0) return null;
    return _writeVerified(kept, corrupt: false);
  }

  static ArchiveWrite _writeVerified(ArchiveBucket b, {required bool corrupt}) {
    final raw = _serialize(b);
    final blob = _deflate(raw, corrupt: corrupt);
    final back = decode(blob);
    final fp = fingerprint(b);
    if (back == null ||
        back.onehz.rowCount != b.onehz.rowCount ||
        back.rr.rowCount != b.rr.rowCount ||
        fingerprint(back) != fp) {
      throw StateError('archive blob failed read-back verification');
    }
    int? lo, hi;
    for (final t in [b.onehz, b.rr]) {
      for (var r = 0; r < t.rowCount; r++) {
        final ts = t.valueAt('rec_ts', r);
        if (ts is! int) continue;
        if (lo == null || ts < lo) lo = ts;
        if (hi == null || ts > hi) hi = ts;
      }
    }
    return ArchiveWrite(
      blob: blob,
      rawBytes: raw.length,
      fingerprint: fp,
      onehzRows: b.onehz.rowCount,
      rrRows: b.rr.rowCount,
      fromTs: lo,
      toTs: hi,
    );
  }

  static Uint8List _deflate(Uint8List raw, {required bool corrupt}) {
    final z = ZLibCodec(level: 6).encode(raw);
    final out = z is Uint8List ? z : Uint8List.fromList(z);
    // Test seam for the verify-before-delete path: one flipped byte inside
    // the deflate stream, so verification has something real to catch.
    if (corrupt && out.length > 6) out[out.length ~/ 2] ^= 0xFF;
    return out;
  }

  // ── wire format ───────────────────────────────────────────────────────────
  //
  // 'OSA1' · u8 formatVersion · varint tableCount (= 2), then per table:
  //   varint rowCount · varint colCount ·
  //   per column: varint nameLen · utf8 name · u8 kind · u8 nullFlag ·
  //               varint payloadLen
  //   then every column's payload, in directory order.
  // nullFlag = 1: a packed NULL bitmap (bit i ⇒ row i NULL) leads the
  // payload, and only non-NULL values follow it.

  static Uint8List _serialize(ArchiveBucket b) {
    final w = _Writer()
      ..bytes(_magic)
      ..byte(formatVersion)
      ..uvarint(2);
    for (final t in [b.onehz, b.rr]) {
      final payloads = <Uint8List>[];
      w
        ..uvarint(t.rowCount)
        ..uvarint(t.columns.length);
      for (final e in t.columns.entries) {
        final c = e.value;
        final name = utf8.encode(e.key);
        final hasNulls = c.kind != ArchiveKind.none && c.nulls != null;
        final scale = c.kind == ArchiveKind.f64 ? _decimalScale(c) : null;
        final payload = scale == null
            ? _encodeColumn(c, hasNulls)
            : _encodeDecimal(c, hasNulls, scale);
        payloads.add(payload);
        w
          ..uvarint(name.length)
          ..bytes(name)
          ..byte(scale == null ? c.kind : ArchiveKind.decimal)
          ..byte(hasNulls ? 1 : 0)
          ..uvarint(payload.length);
      }
      for (final p in payloads) {
        w.bytes(p);
      }
    }
    return w.take();
  }

  static Uint8List _encodeColumn(ArchiveColumn c, bool hasNulls) {
    final w = _Writer();
    if (c.kind == ArchiveKind.none) return w.take();
    if (hasNulls) w.bytes(c.nulls!);
    final n = c.rowCount;
    switch (c.kind) {
      case ArchiveKind.integer:
        var prev = 0;
        for (var i = 0; i < n; i++) {
          if (c.isNull(i)) continue;
          final v = c.ints![i];
          w.svarint(v - prev);
          prev = v;
        }
      case ArchiveKind.f64:
      case ArchiveKind.f32:
        final width = c.kind == ArchiveKind.f64 ? 8 : 4;
        final present = <int>[
          for (var i = 0; i < n; i++)
            if (!c.isNull(i)) i,
        ];
        final m = present.length;
        final bd = ByteData(m * width);
        for (var j = 0; j < m; j++) {
          final v = c.doubles![present[j]];
          if (width == 8) {
            bd.setFloat64(j * 8, v, Endian.little);
          } else {
            bd.setFloat32(j * 4, v, Endian.little);
          }
        }
        final planes = Uint8List(m * width);
        for (var k = 0; k < width; k++) {
          for (var j = 0; j < m; j++) {
            planes[k * m + j] = bd.getUint8(j * width + k);
          }
        }
        w.bytes(planes);
      case ArchiveKind.text:
        w.uvarint(c.dict!.length);
        for (final s in c.dict!) {
          final u = utf8.encode(s);
          w
            ..uvarint(u.length)
            ..bytes(u);
        }
        for (var i = 0; i < n; i++) {
          if (!c.isNull(i)) w.uvarint(c.codes![i]);
        }
      case ArchiveKind.variant:
        for (var i = 0; i < n; i++) {
          if (c.isNull(i)) continue;
          final v = c.values![i];
          if (v is int) {
            w
              ..byte(1)
              ..svarint(v);
          } else if (v is double) {
            final bd = ByteData(8)..setFloat64(0, v, Endian.little);
            w
              ..byte(2)
              ..bytes(bd.buffer.asUint8List());
          } else if (v is String) {
            final u = utf8.encode(v);
            w
              ..byte(3)
              ..uvarint(u.length)
              ..bytes(u);
          } else if (v is Uint8List) {
            w
              ..byte(4)
              ..uvarint(v.length)
              ..bytes(v);
          } else {
            // Not a SQLite value. Refuse rather than coerce — the caller
            // keeps the live rows.
            throw ArgumentError('unarchivable value type ${v.runtimeType}');
          }
        }
    }
    return w.take();
  }

  static const List<double> _pow10 = [
    1,
    1e1,
    1e2,
    1e3,
    1e4,
    1e5,
    1e6,
    1e7,
    1e8,
    1e9,
  ];

  /// The smallest k <= 9 for which EVERY value of an f64 column is exactly
  /// `n / 10^k` for an integer n — bit-exact, checked value by value — or
  /// null. Sensor values the decoder rounds to a fixed number of decimals
  /// (accelerometer g to 4 places, temperature to 2) are noise to a
  /// byte-plane encoding but small integers here.
  static int? _decimalScale(ArchiveColumn c) {
    scales:
    for (var k = 1; k < _pow10.length; k++) {
      for (var i = 0; i < c.rowCount; i++) {
        if (c.isNull(i)) continue;
        if (_decimalNumerator(c.doubles![i], k) == null) continue scales;
      }
      return k;
    }
    return null;
  }

  static const double _two53 = 9007199254740992.0;

  /// The integer n with `n / _pow10[k]` bit-identical to [v], or null. That
  /// exact expression is what the decoder evaluates, so a value that passes
  /// here cannot come back different. NaN, ±Inf, |n| >= 2^53 (n would no
  /// longer be exact as a double) and -0.0 (0 / p is +0.0) all return null.
  static int? _decimalNumerator(double v, int k) {
    final scaled = v * _pow10[k];
    if (!(scaled.abs() < _two53)) return null;
    final n = scaled.round();
    return _bits(n / _pow10[k]) == _bits(v) ? n : null;
  }

  static Uint8List _encodeDecimal(ArchiveColumn c, bool hasNulls, int k) {
    final w = _Writer();
    if (hasNulls) w.bytes(c.nulls!);
    w.byte(k);
    var prev = 0;
    for (var i = 0; i < c.rowCount; i++) {
      if (c.isNull(i)) continue;
      final n = _decimalNumerator(c.doubles![i], k)!;
      w.svarint(n - prev);
      prev = n;
    }
    return w.take();
  }

  // A corrupt header must not be able to ask for gigabytes.
  static const int _maxRows = 1 << 24;

  static ArchiveBucket _deserialize(Uint8List raw) {
    final r = _Reader(raw);
    for (final m in _magic) {
      if (r.byte() != m) throw const FormatException('bad magic');
    }
    if (r.byte() != formatVersion) {
      throw const FormatException('unknown format version');
    }
    if (r.uvarint() != 2) throw const FormatException('bad table count');
    final tables = <ArchiveTable>[];
    for (var t = 0; t < 2; t++) {
      final rows = r.uvarint();
      final cols = r.uvarint();
      if (rows > _maxRows || cols > 4096) {
        throw const FormatException('implausible table size');
      }
      final dir = <(String, int, bool, int)>[];
      for (var c = 0; c < cols; c++) {
        final name = utf8.decode(r.bytes(r.uvarint()));
        dir.add((name, r.byte(), r.byte() == 1, r.uvarint()));
      }
      final columns = <String, ArchiveColumn>{};
      for (final (name, kind, hasNulls, len) in dir) {
        columns[name] = _decodeColumn(
          _Reader(r.bytes(len)),
          kind,
          hasNulls,
          rows,
        );
      }
      tables.add(ArchiveTable(rows, columns));
    }
    if (!r.done) throw const FormatException('trailing bytes');
    return ArchiveBucket(tables[0], tables[1]);
  }

  static ArchiveColumn _decodeColumn(
    _Reader r,
    int kind,
    bool hasNulls,
    int n,
  ) {
    if (kind == ArchiveKind.none) {
      if (!r.done) throw const FormatException('NULL column has a payload');
      return ArchiveColumn._(ArchiveKind.none, n);
    }
    final nulls = hasNulls ? Uint8List.fromList(r.bytes((n + 7) >> 3)) : null;
    bool isNull(int i) => nulls != null && (nulls[i >> 3] >> (i & 7)) & 1 == 1;
    late final ArchiveColumn col;
    switch (kind) {
      case ArchiveKind.integer:
        final a = Int64List(n);
        var prev = 0;
        for (var i = 0; i < n; i++) {
          if (isNull(i)) continue;
          prev += r.svarint();
          a[i] = prev;
        }
        col = ArchiveColumn._(kind, n, nulls: nulls, ints: a);
      case ArchiveKind.f64:
      case ArchiveKind.f32:
        final width = kind == ArchiveKind.f64 ? 8 : 4;
        final present = <int>[
          for (var i = 0; i < n; i++)
            if (!isNull(i)) i,
        ];
        final m = present.length;
        final planes = r.bytes(m * width);
        final bd = ByteData(m * width);
        for (var k = 0; k < width; k++) {
          for (var j = 0; j < m; j++) {
            bd.setUint8(j * width + k, planes[k * m + j]);
          }
        }
        final a = Float64List(n);
        for (var j = 0; j < m; j++) {
          a[present[j]] = width == 8
              ? bd.getFloat64(j * 8, Endian.little)
              : bd.getFloat32(j * 4, Endian.little);
        }
        col = ArchiveColumn._(kind, n, nulls: nulls, doubles: a);
      case ArchiveKind.text:
        final dictLen = r.uvarint();
        if (dictLen > n) throw const FormatException('bad dictionary');
        final dict = [
          for (var d = 0; d < dictLen; d++) utf8.decode(r.bytes(r.uvarint())),
        ];
        final codes = Int32List(n);
        for (var i = 0; i < n; i++) {
          if (isNull(i)) continue;
          final code = r.uvarint();
          if (code >= dictLen) throw const FormatException('bad text code');
          codes[i] = code;
        }
        col = ArchiveColumn._(kind, n, nulls: nulls, dict: dict, codes: codes);
      case ArchiveKind.variant:
        final values = List<Object?>.filled(n, null);
        for (var i = 0; i < n; i++) {
          if (isNull(i)) continue;
          switch (r.byte()) {
            case 1:
              values[i] = r.svarint();
            case 2:
              values[i] = ByteData.sublistView(
                r.bytes(8),
              ).getFloat64(0, Endian.little);
            case 3:
              values[i] = utf8.decode(r.bytes(r.uvarint()));
            case 4:
              values[i] = Uint8List.fromList(r.bytes(r.uvarint()));
            default:
              throw const FormatException('bad variant tag');
          }
        }
        col = ArchiveColumn._(kind, n, nulls: nulls, values: values);
      case ArchiveKind.decimal:
        final k = r.byte();
        if (k < 1 || k >= _pow10.length) {
          throw const FormatException('bad decimal scale');
        }
        final a = Float64List(n);
        var prev = 0;
        for (var i = 0; i < n; i++) {
          if (isNull(i)) continue;
          prev += r.svarint();
          if (!(prev.abs() < _two53)) {
            throw const FormatException('decimal numerator out of range');
          }
          a[i] = prev / _pow10[k];
        }
        // Stored as f64 in memory: `decimal` is a wire encoding only.
        col = ArchiveColumn._(ArchiveKind.f64, n, nulls: nulls, doubles: a);
      default:
        // A kind this build does not know is never guessed at: the whole
        // blob is refused (decode returns null) and callers fail loudly.
        throw const FormatException('unknown column kind');
    }
    if (!r.done) throw const FormatException('column payload length mismatch');
    return col;
  }
}

// ── helpers ─────────────────────────────────────────────────────────────────

final Float32List _f32Scratch = Float32List(1);
final ByteData _bitsScratch = ByteData(8);

int _bits(double v) {
  _bitsScratch.setFloat64(0, v, Endian.little);
  return _bitsScratch.getInt64(0, Endian.little);
}

/// True when [v] survives a float32 round trip with IDENTICAL bits — so -0.0
/// stays -0.0 and a subnormal double that float32 would flush is not "equal".
bool _f32Exact(double v) {
  _f32Scratch[0] = v;
  return _bits(_f32Scratch[0]) == _bits(v);
}

/// Total order over SQLite values: NULL < numbers < text < blobs.
int _compareValues(Object? a, Object? b) {
  int rank(Object? v) => v == null
      ? 0
      : v is num
      ? 1
      : v is String
      ? 2
      : 3;
  final ra = rank(a), rb = rank(b);
  if (ra != rb) return ra - rb;
  if (a is num && b is num) return a.compareTo(b);
  if (a is String && b is String) return a.compareTo(b);
  return 0;
}

/// [winnerKeys] null ⇒ the winner's own `ts_ms` values. Both tables are keyed
/// by their second, `ts_ms` (one device per bucket): a winner second removes
/// every loser row at it.
ArchiveTable _mergeTable(
  ArchiveTable winner,
  ArchiveTable loser,
  List<String> order,
  Set<Object?>? winnerKeys,
) {
  winnerKeys ??= <Object?>{
    for (var i = 0; i < winner.rowCount; i++) winner.valueAt('ts_ms', i),
  };
  final picks = <(ArchiveTable, int)>[
    for (var i = 0; i < winner.rowCount; i++) (winner, i),
    for (var i = 0; i < loser.rowCount; i++)
      if (!winnerKeys.contains(loser.valueAt('ts_ms', i))) (loser, i),
  ];
  picks.sort((x, y) {
    for (final k in order) {
      final c = _compareValues(x.$1.valueAt(k, x.$2), y.$1.valueAt(k, y.$2));
      if (c != 0) return c;
    }
    return 0;
  });
  final names = <String>[
    ...winner.columns.keys,
    for (final k in loser.columns.keys)
      if (!winner.columns.containsKey(k)) k,
  ];
  return _gather(picks, names);
}

ArchiveTable _gather(List<(ArchiveTable, int)> picks, List<String> names) =>
    ArchiveTable(picks.length, {
      for (final name in names)
        name: ArchiveColumn.fromValues([
          for (final (t, i) in picks) t.valueAt(name, i),
        ]),
    });

class _Writer {
  Uint8List _buf = Uint8List(1 << 12);
  int _n = 0;

  void _ensure(int k) {
    if (_n + k <= _buf.length) return;
    var cap = _buf.length * 2;
    while (cap < _n + k) {
      cap *= 2;
    }
    _buf = Uint8List(cap)..setRange(0, _n, _buf);
  }

  void byte(int b) {
    _ensure(1);
    _buf[_n++] = b & 0xFF;
  }

  void bytes(List<int> b) {
    _ensure(b.length);
    _buf.setRange(_n, _n + b.length, b);
    _n += b.length;
  }

  /// Unsigned LEB128 over the 64-bit pattern (a negative int takes 10 bytes).
  void uvarint(int v) {
    _ensure(10);
    while ((v & ~0x7F) != 0) {
      _buf[_n++] = (v & 0x7F) | 0x80;
      v = v >>> 7;
    }
    _buf[_n++] = v;
  }

  /// Zigzag, so a small negative step stays a small varint.
  void svarint(int v) => uvarint((v << 1) ^ (v >> 63));

  Uint8List take() => Uint8List.sublistView(_buf, 0, _n);
}

class _Reader {
  _Reader(this._b);

  final Uint8List _b;
  int _i = 0;

  bool get done => _i == _b.length;

  int byte() {
    if (_i >= _b.length) throw const FormatException('truncated');
    return _b[_i++];
  }

  Uint8List bytes(int n) {
    if (n < 0 || _i + n > _b.length) throw const FormatException('truncated');
    final out = Uint8List.sublistView(_b, _i, _i + n);
    _i += n;
    return out;
  }

  int uvarint() {
    var result = 0;
    for (var shift = 0; shift < 70; shift += 7) {
      final b = byte();
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
    }
    throw const FormatException('varint too long');
  }

  int svarint() {
    final z = uvarint();
    return (z >>> 1) ^ -(z & 1);
  }
}

/// FNV-1a, 64-bit (offset basis 0xcbf29ce484222325, prime 0x100000001b3).
class _Fnv {
  int hash = 0xcbf29ce484222325;
  final ByteData _scratch = ByteData(8);

  void _byte(int b) {
    hash ^= b & 0xFF;
    hash *= 0x100000001b3;
  }

  void _bytes(List<int> b) {
    for (final x in b) {
      _byte(x);
    }
  }

  void uvarint(int v) {
    while ((v & ~0x7F) != 0) {
      _byte((v & 0x7F) | 0x80);
      v = v >>> 7;
    }
    _byte(v);
  }

  void text(String s) {
    final u = utf8.encode(s);
    uvarint(u.length);
    _bytes(u);
  }

  void _word() {
    for (var i = 0; i < 8; i++) {
      _byte(_scratch.getUint8(i));
    }
  }

  void value(Object? v) {
    if (v == null) {
      _byte(0);
    } else if (v is int) {
      _byte(1);
      _scratch.setInt64(0, v, Endian.little);
      _word();
    } else if (v is double) {
      _byte(2);
      _scratch.setFloat64(0, v, Endian.little);
      _word();
    } else if (v is String) {
      _byte(3);
      text(v);
    } else if (v is Uint8List) {
      _byte(4);
      uvarint(v.length);
      _bytes(v);
    } else {
      throw ArgumentError('unfingerprintable value type ${v.runtimeType}');
    }
  }
}
