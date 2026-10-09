// Measurement probe for the substrate archive: how many bytes a UTC day of
// real decoded substrate costs once encoded, per device family, plus the
// per-column share. Prints numbers only; asserts nothing beyond a lossless
// round trip.
//
// Skips unless OPENSTRAP_TEST_DBS names one or more real exports:
//   OPENSTRAP_TEST_DBS=/path/a.db,/path/b.db \
//     flutter test test/substrate_archive_size_probe_test.dart
// Every source is opened READ-ONLY.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/substrate_archive_codec.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final real = (Platform.environment['OPENSTRAP_TEST_DBS'] ?? '')
      .split(',')
      .where((s) => s.trim().isNotEmpty)
      .toList();
  if (real.isEmpty) {
    test(
      'substrate archive size probe',
      () {},
      skip: 'set OPENSTRAP_TEST_DBS to measure real exports',
    );
    return;
  }
  sqfliteFfiInit();
  for (final src in real) {
    test(
      'bytes/day over ${p.basename(src)}',
      () async {
        final db = await databaseFactoryFfi.openDatabase(
          src,
          options: OpenDatabaseOptions(readOnly: true),
        );
        try {
          final buckets = await db.rawQuery(
            'SELECT device_id, rec_ts / 86400 AS d FROM decoded_onehz '
            'WHERE rec_ts > 0 UNION '
            'SELECT device_id, rec_ts / 86400 AS d FROM decoded_rr '
            'WHERE rec_ts > 0 ORDER BY d, device_id',
          );
          final colBytes = <String, int>{};
          var fullDays = 0, fullBytes = 0;
          for (final b in buckets) {
            final dev = b['device_id'] as String;
            final d = (b['d'] as num).toInt();
            final args = [dev, d * 86400, (d + 1) * 86400];
            const w = 'device_id = ? AND rec_ts >= ? AND rec_ts < ?';
            final onehz = ArchiveTableBuilder()
              ..addRows(
                await db.rawQuery('SELECT * FROM decoded_onehz WHERE $w', args),
              );
            final rr = ArchiveTableBuilder()
              ..addRows(
                await db.rawQuery('SELECT * FROM decoded_rr WHERE $w', args),
              );
            final bucket = SubstrateArchiveCodec.merge(
              ArchiveBucket(onehz.build(), rr.build()),
              ArchiveBucket.empty,
            );
            final out = SubstrateArchiveCodec.encodeMergeVerify(bucket);
            final family = bucket.onehz.rowCount == 0
                ? '?'
                : '${bucket.onehz.valueAt('device_family', 0)}';
            // ignore: avoid_print
            print(
              '${p.basename(src)} dev="$dev" utc_day=$d family=$family '
              'onehz=${out.onehzRows} rr=${out.rrRows} '
              'raw=${out.rawBytes} blob=${out.blob.length}',
            );
            if (out.onehzRows < 80000) continue; // partial day: not a bytes/day
            fullDays++;
            fullBytes += out.blob.length;
            for (final (tag, t) in [
              ('onehz', bucket.onehz),
              ('rr', bucket.rr),
            ]) {
              for (final e in t.columns.entries) {
                final only = ArchiveTable(t.rowCount, {e.key: e.value});
                final size = SubstrateArchiveCodec.encode(
                  tag == 'onehz'
                      ? ArchiveBucket(only, ArchiveTable.empty)
                      : ArchiveBucket(ArchiveTable.empty, only),
                ).length;
                colBytes['$tag.${e.key}'] =
                    (colBytes['$tag.${e.key}'] ?? 0) + size;
              }
            }
          }
          if (fullDays > 0) {
            // ignore: avoid_print
            print(
              '${p.basename(src)}: $fullDays full days, '
              '${(fullBytes / fullDays / 1024).toStringAsFixed(0)} KB/day',
            );
            final cols = colBytes.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value));
            for (final c in cols) {
              // ignore: avoid_print
              print(
                '  ${c.key}: ${(c.value / fullDays / 1024).toStringAsFixed(1)} '
                'KB/day',
              );
            }
          }
        } finally {
          await db.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 30)),
    );
  }
}
