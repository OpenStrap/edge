import 'dart:convert';
import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart' as ana;

/// Caller-owned bytes and provenance. Row objects exist only in the worker.
class CardioRowsChunk {
  CardioRowsChunk(this.bytes, this.loSec, this.hiSec, this.revisions,
      this.generation, this.algorithm);
  final Uint8List bytes;
  final int loSec, hiSec;
  final Map<String, (int, int, int)> revisions;
  int generation, algorithm;

  bool overlaps(int lo, int hi) => hiSec >= lo && loSec <= hi;

  bool matches(Map<String, (int, int, int)> current, int gen, int algo) =>
      generation == gen && algorithm == algo &&
      current.entries.every((e) =>
          !revisions.containsKey(e.key) || revisions[e.key] == e.value);
}

/// Worker only. Damage or an unknown codec version costs a cold staging.
ana.CardioRowCache decodeCardioRows(List<Uint8List> chunks) {
  final rows = ana.CardioRowCache();
  for (final bytes in chunks) {
    try {
      rows.merge(ana.CardioRowCache.fromJson(
          (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>()));
    } on FormatException {
      // Refuse the whole chunk.
    } on TypeError {
      // A structurally invalid JSON value is also a miss.
    }
  }
  return rows;
}

/// Keep at most one search window plus slack and 8,000 row variants. A limit
/// only evicts reusable work; analytics always recomputes a missing row.
Uint8List encodeCardioRows(ana.CardioRowCache rows, int lo, int hi) {
  var kept = 0;
  rows.retainWhere((k) =>
      k.startSec >= lo && k.startSec <= hi && kept++ < 8000);
  return Uint8List.fromList(utf8.encode(jsonEncode(rows.toJson())));
}
