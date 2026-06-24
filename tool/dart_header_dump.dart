// Throwaway: decode the 550 whoop_hist R24 frames with the EDGE Dart decoder
// (header subset) and dump {hex, counter, ts_epoch, ts_subsec, hr} so the Rust
// core's decode_r24 can be checked byte-identical on the header it shares.
import 'dart:convert';
import 'dart:io';
import 'package:openstrap_edge/protocol/records.dart';

void main() {
  final home = Platform.environment['HOME']!;
  final lines = File('$home/Documents/whoop-master/whoop_hist.jsonl')
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty);
  final out = <Map<String, dynamic>>[];
  for (final line in lines) {
    final hex = (jsonDecode(line) as Map)['hex'] as String;
    final r = parseR24(hexToBytes(hex));
    if (r == null) continue;
    out.add({
      'hex': hex,
      'counter': r.counter,
      'ts_epoch': r.tsEpoch,
      'ts_subsec': r.tsSubsec,
      'hr': r.hr,
    });
  }
  File('$home/Documents/whoop-master/openstrap-analytics/core/dart_header.json')
      .writeAsStringSync(jsonEncode(out));
  stdout.writeln('dart decoded ${out.length} R24 headers');
}
