// Streams a local-only research bundle. No share sheet or network integration.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show frameAccel;
import 'package:path/path.dart' as p;

import 'whoop4_r10_capture.dart';

class R10StudyInterval {
  const R10StudyInterval({
    required this.startEpochS,
    required this.endEpochS,
    this.label,
    this.countedSteps,
  });
  final int startEpochS, endEpochS;
  final String? label;
  final int? countedSteps;

  Map<String, Object?> toMap() {
    if (endEpochS <= startEpochS ||
        (countedSteps != null && countedSteps! < 0) ||
        (label?.length ?? 0) > 120) {
      throw ArgumentError('invalid_study_interval');
    }
    return {
      'start_epoch_s': startEpochS,
      'end_epoch_s': endEpochS,
      'label': label,
      'independently_counted_steps': countedSteps,
      'source': 'user_annotation_not_band_output',
    };
  }
}

Future<String> exportWhoop4R10(
  Whoop4R10Capture capture, {
  R10StudyInterval? interval,
  int maxExportBytes = 64 * 1024 * 1024,
}) => capture.withStoppedSession((directory, manifest, valid) async {
  final study = interval?.toMap();
  final path = directory.path;
  final result = await Isolate.run(
    () => _writeExport(path, manifest, study, maxExportBytes),
  );
  if (!valid()) {
    final file = File(result);
    if (await file.exists()) await file.delete();
    throw StateError('research_export_revoked');
  }
  return result;
});

String _writeExport(
  String root,
  Map<String, Object?> manifest,
  Map<String, Object?>? study,
  int maxBytes,
) {
  final directory = Directory(p.join(root, 'exports'));
  directory.createSync(recursive: true);
  final output = File(p.join(directory.path, 'whoop4_r10.ndjson'));
  final partial = File(p.join(directory.path, 'whoop4_r10.partial'));
  if (output.existsSync()) output.deleteSync();
  final sink = partial.openSync(mode: FileMode.write);
  var size = 0, count = 0, conflicts = 0;
  var closed = false;
  final timestamps = <int, Set<String>>{};
  final payloads = <String>{};
  void write(Map<String, Object?> value) {
    final bytes = utf8.encode('${jsonEncode(value)}\n');
    if (size + bytes.length > maxBytes) {
      throw StateError('research_export_size_limit');
    }
    sink.writeFromSync(bytes);
    size += bytes.length;
  }

  try {
    final chunks =
        Directory(root)
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  p.basename(f.path).startsWith('chunk_') &&
                  p.extension(f.path) == '.ndjson',
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    var partialChunks = Directory(root)
        .listSync()
        .whereType<File>()
        .where(
          (f) =>
              p.basename(f.path).startsWith('chunk_') &&
              p.extension(f.path) == '.partial',
        )
        .length;
    for (final chunk in chunks) {
      // Recorder bounds each chunk to 32 known-size payloads.
      if (chunk.lengthSync() > 256 * 1024) {
        throw StateError('research_chunk_too_large');
      }
      final lines = chunk.readAsLinesSync();
      if (lines.isEmpty) throw StateError('research_chunk_incomplete');
      final footer = jsonDecode(lines.last) as Map;
      final body = lines.take(lines.length - 1).toList();
      if (footer['kind'] != 'chunk_end' ||
          footer['records'] != body.length ||
          footer['content_sha256'] !=
              sha256.convert(utf8.encode(body.join('\n'))).toString()) {
        throw StateError('research_chunk_integrity_failed');
      }
      for (final line in body) {
        final row = Map<String, Object?>.from(jsonDecode(line) as Map);
        final hex = row['inner_hex'] as String;
        if (!Whoop4R10Capture.matches(hex, 'gen4', row['packet_type'] as int)) {
          throw StateError('research_record_invalid');
        }
        final decoded = frameAccel(hex);
        final ts = row['record_ts_epoch_s'] as int?;
        final timestampMatches = decoded != null && decoded.ts == ts;
        final accepted =
            row['timestamp_status'] == 'accepted' && timestampMatches;
        final digest = row['payload_sha256'] as String;
        if (!payloads.add(digest)) continue;
        count++;
        if (accepted && ts != null) {
          timestamps.putIfAbsent(ts, () => <String>{}).add(digest);
        }
        write({
          ...row,
          'kind': 'record',
          'decoded_header_ts_epoch_s': decoded?.ts,
          'timestamp_matches_header': timestampMatches,
          'accel_x_lsb': decoded?.xs?.map((v) => v.toInt()).toList(),
          'accel_y_lsb': decoded?.ys?.map((v) => v.toInt()).toList(),
          'accel_z_lsb': decoded?.zs?.map((v) => v.toInt()).toList(),
          'accel_scale_g_per_lsb': 1 / 4096,
          'samples_per_axis': decoded?.mags.length,
          'nominal_sample_rate_hz': 100,
          'sample_rate_status': 'repository_reported_not_measured',
          'decode_error': decoded == null ? 'no_usable_acceleration' : null,
        });
      }
    }
    final seconds =
        timestamps.entries
            .where((e) {
              if (e.value.length > 1) {
                conflicts++;
                return false;
              }
              return true;
            })
            .map((e) => e.key)
            .toList()
          ..sort();
    final gaps = <Map<String, int>>[];
    final runs = <Map<String, int>>[];
    int? first, last;
    for (final ts in seconds) {
      if (last != null && ts != last + 1) {
        runs.add({'first_record_epoch_s': first!, 'last_record_epoch_s': last});
        gaps.add({'from_epoch_s': last + 1, 'to_epoch_s_exclusive': ts});
        first = ts;
      }
      first ??= ts;
      last = ts;
    }
    if (last != null) {
      runs.add({'first_record_epoch_s': first!, 'last_record_epoch_s': last});
    }
    final start = study?['start_epoch_s'] as int?;
    final end = study?['end_epoch_s'] as int?;
    final inStudy = start == null || end == null
        ? null
        : seconds.where((s) => s >= start && s < end).length;
    final deltas = <int, int>{};
    for (var i = 1; i < seconds.length; i++) {
      final delta = seconds[i] - seconds[i - 1];
      deltas.update(delta, (v) => v + 1, ifAbsent: () => 1);
    }
    write({
      'kind': 'manifest',
      ...manifest,
      'incomplete':
          manifest['incomplete'] == true ||
          partialChunks > 0 ||
          count != manifest['records_retained'],
      'retained_record_count_matches_export':
          count == manifest['records_retained'],
      'exported_records': count,
      'partial_chunks_excluded': partialChunks,
      'study_interval': study,
      'coverage': {
        'distinct_trusted_record_seconds': seconds.length,
        'conflicting_record_seconds_excluded': conflicts,
        'contiguous_timestamp_runs': runs,
        'internal_missing_second_ranges': gaps,
        'adjacent_timestamp_delta_counts': {
          for (final e in deltas.entries) e.key.toString(): e.value,
        },
        'study_record_seconds': inStudy,
        'study_timestamp_presence_fraction': start == null || end == null
            ? null
            : inStudy! / (end - start),
        'within_record_timing': 'unverified',
        'continuous_motion_duration_s': null,
        'nominal_samples_per_record': 100,
        'nominal_sample_rate_hz': 100,
        'coverage_interpretation':
            'timestamp_presence_not_proven_sampling_coverage',
      },
      'export_location': 'private_app_cache',
      'no_step_estimate_computed': true,
    });
    sink.flushSync();
    sink.closeSync();
    closed = true;
    partial.renameSync(output.path);
    return output.path;
  } catch (_) {
    try {
      if (!closed) sink.closeSync();
    } finally {
      if (partial.existsSync()) partial.deleteSync();
    }
    rethrow;
  }
}
