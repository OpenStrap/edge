import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import 'cardio_rows_cache.dart';
import 'night_rr_state.dart';

// Format 2 carries RSA v3 and closed-bin spectral states, not saved rates.
// Older closed windows cannot be certified under the current RSA floor gate.
const nightCheckpointFormat = 2;
const maxNightCheckpointBytes = 8 * 1024 * 1024;

/// One request's provenance, read before loading substrate. No decoded rows.
class NightCheckpointPlan {
  NightCheckpointPlan(this.from, this.through, this.revisions, this.generation,
      this.epoch, this.storeId);
  final int from, through, generation, epoch;
  final String storeId;
  final Map<int, int> revisions;
  String? context;
  int boundary = 0;
  List<Uint8List> cardio = [];
  NightRrState? restored;
}

Uint8List checkpointRevisions(Map<int, int> revisions, int from, int boundary) =>
    Uint8List.fromList(utf8.encode(jsonEncode([
      for (var b = from ~/ 900; b < boundary ~/ 900; b++)
        [b, revisions[b] ?? 0],
    ])));

typedef NightCheckpointRead = ({NightRrState? night, Uint8List? cardio,
  Map<String, Object?>? payload, String? rejection});
typedef NightCheckpointWrite = ({Uint8List bytes, Map<String, Object?> payload});

/// Worker only. SHA-256 covers both sections and all SQL provenance. No section
/// is returned unless every section and the complete revision vector validate.
NightCheckpointRead decodeNightCheckpoint(Map<String, Object?> row,
    String day, int algorithm, String context, int from, int through,
    Map<int, int> revisions, {List<double>? searchRr, List<double>? searchTimes}) {
  try {
    final boundary = row['cp_rec_ts'];
    if (row['day_id'] != day || row['algo_version'] != algorithm ||
        row['fmt'] != nightCheckpointFormat || row['ctx_sig'] != context ||
        row['night_ref'] != null || boundary is! int || boundary % 900 != 0 ||
        boundary <= from || boundary > through + 1) {
      throw const FormatException('checkpoint provenance');
    }
    final expectedRevisions = checkpointRevisions(revisions, from, boundary);
    if (base64Encode(row['rev_vec'] as List<int>) != base64Encode(expectedRevisions)) {
      throw const FormatException('checkpoint revisions');
    }
    final bytes = row['state'] as List<int>;
    if (bytes.length <= 32 || bytes.length > maxNightCheckpointBytes) {
      throw const FormatException('checkpoint length');
    }
    final body = bytes.sublist(32);
    if (base64Encode(sha256.convert(body).bytes) != base64Encode(bytes.sublist(0, 32))) {
      throw const FormatException('checkpoint checksum');
    }
    final payload = (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>();
    if (payload.length != 4 || payload['v'] != nightCheckpointFormat ||
        jsonEncode(payload['provenance']) != jsonEncode([
          day, algorithm, context, boundary, base64Encode(expectedRevisions),
        ])) {
      throw const FormatException('checkpoint envelope');
    }
    final night = NightRrState.fromCheckpoint(
        (payload['night'] as Map).cast<String, dynamic>(), boundary);
    if (((payload['night'] as Map)['tag'] as Map)['day'] != day ||
        (searchRr != null && (searchTimes == null ||
          !night.acceptsSearchPrefix(searchRr, searchTimes, day)))) {
      throw const FormatException('checkpoint raw prefix');
    }
    final cardioJson = (payload['cardio'] as Map).cast<String, dynamic>();
    final cardio = ana.CardioRowCache.fromJson(cardioJson);
    if (cardio.length > 8000) throw const FormatException('checkpoint cardio size');
    var outside = false;
    cardio.retainWhere((k) {
      if (k.startSec < from - 3600 || k.startSec + k.epochSec > boundary) outside = true;
      return true;
    });
    if (outside) throw const FormatException('checkpoint cardio window');
    return (night: night,
      cardio: Uint8List.fromList(utf8.encode(jsonEncode(cardioJson))),
      payload: payload, rejection: null);
  } catch (e) {
    return (night: null, cardio: null, payload: null,
      rejection: 'checkpoint refused: ${e.runtimeType}');
  }
}

/// Worker only. Oversized or absent nights stay on the ordinary cold path.
NightCheckpointWrite? encodeNightCheckpoint(NightRrState? night,
    List<Uint8List> chunks, String day, int algorithm, String context,
    int from, int boundary, Uint8List revisions) {
  final nightJson = night?.checkpoint(boundary);
  if (nightJson == null) return null;
  final cardio = decodeCardioRows(chunks);
  var kept = 0;
  cardio.retainWhere((k) => k.startSec >= from - 3600 &&
      k.startSec + k.epochSec <= boundary && kept++ < 8000);
  final payload = <String, Object?>{
    'v': nightCheckpointFormat,
    'provenance': [day, algorithm, context, boundary, base64Encode(revisions)],
    'night': nightJson, 'cardio': cardio.toJson(),
  };
  final body = utf8.encode(jsonEncode(payload));
  if (body.length + 32 > maxNightCheckpointBytes) return null;
  final bytes = Uint8List.fromList([...sha256.convert(body).bytes, ...body]);
  return (bytes: bytes,
    payload: (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>());
}
