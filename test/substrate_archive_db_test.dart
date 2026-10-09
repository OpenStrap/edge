// The substrate archive end to end over the REAL LocalDb (sqflite_common_ffi):
// archive-then-delete on prune, late-row merge, verify-before-delete, the
// policy, eviction, and every other owner of the decoded tables (delete day,
// export day, restore/salvage, schema health, the prune guard).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/auto_backup.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/substrate_archive.dart';
import 'package:openstrap_edge/data/substrate_archive_codec.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

// A UTC-midnight-aligned base, so day N is exactly bucket d0 + N.
const int _d0 = 1900000000 ~/ 86400 * 86400;
const int _day = 86400;
const int _step = 600; // one row every 10 min keeps the test fast
const String _ring = 'ring-TEST';

Map<String, Object?> _gen4(int ts, {int hr = 60}) => {
  'device_id': '',
  'ts_ms': ts * 1000,
  'rec_ts': ts,
  'counter': ts - _d0,
  'hr': hr,
  'ax': 0.015625 * (ts % 7),
  'ay': -0.5,
  'az': 0.984375,
  'spo2_red_raw': 51000 + ts % 13,
  'spo2_ir_raw': 62000 + ts % 11,
  'skin_temp_raw': 1200 + ts % 5,
  'ambient_raw': 300,
  'device_family': 'gen4',
};

Map<String, Object?> _gen5(int ts) => {
  'device_id': _ring,
  'ts_ms': ts * 1000,
  'rec_ts': ts,
  'counter': ts - _d0,
  'hr': 55 + ts % 9,
  'step_count': (ts ~/ _step) % 3 == 0 ? null : ts % 40,
  'step_cadence': 0,
  'activity_class': 1,
  'skin_temp_c': 33.1 + (ts % 4) / 10,
  'temp_ch2_c': 31.7,
  'signal_quality_logvar': -2.3456789,
  'dyn_accel_g': 0.001,
  'device_family': 'gen5',
  'source': 'test',
};

Map<String, Object?> _beat(String dev, int ts, int i, int rr) => {
  'device_id': dev,
  'ts_ms': ts * 1000,
  'rec_ts': ts,
  'beat_index': i,
  'rr_ts_ms': ts * 1000,
  'rr_ms': rr,
  'beat_ts_ms': dev.isEmpty ? ts * 1000 + 100 * i : null,
};

Future<Database> _db() => LocalDb.instance;

Future<void> _clear() async {
  final db = await _db();
  for (final t in [
    'decoded_onehz',
    'decoded_rr',
    'substrate_archive',
    'compute_freshness',
  ]) {
    await db.delete(t);
  }
  SubstrateArchive.debugCorruptEncode = false;
  SubstrateArchive.debugBeforeBucket = null;
  SubstrateArchive.debugThrowInBucket = null;
  SubstrateArchive.debugBeforeFallbackDelete = null;
  LocalDb.debugFailExportStrip = false;
}

/// Beats at one second of one device, in beat order.
Future<List<Object?>> _archivedBeatsAt(String dev, int ts) async {
  final (_, rr) = await _archived();
  final beats =
      rr.values
          .where((r) => r['device_id'] == dev && r['ts_ms'] == ts * 1000)
          .toList()
        ..sort(
          (a, b) => (a['beat_index'] as int).compareTo(b['beat_index'] as int),
        );
  return [for (final b in beats) b['rr_ms']];
}

/// What a live re-write of second [ts] does: REPLACE the 1 Hz row and clear
/// that second's beats (see `_queueRrBeats`), then write [beats].
Future<void> _rewriteLive(
  int ts, {
  int hr = 60,
  List<int> beats = const [],
}) async {
  final db = await _db();
  await db.insert(
    'decoded_onehz',
    _gen4(ts, hr: hr),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  await db.delete(
    'decoded_rr',
    where: "device_id = '' AND ts_ms = ?",
    whereArgs: [ts * 1000],
  );
  for (final (i, rr) in beats.indexed) {
    await db.insert('decoded_rr', _beat('', ts, i, rr));
  }
}

/// Import [exportPath] into a FRESH database, archive everything there, and
/// return that database's archive — the end-to-end answer to "what does the
/// export carry, once the merge rules have run on the importing device?".
Future<(Map<String, Map<String, Object?>>, Map<String, Map<String, Object?>>)>
_roundTrip(String exportPath) async {
  final home = LocalDb.dbName;
  await LocalDb.close();
  LocalDb.dbName = 'openstrap_substrate_archive_roundtrip.db';
  final path = p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName);
  await databaseFactory.deleteDatabase(path);
  try {
    await LocalDb.importFromDbFile(exportPath);
    await LocalDb.pruneDecodedBeforeRecTs(
      _d0 + 30 * _day,
      archive: const SubstrateArchivePolicy(365),
    );
    return await _archived();
  } finally {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(path);
    LocalDb.dbName = home;
  }
}

Future<void> _threeBeatsAt(int ts) async {
  final db = await _db();
  for (var i = 0; i < 3; i++) {
    await db.insert(
      'decoded_rr',
      _beat('', ts, i, 700 + 10 * i),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

/// 3 UTC days for both devices, beat-only seconds, and one rec_ts = 0 row.
Future<void> _seed() async {
  final db = await _db();
  final batch = db.batch();
  for (var ts = _d0; ts < _d0 + 3 * _day; ts += _step) {
    batch.insert('decoded_onehz', _gen4(ts));
    batch.insert('decoded_onehz', _gen5(ts + 1));
    batch.insert('decoded_rr', _beat('', ts, 0, 900 + ts % 50));
    batch.insert('decoded_rr', _beat('', ts, 1, 910 + ts % 50));
    batch.insert('decoded_rr', _beat(_ring, ts + 1, 0, 1000));
  }
  // Beat-only seconds: R-R with no 1 Hz parent (gen4 history can do this).
  for (final ts in [_d0 + 301, _d0 + _day + 301]) {
    batch.insert('decoded_rr', _beat('', ts, 0, 777));
  }
  batch.insert('decoded_onehz', {..._gen4(0), 'ts_ms': 0, 'counter': 0});
  await batch.commit(noResult: true);
}

Future<List<Map<String, Object?>>> _live(
  String t,
  String where,
  List<Object?> args,
) async => (await _db()).rawQuery('SELECT * FROM $t WHERE $where', args);

String _key(Map<String, Object?> r) =>
    '${r['device_id']}|${r['ts_ms']}|${r['beat_index']}';

/// Every archived row, keyed like the live tables.
Future<(Map<String, Map<String, Object?>>, Map<String, Map<String, Object?>>)>
_archived() async {
  final onehz = <String, Map<String, Object?>>{};
  final rr = <String, Map<String, Object?>>{};
  for (final row in await (await _db()).query('substrate_archive')) {
    final b = SubstrateArchiveCodec.decode(
      row['blob'] as Uint8List,
      codec: row['codec'] as int,
    )!;
    for (var i = 0; i < b.onehz.rowCount; i++) {
      final r = b.onehz.rowAt(i);
      onehz[_key(r)] = r;
    }
    for (var i = 0; i < b.rr.rowCount; i++) {
      final r = b.rr.rowAt(i);
      rr[_key(r)] = r;
    }
  }
  return (onehz, rr);
}

void _expectSameRows(
  List<Map<String, Object?>> live,
  Map<String, Map<String, Object?>> archived,
) {
  expect(archived.length, live.length);
  for (final r in live) {
    final a = archived[_key(r)];
    expect(a, isNotNull, reason: 'missing ${_key(r)}');
    for (final e in r.entries) {
      expect(a![e.key], e.value, reason: '${_key(r)}.${e.key}');
      expect(a[e.key].runtimeType, e.value.runtimeType);
    }
  }
}

void main() {
  late Directory tmp;
  final policy = const SubstrateArchivePolicy(365);
  const cutoff = _d0 + 2 * _day; // start of day 3

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('openstrap_substrate_archive_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    LocalDb.dbName = 'openstrap_substrate_archive_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  setUp(_clear);

  Future<bool> hasArchiveTable() async => (await (await _db()).rawQuery(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' "
    "AND name = 'substrate_archive'",
  )).isNotEmpty;

  test(
    'a fresh database and a reopened existing one both have the table',
    () async {
      expect(await hasArchiveTable(), isTrue, reason: 'fresh install');
      // An existing install at the same schema version that predates the
      // table: the every-open repair pass must create it.
      await (await _db()).execute('DROP TABLE substrate_archive');
      expect(await hasArchiveTable(), isFalse);
      await LocalDb.close();
      expect(await hasArchiveTable(), isTrue, reason: 'reopened install');
    },
  );

  test('schemaHealth requires substrate_archive', () async {
    expect((await LocalDb.schemaHealth())['ok'], isTrue);
    await (await _db()).execute('DROP TABLE substrate_archive');
    final health = await LocalDb.schemaHealth();
    expect(health['missing_tables'], contains('substrate_archive'));
    await LocalDb.close(); // reopen repairs it for the remaining tests
    expect(await hasArchiveTable(), isTrue);
  });

  test('restore/salvage lists include substrate_archive', () {
    expect(LocalDb.restoreTablesForTest, contains('substrate_archive'));
    expect(LocalDb.salvageTablesForTest, contains('substrate_archive'));
  });

  test('archives every pruned row and deletes exactly those', () async {
    await _seed();
    final liveOnehz = await _live(
      'decoded_onehz',
      'rec_ts > 0 AND rec_ts < ?',
      [cutoff],
    );
    final liveRr = await _live('decoded_rr', 'rec_ts > 0 AND rec_ts < ?', [
      cutoff,
    ]);
    final keptOnehz = await _live('decoded_onehz', 'rec_ts >= ?', [cutoff]);

    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);

    expect(
      await _live('decoded_onehz', 'rec_ts < ?', [cutoff]),
      isEmpty,
      reason: 'including the rec_ts = 0 row',
    );
    expect(await _live('decoded_rr', 'rec_ts < ?', [cutoff]), isEmpty);
    expect(
      await _live('decoded_onehz', 'rec_ts >= ?', [cutoff]),
      hasLength(keptOnehz.length),
    );
    final buckets = await (await _db()).query(
      'substrate_archive',
      orderBy: 'utc_day, device_id',
    );
    expect(
      [for (final b in buckets) '${b['device_id']}/${b['utc_day']}'],
      [
        '/${_d0 ~/ _day}',
        '$_ring/${_d0 ~/ _day}',
        '/${_d0 ~/ _day + 1}',
        '$_ring/${_d0 ~/ _day + 1}',
      ],
    );
    final (onehz, rr) = await _archived();
    _expectSameRows(liveOnehz, onehz);
    _expectSameRows(liveRr, rr);
    expect(onehz.keys.where((k) => k.startsWith('|0|')), isEmpty);
    // A gen5 NULL step count is still NULL, never 0.
    expect(
      onehz.values.where(
        (r) => r['device_id'] == _ring && r['step_count'] == null,
      ),
      isNotEmpty,
    );
  });

  test('the default policy archives when no policy is passed', () async {
    expect(
      await LocalDb.substrateArchivePolicy(),
      SubstrateArchivePolicy.defaults,
    );
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff);
    expect(await (await _db()).query('substrate_archive'), hasLength(4));
  });

  test('late rows merge into an existing bucket', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final before = await (await _db()).query(
      'substrate_archive',
      where: "device_id = '' AND utc_day = ?",
      whereArgs: [_d0 ~/ _day],
    );
    final origRows = before.single['onehz_rows'] as int;

    final db = await _db();
    final batch = db.batch();
    for (var i = 0; i < 10; i++) {
      batch.insert('decoded_onehz', _gen4(_d0 + i * _step, hr: 150));
    }
    for (var i = 0; i < 5; i++) {
      batch.insert('decoded_onehz', _gen4(_d0 + i * _step + 7, hr: 99));
    }
    await batch.commit(noResult: true);
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);

    final after = await db.query(
      'substrate_archive',
      where: "device_id = '' AND utc_day = ?",
      whereArgs: [_d0 ~/ _day],
    );
    expect(after, hasLength(1));
    expect(after.single['onehz_rows'], origRows + 5);
    expect(after.single['created_at'], before.single['created_at']);
    final (onehz, _) = await _archived();
    for (var i = 0; i < 10; i++) {
      expect(onehz['|${(_d0 + i * _step) * 1000}|null']!['hr'], 150);
    }
    expect(onehz['|${(_d0 + 7) * 1000}|null']!['hr'], 99);
    expect(await _live('decoded_onehz', 'rec_ts < ?', [cutoff]), isEmpty);
  });

  test('verify failure keeps rows live inside the hold window and deletes '
      'past hardFloorSec', () async {
    await _seed();
    final liveBefore = await _live(
      'decoded_onehz',
      'rec_ts > 0 AND rec_ts < ?',
      [cutoff],
    );
    SubstrateArchive.debugCorruptEncode = true;
    final logs = <String>[];
    await LocalDb.pruneDecodedBeforeRecTs(
      cutoff,
      archive: policy,
      hardFloorSec: _d0, // every bucket is still inside the hold
      log: logs.add,
    );
    expect(
      await _live('decoded_onehz', 'rec_ts > 0 AND rec_ts < ?', [cutoff]),
      hasLength(liveBefore.length),
    );
    expect(await (await _db()).query('substrate_archive'), isEmpty);
    expect(logs, hasLength(4));
    expect(logs.first, contains('kept live'));

    // Past the bounded hold the old behaviour applies: deleted unarchived.
    await LocalDb.pruneDecodedBeforeRecTs(
      cutoff,
      archive: policy,
      hardFloorSec: cutoff,
    );
    expect(await _live('decoded_onehz', 'rec_ts < ?', [cutoff]), isEmpty);
    expect(await _live('decoded_rr', 'rec_ts < ?', [cutoff]), isEmpty);
    expect(await (await _db()).query('substrate_archive'), isEmpty);
  });

  test('policy off ⇒ legacy behaviour', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(
      cutoff,
      archive: const SubstrateArchivePolicy(0),
    );
    expect(await _live('decoded_onehz', 'rec_ts < ?', [cutoff]), isEmpty);
    expect(await _live('decoded_rr', 'rec_ts < ?', [cutoff]), isEmpty);
    expect(await (await _db()).query('substrate_archive'), isEmpty);
  });

  test('evictSubstrateArchive drops buckets older than keepDays; -1 keeps '
      'all; setting the policy to 0 purges', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final db = await _db();
    expect(
      await LocalDb.evictSubstrateArchive(
        const SubstrateArchivePolicy(-1),
        cutoff + 10 * _day,
      ),
      0,
    );
    // keepDays 1 behind day 2 keeps day 1 and drops day 0.
    expect(
      await LocalDb.evictSubstrateArchive(
        const SubstrateArchivePolicy(1),
        cutoff + 3600,
      ),
      2,
    );
    final left = await db.query('substrate_archive', columns: ['utc_day']);
    expect({for (final r in left) r['utc_day']}, {_d0 ~/ _day + 1});

    await LocalDb.setSubstrateArchivePolicy(const SubstrateArchivePolicy(0));
    expect(await db.query('substrate_archive'), isEmpty);
    expect(
      await LocalDb.substrateArchivePolicy(),
      const SubstrateArchivePolicy(0),
    );
  });

  test(
    'deleteDays removes archived seconds in the local window only',
    () async {
      await _seed();
      await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
      final (onehzBefore, rrBefore) = await _archived();
      // The local day containing the middle of UTC day 1.
      final label = dayLabelOf(
        DateTime.fromMillisecondsSinceEpoch((_d0 + _day + _day ~/ 2) * 1000),
      );
      final start = localDayStartSec(label)!;
      final end = localDayEndSec(label)!;
      bool inWindow(Map<String, Object?> r) {
        final ts = r['rec_ts'] as int;
        return ts >= start && ts < end;
      }

      await LocalDb.deleteDays({label});
      final (onehz, rr) = await _archived();
      expect(onehz.values.where(inWindow), isEmpty);
      expect(rr.values.where(inWindow), isEmpty);
      expect(
        onehz.length,
        onehzBefore.values.where((r) => !inWindow(r)).length,
      );
      expect(rr.length, rrBefore.values.where((r) => !inWindow(r)).length);
    },
  );

  test('deleteRanges edits a partially-covered bucket and drops a covered '
      'one', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final db = await _db();
    // Mid-bucket window inside day 0, whole-bucket window over day 1.
    const a = (_d0 + 3600, _d0 + 7200);
    const b = (_d0 + _day, _d0 + 2 * _day);
    await db.transaction(
      (txn) => SubstrateArchive.deleteRanges(txn, const [a, b]),
    );
    final (onehz, _) = await _archived();
    expect(
      onehz.values.where((r) {
        final ts = r['rec_ts'] as int;
        return (ts >= a.$1 && ts < a.$2) || ts >= b.$1;
      }),
      isEmpty,
    );
    // Neighbours either side of the mid-bucket window survive.
    expect(onehz.containsKey('|${(_d0 + 3000) * 1000}|null'), isTrue);
    expect(onehz.containsKey('|${(_d0 + 7200) * 1000}|null'), isTrue);
    expect(
      await db.query(
        'substrate_archive',
        where: 'utc_day = ?',
        whereArgs: [_d0 ~/ _day + 1],
      ),
      isEmpty,
    );
  });

  test('deleteRanges: touching windows that together cover a bucket drop it '
      'without a decode', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final db = await _db();
    // Any rewrite would throw: a whole drop is the only way this passes.
    SubstrateArchive.debugCorruptEncode = true;
    await db.transaction(
      (txn) => SubstrateArchive.deleteRanges(txn, const [
        // Neither window alone contains bucket 1; together they do, and
        // neither reaches the neighbouring buckets.
        (_d0 + _day + 3600, _d0 + 2 * _day),
        (_d0 + _day, _d0 + _day + 3600),
      ]),
    );
    SubstrateArchive.debugCorruptEncode = false;
    expect(
      await db.query(
        'substrate_archive',
        where: 'utc_day = ?',
        whereArgs: [_d0 ~/ _day + 1],
      ),
      isEmpty,
    );
  });

  test('exportDaysDb carries exactly the selected days\' archived seconds, '
      'compact, bit-identical after a round trip', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final (onehz, rr) = await _archived();
    final label = dayLabelOf(
      DateTime.fromMillisecondsSinceEpoch((_d0 + _day ~/ 2) * 1000),
    );
    final start = localDayStartSec(label)!;
    final end = localDayEndSec(label)!;
    bool inWindow(Map<String, Object?> r) {
      final ts = r['rec_ts'] as int;
      return ts >= start && ts < end;
    }

    final path = await LocalDb.exportDaysDb({label});
    try {
      // Compact in the file: buckets, not expanded rows.
      final out = await databaseFactory.openDatabase(path);
      final buckets = await out.query('substrate_archive');
      expect(buckets, isNotEmpty);
      expect(await out.query('decoded_onehz'), isEmpty);
      await out.close();

      final (gotOnehz, gotRr) = await _roundTrip(path);
      _expectSameRows(onehz.values.where(inWindow).toList(), gotOnehz);
      _expectSameRows(rr.values.where(inWindow).toList(), gotRr);
    } finally {
      await File(path).delete();
    }
  });

  test(
    'exportDaysDb fails loudly on an archive bucket it cannot read',
    () async {
      await _seed();
      await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
      await (await _db()).update('substrate_archive', {'codec': 99});
      final label = dayLabelOf(
        DateTime.fromMillisecondsSinceEpoch((_d0 + _day ~/ 2) * 1000),
      );
      await expectLater(LocalDb.exportDaysDb({label}), throwsStateError);
    },
  );

  test('restore merges substrate_archive with local winning', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final db = await _db();
    final snapshot = await LocalDb.exportCopy();
    // Doctor the copy: one bucket gets a different hr for a second the local
    // archive has, plus seconds the local archive does not have.
    final copy = await databaseFactory.openDatabase(snapshot);
    final key = ['', _d0 ~/ _day];
    final row = (await copy.query(
      'substrate_archive',
      where: 'device_id = ? AND utc_day = ?',
      whereArgs: key,
    )).single;
    final b = SubstrateArchiveCodec.decode(row['blob'] as Uint8List)!;
    final foreign = ArchiveBucket(
      (ArchiveTableBuilder()..addRows([
            {..._gen4(_d0), 'hr': 1},
            _gen4(_d0 + 5),
            _gen4(_d0 + 6),
          ]))
          .build(),
      ArchiveTable.empty,
    );
    final w = SubstrateArchiveCodec.encodeMergeVerify(
      foreign,
      existing: SubstrateArchiveCodec.encode(b),
    );
    await copy.update(
      'substrate_archive',
      {'blob': w.blob, 'onehz_rows': w.onehzRows, 'fingerprint': w.fingerprint},
      where: 'device_id = ? AND utc_day = ?',
      whereArgs: key,
    );
    await copy.close();
    // And a bucket the local archive lost entirely comes back whole.
    await db.delete(
      'substrate_archive',
      where: 'device_id = ? AND utc_day = ?',
      whereArgs: [_ring, _d0 ~/ _day],
    );

    await LocalDb.importFromDbFile(snapshot);
    await File(snapshot).delete();

    final (onehz, _) = await _archived();
    expect(onehz['|${_d0 * 1000}|null']!['hr'], 60, reason: 'local wins');
    expect(onehz.containsKey('|${(_d0 + 5) * 1000}|null'), isTrue);
    expect(onehz.containsKey('|${(_d0 + 6) * 1000}|null'), isTrue);
    expect(
      await db.query(
        'substrate_archive',
        where: 'device_id = ? AND utc_day = ?',
        whereArgs: [_ring, _d0 ~/ _day],
      ),
      hasLength(1),
    );
  });

  test('decodedRecTsMaxByDay ignores the archive', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final cutoffLabel = dayLabelOf(
      DateTime.fromMillisecondsSinceEpoch(cutoff * 1000),
    );
    final days = await LocalDb.decodedRecTsMaxByDay();
    expect(days, isNotEmpty);
    for (final d in days.keys) {
      expect(d.compareTo(cutoffLabel), greaterThanOrEqualTo(0), reason: d);
    }
    for (final mx in days.values) {
      expect(mx, greaterThanOrEqualTo(cutoff));
    }
  });

  test('substrateArchiveStats reports buckets and bytes', () async {
    expect((await LocalDb.substrateArchiveStats())['buckets'], 0);
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final s = await LocalDb.substrateArchiveStats();
    expect(s['buckets'], 4);
    expect(s['bytes'] as int, greaterThan(0));
    expect(s['raw_bytes'] as int, greaterThan(0));
    expect(s['oldest_from_ts'], _d0);
  });

  group('R-R: a re-written second owns its whole beat set', () {
    const x = _d0 + 1200;

    test('prune merge: 3 archived beats re-written to 0 stay 0', () async {
      await _seed();
      await _threeBeatsAt(x);
      await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
      expect(await _archivedBeatsAt('', x), [700, 710, 720]);
      await _rewriteLive(x, hr: 88);
      await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
      expect(await _archivedBeatsAt('', x), isEmpty);
      final (onehz, _) = await _archived();
      expect(onehz['|${x * 1000}|null']!['hr'], 88);
    });

    test('restore: incoming beats never come back over a local second '
        'that has none', () async {
      await _seed();
      await _rewriteLive(x); // local: 1 Hz row, zero beats
      await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
      expect(await _archivedBeatsAt('', x), isEmpty);
      final snapshot = await LocalDb.exportCopy();
      final copy = await databaseFactory.openDatabase(snapshot);
      final key = ['', _d0 ~/ _day];
      final row = (await copy.query(
        'substrate_archive',
        where: 'device_id = ? AND utc_day = ?',
        whereArgs: key,
      )).single;
      final w = SubstrateArchiveCodec.encodeMergeVerify(
        ArchiveBucket(
          ArchiveTable.empty,
          (ArchiveTableBuilder()..addRows([
                for (var i = 0; i < 3; i++) _beat('', x, i, 700 + 10 * i),
              ]))
              .build(),
        ),
        existing: row['blob'] as Uint8List,
      );
      await copy.update(
        'substrate_archive',
        {'blob': w.blob, 'rr_rows': w.rrRows, 'fingerprint': w.fingerprint},
        where: 'device_id = ? AND utc_day = ?',
        whereArgs: key,
      );
      await copy.close();
      await LocalDb.importFromDbFile(snapshot);
      await File(snapshot).delete();
      expect(await _archivedBeatsAt('', x), isEmpty);
    });

    test(
      'export: a live second with 0 beats takes none from the archive',
      () async {
        await _seed();
        await _threeBeatsAt(x);
        await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
        await _rewriteLive(x, hr: 88); // late live row, no beats
        final label = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(x * 1000));
        final path = await LocalDb.exportDaysDb({label});
        try {
          final (onehz, rr) = await _roundTrip(path);
          expect(onehz['|${x * 1000}|null']!['hr'], 88, reason: 'live wins');
          expect(rr.values.where((r) => r['ts_ms'] == x * 1000), isEmpty);
        } finally {
          await File(path).delete();
        }
      },
    );

    test('export: live beat-only rows win over archived beats, and never '
        'erase the archived 1 Hz row', () async {
      await _seed();
      await _threeBeatsAt(x);
      await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
      final archived1Hz = (await _archived()).$1['|${x * 1000}|null']!;
      // A re-delivered beat-only (gen4 R10-lite) second, no 1 Hz parent.
      await (await _db()).insert('decoded_rr', _beat('', x, 0, 555));
      // And a beat-only second the archive never had.
      await (await _db()).insert('decoded_rr', _beat('', x + 7, 0, 444));
      final label = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(x * 1000));
      final path = await LocalDb.exportDaysDb({label});
      try {
        final (onehz, rr) = await _roundTrip(path);
        List<Object?> beats(int ts) => [
          for (final r in rr.values.where((r) => r['ts_ms'] == ts * 1000))
            r['rr_ms'],
        ];
        expect(beats(x), [555]);
        expect(beats(x + 7), [444]);
        // The beat-only record carries no HR or accel: the archived 1 Hz row
        // for that second survives the trip, every column of it.
        final row = onehz['|${x * 1000}|null']!;
        for (final e in archived1Hz.entries) {
          expect(row[e.key], e.value, reason: e.key);
        }
      } finally {
        await File(path).delete();
      }
    });
  });

  test('deleteRanges: an unreadable bucket overlapping the window goes '
      'whole (documented trade-off)', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final db = await _db();
    await db.update(
      'substrate_archive',
      {'codec': 99},
      where: "device_id = '' AND utc_day = ?",
      whereArgs: [_d0 ~/ _day],
    );
    await db.transaction(
      (txn) =>
          SubstrateArchive.deleteRanges(txn, const [(_d0 + 3600, _d0 + 7200)]),
    );
    final left = await db.query(
      'substrate_archive',
      where: 'utc_day = ?',
      whereArgs: [_d0 ~/ _day],
    );
    expect([for (final r in left) r['device_id']], [_ring]);
  });

  test('deleteDays: a failed rewrite rolls back and throws, neighbours and '
      'live rows intact', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final db = await _db();
    final label = dayLabelOf(
      DateTime.fromMillisecondsSinceEpoch((_d0 + _day + _day ~/ 2) * 1000),
    );
    final start = localDayStartSec(label)!;
    final end = localDayEndSec(label)!;
    // A bucket whose seconds straddle that local day, in any timezone, so
    // deleting the day has to REWRITE it rather than drop it whole.
    final w = SubstrateArchiveCodec.encodeMergeVerify(
      ArchiveBucket(
        (ArchiveTableBuilder()..addRows([
              for (final ts in [start - 10, start + 10, end + 10])
                {..._gen4(ts), 'device_id': 'probe'},
            ]))
            .build(),
        ArchiveTable.empty,
      ),
    );
    await db.insert('substrate_archive', {
      'device_id': 'probe',
      'utc_day': start ~/ _day,
      'codec': SubstrateArchiveCodec.codecId,
      'from_ts': w.fromTs,
      'to_ts': w.toTs,
      'onehz_rows': w.onehzRows,
      'rr_rows': w.rrRows,
      'raw_bytes': w.rawBytes,
      'fingerprint': w.fingerprint,
      'blob': w.blob,
      'created_at': 1,
      'updated_at': 1,
    });
    final before = await db.query('substrate_archive', orderBy: 'rowid');
    final liveBefore = await db.query('decoded_onehz');

    SubstrateArchive.debugCorruptEncode = true;
    await expectLater(LocalDb.deleteDays({label}), throwsStateError);
    SubstrateArchive.debugCorruptEncode = false;

    final after = await db.query('substrate_archive', orderBy: 'rowid');
    expect(after.length, before.length);
    for (var i = 0; i < after.length; i++) {
      expect(after[i]['fingerprint'], before[i]['fingerprint']);
    }
    expect(await db.query('decoded_onehz'), hasLength(liveBefore.length));

    // And without the fault the same delete goes through, keeping the
    // probe's seconds outside the day.
    await LocalDb.deleteDays({label});
    final probe = (await db.query(
      'substrate_archive',
      where: "device_id = 'probe'",
    )).single;
    final b = SubstrateArchiveCodec.decode(probe['blob'] as Uint8List)!;
    expect(
      [for (var i = 0; i < b.onehz.rowCount; i++) b.onehz.valueAt('rec_ts', i)],
      [start - 10, end + 10],
    );
  });

  group('restore', () {
    Future<String> doctoredSnapshot({required int codec}) async {
      final snapshot = await LocalDb.exportCopy();
      final copy = await databaseFactory.openDatabase(snapshot);
      final key = ['', _d0 ~/ _day];
      final row = (await copy.query(
        'substrate_archive',
        where: 'device_id = ? AND utc_day = ?',
        whereArgs: key,
      )).single;
      final w = SubstrateArchiveCodec.encodeMergeVerify(
        ArchiveBucket(
          (ArchiveTableBuilder()..addRows([_gen4(_d0 + 5)])).build(),
          ArchiveTable.empty,
        ),
        existing: row['blob'] as Uint8List,
      );
      await copy.update(
        'substrate_archive',
        {'blob': w.blob, 'fingerprint': w.fingerprint, 'codec': codec},
        where: 'device_id = ? AND utc_day = ?',
        whereArgs: key,
      );
      await copy.close();
      return snapshot;
    }

    test(
      'a failing merge fails the restore instead of reporting success',
      () async {
        await _seed();
        await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
        final before = await _archived();
        final snapshot = await doctoredSnapshot(codec: 1);
        SubstrateArchive.debugCorruptEncode = true;
        await expectLater(LocalDb.importFromDbFile(snapshot), throwsStateError);
        SubstrateArchive.debugCorruptEncode = false;
        await File(snapshot).delete();
        expect((await _archived()).$1.length, before.$1.length);
      },
    );

    test(
      'an unknown incoming codec is skipped and counted, local kept',
      () async {
        await _seed();
        await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
        final before = await _archived();
        final snapshot = await doctoredSnapshot(codec: 99);
        final counts = await LocalDb.importFromDbFile(snapshot);
        await File(snapshot).delete();
        expect(counts['_substrate_archive_skipped'], 1);
        final after = await _archived();
        expect(after.$1.length, before.$1.length);
        expect(after.$1.containsKey('|${(_d0 + 5) * 1000}|null'), isFalse);
      },
    );

    test('a bucket in an unknown codec never enters the table, even when the '
        'key is new here', () async {
      await _seed();
      await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
      final snapshot = await doctoredSnapshot(codec: 99);
      final db = await _db();
      await db.delete(
        'substrate_archive',
        where: "device_id = '' AND utc_day = ?",
        whereArgs: [_d0 ~/ _day],
      );
      final counts = await LocalDb.importFromDbFile(snapshot);
      await File(snapshot).delete();
      expect(counts['_substrate_archive_skipped'], 1);
      expect(await db.query('substrate_archive', where: 'codec != 1'), isEmpty);
    });

    test(
      'a damaged blob fails the restore instead of entering the table',
      () async {
        await _seed();
        await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
        final snapshot = await LocalDb.exportCopy();
        final copy = await databaseFactory.openDatabase(snapshot);
        final key = ['', _d0 ~/ _day];
        final blob = Uint8List.fromList(
          (await copy.query(
                'substrate_archive',
                where: 'device_id = ? AND utc_day = ?',
                whereArgs: key,
              )).single['blob']
              as Uint8List,
        );
        blob[blob.length ~/ 2] ^= 0xFF;
        await copy.update(
          'substrate_archive',
          {'blob': blob},
          where: 'device_id = ? AND utc_day = ?',
          whereArgs: key,
        );
        await copy.close();
        final db = await _db();
        await db.delete(
          'substrate_archive',
          where: 'device_id = ? AND utc_day = ?',
          whereArgs: key,
        );
        await expectLater(LocalDb.importFromDbFile(snapshot), throwsStateError);
        await File(snapshot).delete();
        expect(
          await db.query(
            'substrate_archive',
            where: 'device_id = ? AND utc_day = ?',
            whereArgs: key,
          ),
          isEmpty,
        );
      },
    );

    test('the retention policy comes back when none exists locally, and a '
        'local one wins', () async {
      await _seed();
      await LocalDb.setSubstrateArchivePolicy(const SubstrateArchivePolicy(-1));
      await LocalDb.pruneDecodedBeforeRecTs(cutoff);
      final snapshot = await LocalDb.exportCopy();
      final db = await _db();
      // A fresh phone: no policy row and no archive of its own.
      await db.delete(
        'compute_freshness',
        where: 'key = ?',
        whereArgs: [SubstrateArchive.policyKey],
      );
      await db.delete('substrate_archive');
      await LocalDb.importFromDbFile(snapshot);
      expect(
        await LocalDb.substrateArchivePolicy(),
        const SubstrateArchivePolicy(-1),
      );
      expect(await db.query('substrate_archive'), hasLength(4));
      await LocalDb.setSubstrateArchivePolicy(const SubstrateArchivePolicy(30));
      await LocalDb.importFromDbFile(snapshot);
      await File(snapshot).delete();
      expect(
        await LocalDb.substrateArchivePolicy(),
        const SubstrateArchivePolicy(30),
      );
    });
  });

  test('a backup\'s Off policy never deletes this phone\'s archive; on a '
      'fresh phone it is adopted', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff); // implicit default
    final withBuckets = await LocalDb.exportCopy();
    await LocalDb.setSubstrateArchivePolicy(const SubstrateArchivePolicy(0));
    final offBackup = await LocalDb.exportCopy();
    // Back to: no policy row (implicit default) and four archived buckets.
    final db = await _db();
    await db.delete(
      'compute_freshness',
      where: 'key = ?',
      whereArgs: [SubstrateArchive.policyKey],
    );
    await LocalDb.importFromDbFile(withBuckets);
    expect(await db.query('substrate_archive'), hasLength(4));

    // Importing an Off backup over local history: history kept, the local
    // (default) policy kept, nothing adopted.
    await LocalDb.importFromDbFile(offBackup);
    expect(await db.query('substrate_archive'), hasLength(4));
    expect(
      await db.query(
        'compute_freshness',
        where: 'key = ?',
        whereArgs: [SubstrateArchive.policyKey],
      ),
      isEmpty,
    );

    // A fresh phone adopts it — and then takes no archive rows in.
    await db.delete('substrate_archive');
    await LocalDb.importFromDbFile(offBackup);
    expect(
      await LocalDb.substrateArchivePolicy(),
      const SubstrateArchivePolicy(0),
    );
    await LocalDb.importFromDbFile(withBuckets);
    expect(await db.query('substrate_archive'), isEmpty);
    await File(withBuckets).delete();
    await File(offBackup).delete();
  });

  test('the import report counts archive buckets it could not merge '
      '(production runImport path)', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final snapshot = await LocalDb.exportCopy();
    final copy = await databaseFactory.openDatabase(snapshot);
    await copy.update(
      'substrate_archive',
      {'codec': 99},
      where: "device_id = '' AND utc_day = ?",
      whereArgs: [_d0 ~/ _day],
    );
    await copy.close();
    final app = AppState.forTesting();
    final outcome = await runImport(app, [snapshot]);
    await File(snapshot).delete();
    expect(app.lastImportArchiveSkipped, 1);
    expect(outcome.archiveBucketsSkipped, 1);
    expect(outcome.lostSomething, isTrue);
  });

  test('archiving switched off mid-prune: no bucket is written after the '
      'purge', () async {
    await _seed();
    var calls = 0;
    SubstrateArchive.debugBeforeBucket = () async {
      if (calls++ == 1) {
        await LocalDb.setSubstrateArchivePolicy(
          const SubstrateArchivePolicy(0),
        );
      }
    };
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    expect(calls, 4);
    // The first bucket was archived before the switch; the purge removed it,
    // and nothing was written after it.
    expect(await (await _db()).query('substrate_archive'), isEmpty);
    expect(await _live('decoded_onehz', 'rec_ts < ?', [cutoff]), isEmpty);
    expect(await _live('decoded_rr', 'rec_ts < ?', [cutoff]), isEmpty);
  });

  test('an offload starting mid-prune stops archiving after the in-flight '
      'bucket; the rest stay live and archive next pass', () async {
    await _seed();
    final liveBelow = await _live(
      'decoded_onehz',
      'rec_ts > 0 AND rec_ts < ?',
      [cutoff],
    );
    var buckets = 0;
    SubstrateArchive.debugBeforeBucket = () async => buckets++;
    final logs = <String>[];
    // Every bucket is behind the hard floor: a yield that deleted unarchived
    // rows would show up as missing seconds below.
    await LocalDb.pruneDecodedBeforeRecTs(
      cutoff,
      archive: policy,
      hardFloorSec: cutoff,
      log: logs.add,
      shouldYield: () => buckets > 1, // the offload begins after bucket 1
    );
    final db = await _db();
    expect(await db.query('substrate_archive'), hasLength(1));
    expect(logs.single, contains('offload active'));
    final (archived1, _) = await _archived();
    final stillLive = await _live(
      'decoded_onehz',
      'rec_ts > 0 AND rec_ts < ?',
      [cutoff],
    );
    expect(archived1.length + stillLive.length, liveBelow.length);

    // Next pass, offload over: the rest is archived, nothing was lost.
    await LocalDb.pruneDecodedBeforeRecTs(
      cutoff,
      archive: policy,
      hardFloorSec: cutoff,
    );
    expect(await db.query('substrate_archive'), hasLength(4));
    final (archived, _) = await _archived();
    _expectSameRows(liveBelow, archived);
    expect(await _live('decoded_onehz', 'rec_ts < ?', [cutoff]), isEmpty);
  });

  test('a late merge keeps the bucket\'s original tz_offset_min', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final db = await _db();
    const where = "device_id = '' AND utc_day = ?";
    final args = [_d0 ~/ _day];
    await db.update(
      'substrate_archive',
      {'tz_offset_min': 540},
      where: where,
      whereArgs: args,
    );
    await db.insert('decoded_onehz', _gen4(_d0 + 11));
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final row = (await db.query(
      'substrate_archive',
      where: where,
      whereArgs: args,
    )).single;
    expect(row['tz_offset_min'], 540);
    expect(
      (await _archived()).$1.containsKey('|${(_d0 + 11) * 1000}|null'),
      isTrue,
    );
  });

  test('a failed exportCopy leaves no copy behind, and the backup reports '
      'the failure', () async {
    List<String> leftovers() => [
      for (final f in tmp.listSync().whereType<File>())
        if (p.basename(f.path).startsWith('openstrap_export_'))
          p.basename(f.path),
    ];
    LocalDb.debugFailExportStrip = true;
    await expectLater(
      LocalDb.exportCopy(includeSubstrateArchive: false),
      throwsStateError,
    );
    final outcome = await runBackup(now: DateTime(2031, 1, 1, 12));
    LocalDb.debugFailExportStrip = false;
    expect(outcome.succeeded, isFalse);
    expect(leftovers(), isEmpty);
  });

  test('page queries seek on the primary key', () async {
    final db = await _db();
    for (final sql in [
      SubstrateArchive.onehzPageSql,
      SubstrateArchive.rrPageSql,
    ]) {
      final plan = await db.rawQuery(
        'EXPLAIN QUERY PLAN $sql',
        List.filled('?'.allMatches(sql).length, 1),
      );
      final detail = plan.map((r) => r['detail']).join(' | ');
      expect(detail, contains('USING INDEX sqlite_autoindex_'), reason: detail);
      expect(detail, contains('ts_ms'), reason: detail);
      expect(detail, isNot(contains('TEMP B-TREE')), reason: detail);
    }
  });

  test(
    'a full-density day archives losslessly across page boundaries',
    () async {
      // 86,400 one-second rows and ~1.3 beats each: many 5,000-row pages per
      // table, so both keyset cursors cross page boundaries mid-second.
      final db = await _db();
      final rnd = math.Random(7);
      for (var c = 0; c < 86400; c += 8640) {
        final batch = db.batch();
        for (var ts = _d0 + c; ts < _d0 + c + 8640; ts++) {
          batch.insert('decoded_onehz', {
            ..._gen4(ts, hr: 50 + rnd.nextInt(60)),
            'ax': (rnd.nextInt(20001) - 10000) / 10000,
          });
          for (var i = 0; i < 1 + (ts % 3 == 0 ? 1 : 0); i++) {
            batch.insert(
              'decoded_rr',
              _beat('', ts, i, 600 + rnd.nextInt(600)),
            );
          }
        }
        await batch.commit(noResult: true);
      }
      final liveOnehz = await _live('decoded_onehz', 'rec_ts < ?', [
        _d0 + _day,
      ]);
      final liveRr = await _live('decoded_rr', 'rec_ts < ?', [_d0 + _day]);
      expect(liveRr.length, greaterThan(SubstrateArchive.pageSizeForTest * 4));

      // Longest stall of this isolate's event loop while the prune runs.
      var last = DateTime.now();
      var worst = Duration.zero;
      final tick = Timer.periodic(const Duration(milliseconds: 2), (_) {
        final now = DateTime.now();
        final gap = now.difference(last);
        if (gap > worst) worst = gap;
        last = now;
      });
      final clock = Stopwatch()..start();
      try {
        await LocalDb.pruneDecodedBeforeRecTs(_d0 + _day, archive: policy);
      } finally {
        tick.cancel();
      }
      // One full-day bucket is one write transaction: this is how long the
      // database's write lock is held for it.
      // ignore: avoid_print
      print('full-density bucket: ${clock.elapsedMilliseconds} ms in one txn');
      // ignore: avoid_print
      print(
        'full-density prune: longest main-isolate stall ${worst.inMilliseconds} ms',
      );

      final (onehz, rr) = await _archived();
      _expectSameRows(liveOnehz, onehz);
      _expectSameRows(liveRr, rr);
      expect(await _live('decoded_rr', 'rec_ts < ?', [_d0 + _day]), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('automatic snapshots leave the archive out; manual exports keep it', () {
    // Every caller of exportCopy, by intent. A new automatic path has to be
    // added here deliberately, not inherit the archive by default.
    String src(String path) => File(path).readAsStringSync();
    for (final auto in [
      'lib/data/auto_backup.dart',
      'lib/telemetry/health_uploader.dart',
    ]) {
      expect(
        src(auto),
        contains('exportCopy(includeSubstrateArchive: false)'),
        reason: auto,
      );
    }
    final calls = RegExp(r'LocalDb\.exportCopy\(([^)]*)\)');
    final manual = [
      for (final m in calls.allMatches(src('lib/ui2/profile/data.dart')))
        m.group(1),
    ];
    expect(manual, isNotEmpty);
    expect(manual, everyElement(isNot(contains('false'))));
  });

  test(
    'a transient failure keeps the rows live even past the hard floor',
    () async {
      await _seed();
      final before = await _live('decoded_onehz', 'rec_ts > 0 AND rec_ts < ?', [
        cutoff,
      ]);
      SubstrateArchive.debugThrowInBucket = Exception('database is locked');
      await LocalDb.pruneDecodedBeforeRecTs(
        cutoff,
        archive: policy,
        hardFloorSec: cutoff, // every bucket is past the hold
      );
      SubstrateArchive.debugThrowInBucket = null;
      expect(
        await _live('decoded_onehz', 'rec_ts > 0 AND rec_ts < ?', [cutoff]),
        hasLength(before.length),
      );
      expect(await (await _db()).query('substrate_archive'), isEmpty);
    },
  );

  test('maxArchiveBuckets caps one pass; the rest stay live', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(
      cutoff,
      archive: policy,
      maxArchiveBuckets: 1,
    );
    final db = await _db();
    expect(await db.query('substrate_archive'), hasLength(1));
    expect(
      await _live('decoded_onehz', 'rec_ts > 0 AND rec_ts < ?', [cutoff]),
      isNotEmpty,
    );
  });

  test(
    'readBlob returns a blob larger than one chunk, byte for byte',
    () async {
      final db = await _db();
      final rnd = math.Random(3);
      final big = Uint8List.fromList([
        for (var i = 0; i < 1300 * 1024 + 17; i++) rnd.nextInt(256),
      ]);
      await db.insert('substrate_archive', {
        'device_id': 'big',
        'utc_day': 1,
        'codec': 1,
        'from_ts': 86400,
        'to_ts': 86401,
        'onehz_rows': 0,
        'rr_rows': 0,
        'raw_bytes': 0,
        'fingerprint': 0,
        'blob': big,
        'created_at': 1,
        'updated_at': 1,
      });
      final back = await SubstrateArchive.readBlob(db, 'big', 1);
      expect(back, big);
      expect(await SubstrateArchive.readBlob(db, 'big', 2), isNull);
    },
  );

  test('restore leaves out buckets older than this database keeps', () async {
    await _seed();
    await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
    final snapshot = await LocalDb.exportCopy();
    final db = await _db();
    await db.delete('substrate_archive');
    // Keep one day behind the edge: day 0's buckets would be evicted at the
    // next housekeeping, so they are not restored (or reported) at all.
    await LocalDb.setSubstrateArchivePolicy(const SubstrateArchivePolicy(1));
    final counts = await LocalDb.importFromDbFile(snapshot);
    await File(snapshot).delete();
    final days = {
      for (final r in await db.query('substrate_archive', columns: ['utc_day']))
        r['utc_day'],
    };
    expect(days, {_d0 ~/ _day + 1});
    expect(counts['substrate_archive'], 2);
  });

  test(
    'a multi-day export carries every selected day and nothing else',
    () async {
      await _seed();
      await LocalDb.pruneDecodedBeforeRecTs(cutoff, archive: policy);
      final (onehz, _) = await _archived();
      final labels = {
        dayLabelOf(DateTime.fromMillisecondsSinceEpoch((_d0 + 3600) * 1000)),
        dayLabelOf(
          DateTime.fromMillisecondsSinceEpoch((_d0 + _day + 3600) * 1000),
        ),
      };
      final windows = [
        for (final l in labels) (localDayStartSec(l)!, localDayEndSec(l)!),
      ];
      bool inAny(Map<String, Object?> r) {
        final ts = r['rec_ts'] as int;
        return windows.any((w) => ts >= w.$1 && ts < w.$2);
      }

      final path = await LocalDb.exportDaysDb(labels);
      try {
        final (got, _) = await _roundTrip(path);
        _expectSameRows(onehz.values.where(inAny).toList(), got);
      } finally {
        await File(path).delete();
      }
    },
  );

  test('a failed unarchived delete neither stops the pass nor loses the '
      'failure counts', () async {
    await _seed();
    SubstrateArchive.debugThrowInBucket = Exception('out of memory');
    for (var pass = 1; pass < SubstrateArchive.maxFailedPasses; pass++) {
      await LocalDb.pruneDecodedBeforeRecTs(
        cutoff,
        archive: policy,
        hardFloorSec: cutoff,
      );
    }
    // The pass that would delete unarchived: the FIRST bucket's delete fails
    // (a concurrent writer holding the lock).
    var calls = 0;
    SubstrateArchive.debugBeforeFallbackDelete = () async {
      if (calls++ == 0) throw Exception('database is locked');
    };
    await LocalDb.pruneDecodedBeforeRecTs(
      cutoff,
      archive: policy,
      hardFloorSec: cutoff,
    );
    SubstrateArchive.debugBeforeFallbackDelete = null;
    SubstrateArchive.debugThrowInBucket = null;
    expect(calls, greaterThan(1), reason: 'the later buckets still ran');
    final left = await _live('decoded_onehz', 'rec_ts > 0 AND rec_ts < ?', [
      cutoff,
    ]);
    expect(left, isNotEmpty, reason: 'the failed bucket stays live');
    final days = {for (final r in left) (r['rec_ts'] as int) ~/ 86400};
    expect(days, hasLength(1));
    // The rest of the prune ran: the undatable row is gone.
    expect(await _live('decoded_onehz', 'rec_ts <= 0', const []), isEmpty);
    // Every bucket's count was saved; only the failed one is still counted.
    final row = await (await _db()).query(
      'compute_freshness',
      where: 'key = ?',
      whereArgs: [SubstrateArchive.failuresKey],
    );
    final counts = jsonDecode(row.single['payload_json'] as String) as Map;
    expect(counts.values.toSet(), {SubstrateArchive.maxFailedPasses});
    expect(counts.keys.every((k) => (k as String).endsWith('|${days.single}')),
        isTrue);
    // The next pass finishes the job.
    await LocalDb.pruneDecodedBeforeRecTs(
      cutoff,
      archive: policy,
      hardFloorSec: cutoff,
    );
    expect(await _live('decoded_onehz', 'rec_ts < ?', [cutoff]), isEmpty);
  });

  test('a bucket that keeps failing past the hold is deleted after '
      '${SubstrateArchive.maxFailedPasses} passes', () async {
    await _seed();
    final before = await _live('decoded_onehz', 'rec_ts > 0 AND rec_ts < ?', [
      cutoff,
    ]);
    SubstrateArchive.debugThrowInBucket = Exception('out of memory');
    for (var pass = 1; pass < SubstrateArchive.maxFailedPasses; pass++) {
      await LocalDb.pruneDecodedBeforeRecTs(
        cutoff,
        archive: policy,
        hardFloorSec: cutoff,
      );
      expect(
        await _live('decoded_onehz', 'rec_ts > 0 AND rec_ts < ?', [cutoff]),
        hasLength(before.length),
        reason: 'pass $pass keeps it live',
      );
    }
    await LocalDb.pruneDecodedBeforeRecTs(
      cutoff,
      archive: policy,
      hardFloorSec: cutoff,
    );
    SubstrateArchive.debugThrowInBucket = null;
    expect(await _live('decoded_onehz', 'rec_ts < ?', [cutoff]), isEmpty);
    expect(await (await _db()).query('substrate_archive'), isEmpty);
    // The counts are cleared with the buckets they counted.
    final row = await (await _db()).query(
      'compute_freshness',
      where: 'key = ?',
      whereArgs: [SubstrateArchive.failuresKey],
    );
    expect(row.single['payload_json'], '{}');
  });
}
