// E16 RED contracts. The standalone night/cardio payload uses format 2;
// fork day/minute/awake accumulator formats and schema numbers do not transfer.
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:openstrap_edge/compute/night_checkpoint.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/ed2b_stream_diagnostics.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/recent_slice.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/ed2a_recalc_fixture.dart';

class _CheckpointPaths extends PathProviderPlatform {
  _CheckpointPaths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

Map<String, Object?> _legacyRsa(Map<String, Object?> row, {required bool bins}) {
  final bytes = row['state'] as List<int>;
  final payload = jsonDecode(utf8.decode(bytes.sublist(32))) as Map;
  final night = payload['night'] as Map;
  final state = bins ? (night['rsa_bins'] as Map)['open'] as Map : night['rsa'] as Map;
  state['version'] = 2;
  final body = utf8.encode(jsonEncode(payload));
  return {'state': Uint8List.fromList([...sha256.convert(body).bytes, ...body])};
}

Future<bool> _hasCheckpoint(Database db) async => (await db.rawQuery(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='day_checkpoint'"))
    .isNotEmpty;

Future<Database> _storage() async {
  final db = await LocalDb.instance;
  expect(await _hasCheckpoint(db), isTrue,
      reason: 'E16 needs disposable day_checkpoint storage at rung 60');
  expect(await db.query('store_identity'), hasLength(1),
      reason: 'rung 60 and repair must also create the durable identity row');
  return db;
}

Map<String, Object?> _sampleRow({String day = edDay, int? version}) => {
  'day_id': day, 'algo_version': version ?? kAlgoVersion, 'fmt': nightCheckpointFormat,
  'ctx_sig': 'night-cardio-context', 'cp_rec_ts': edStart ~/ 900 * 900,
  'rev_vec': Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]),
  'state': Uint8List.fromList([0, 255, 9, 10, 13, 128]),
  'night_ref': null, 'computed_at': 7,
};

Future<List<Map<String, Object?>>> _rows(Database db) => db.query(
    'day_checkpoint', where: 'day_id = ? AND algo_version = ?',
    whereArgs: [edDay, kAlgoVersion]);

// Supply a real sleep window and RR, not an absent-night fixture that could
// satisfy persistence by writing an empty payload. Two closed 15-minute buckets
// plus a tail exercise the resume boundary.
const _nightSeconds = 2100, _manualOffsetSeconds = 2000;
// One beat per second, including both manual-window endpoints. Clamp to the
// seeded RR extent; later 1 Hz-only appends add no beats.
int get _manualBeatCount => math.min(_nightSeconds, _manualOffsetSeconds + 1);

Future<void> _night() async {
  await edRows(edStart, edStart + _nightSeconds, hr: 60, az: 1);
  await LocalDb.putSleepOverride(dayId: edDay,
      onsetTs: edStart, offsetTs: edStart + _manualOffsetSeconds, source: 'manual');
  final db = await LocalDb.instance;
  final batch = db.batch();
  for (var i = 0; i < _nightSeconds; i++) {
    final ts = edStart + i;
    batch.insert('decoded_rr', {'device_id': '', 'ts_ms': ts * 1000,
      'rec_ts': ts, 'beat_index': 0, 'rr_ts_ms': ts * 1000,
      'rr_ms': 950.0 + 35 * math.sin(i * .13) + 13 * math.sin(i * .041)},
      conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);
}

Future<void> _derive(DerivationEngine engine) async {
  expect(await engine.runDays(edProfile, {edDay}), 1,
      reason: 'the checkpoint assertions require a real persisted derivation');
}

void main() {
  final originalName = LocalDb.dbName;
  final originalZone = Platform.environment['TZ'] ?? 'UTC';
  setUpAll(edInit);
  setUp(() async {
    edSetZone('UTC');
    await edFresh('ed2b_checkpoints.db');
    LocalDb.lastRebuild = null;
  });
  tearDown(() async {
    DerivationEngine.debugHoldTonight = {};
    await edDrop();
    LocalDb.dbName = originalName;
    edSetZone(originalZone);
  });

  test('E16 fresh storage uses rung 60 and a versioned composite key', () async {
    expect(LocalDb.schemaVersion, 60,
        reason: '59 belongs to ED-2a revisions; fork rungs do not transfer');
    final db = await _storage();
    expect(await db.getVersion(), 60);
    expect(await db.query('store_identity'), hasLength(1));
    expect(await LocalDb.storeIdentity(), matches(RegExp(r'^[0-9a-f]{32}$')));
    final columns = {for (final row in await db.rawQuery(
      'PRAGMA table_info(day_checkpoint)')) row['name']: row};
    expect(columns.keys.toSet(), {'day_id', 'algo_version', 'fmt', 'ctx_sig',
      'cp_rec_ts', 'rev_vec', 'state', 'night_ref', 'computed_at'});
    expect(columns['day_id']!['pk'], 1);
    expect(columns['algo_version']!['pk'], 2);
    for (final name in ['rev_vec', 'state']) {
      expect(columns[name]!['type'], 'BLOB');
      expect(columns[name]!['notnull'], 1);
    }
    expect(await db.query('day_checkpoint'), isEmpty);
  });

  test('E16 59 to 60 preserves decoded rows and revisions without backfill', () async {
    var db = await LocalDb.instance;
    await edRows(edStart, edStart + 3);
    await db.insert('decoded_rr', {'device_id': '', 'ts_ms': edStart * 1000,
      'rec_ts': edStart, 'rr_ts_ms': edStart * 1000, 'beat_index': 0, 'rr_ms': 900});
    final raw = await db.query('decoded_onehz');
    final rr = await db.query('decoded_rr');
    final revs = await db.query('input_rev', orderBy: 'bucket');
    final rawShape = await db.rawQuery('PRAGMA table_info(decoded_onehz)');
    await db.execute('DROP TABLE IF EXISTS day_checkpoint');
    await db.execute('DROP TABLE IF EXISTS store_identity');
    await db.setVersion(59);
    await LocalDb.close();
    db = await LocalDb.instance;
    expect(LocalDb.lastRebuild, isNull,
        reason: 'a migration must preserve the original DB, not quarantine it');
    expect(await db.query('decoded_onehz'), raw);
    expect(await db.query('decoded_rr'), rr);
    expect(await db.query('input_rev', orderBy: 'bucket'), revs);
    expect(await db.rawQuery('PRAGMA table_info(decoded_onehz)'), rawShape);
    await _storage();
    expect(await db.getVersion(), 60);
    expect(await db.query('day_checkpoint'), isEmpty,
        reason: 'migration creates empty scratch storage without deriving old days');
  });

  test('E16 same-version repair creates storage and is idempotent', () async {
    final db = await LocalDb.instance;
    await db.execute('DROP TABLE IF EXISTS day_checkpoint');
    await db.execute('DROP TABLE IF EXISTS store_identity');
    await LocalDb.repairOpenSchemaForTest(db);
    await _storage();
    await db.insert('day_checkpoint', _sampleRow());
    final before = await db.query('day_checkpoint');
    final storeId = await LocalDb.storeIdentity();
    await LocalDb.repairOpenSchemaForTest(db);
    await LocalDb.repairOpenSchemaForTest(db);
    await LocalDb.close();
    final reopened = await LocalDb.instance;
    expect(LocalDb.lastRebuild, isNull);
    expect(await reopened.query('day_checkpoint'), before);
    expect(await LocalDb.storeIdentity(), storeId);
  });

  test('E16 upgrade and open repair create scratch without scanning raw input', () async {
    var db = await LocalDb.instance;
    await edRows(edStart, edStart + 3);
    await db.execute('DROP TABLE IF EXISTS day_checkpoint');
    await db.execute('DROP TABLE IF EXISTS store_identity');
    await db.setVersion(59);
    await LocalDb.close();
    final sql = <String>[];
    // Observe the actual sqflite calls, including batches, without changing
    // migration code or providing a synthetic checkpoint implementation.
    // ignore: experimental_member_use
    databaseFactoryOrNull = SqfliteDatabaseFactoryLogger(databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.invoke,
        log: (event) {
          if (event is! SqfliteLoggerInvokeEvent) return;
          void collect(Object? value) {
            if (value is Map) {
              if (value['sql'] case final String statement) sql.add(statement);
              for (final v in value.values) { collect(v); }
            } else if (value is List) {
              for (final v in value) { collect(v); }
            }
          }
          collect(event.arguments);
        },
      ));
    try {
      db = await LocalDb.instance;
      await LocalDb.repairOpenSchemaForTest(db);
      final openingSql = List<String>.of(sql);
      expect(openingSql, isNotEmpty, reason: 'SQL observation must be active');
      final rawAccess = RegExp(
        r'\b(?:FROM|JOIN|UPDATE|INTO|DELETE\s+FROM)\s+["`\[]?'
        r'(?:decoded_onehz|decoded_rr|samples|raw_archive)\b',
        caseSensitive: false);
      expect(openingSql.where((statement) {
        final ddl = statement.trimLeft().toUpperCase();
        if (ddl.startsWith('CREATE TRIGGER') || ddl.startsWith('CREATE VIEW')) return false;
        return rawAccess.hasMatch(statement);
      }), isEmpty, reason: 'rung 60 and repair must perform no raw scan/backfill/rewrite');
      await _storage();
      expect(await db.query('day_checkpoint'), isEmpty);
    } finally {
      await LocalDb.close();
      databaseFactory = databaseFactoryFfi;
    }
  });

  test('E16 actual same-version reopen repairs missing checkpoint storage', () async {
    final db = await LocalDb.instance;
    await db.execute('DROP TABLE IF EXISTS day_checkpoint');
    await db.execute('DROP TABLE IF EXISTS store_identity');
    final version = await db.getVersion();
    await LocalDb.close();
    final reopened = await LocalDb.instance;
    expect(LocalDb.lastRebuild, isNull);
    expect(await reopened.getVersion(), version);
    await _storage();
    expect(await reopened.query('day_checkpoint'), isEmpty);
  });

  test('E16 rerunning rung 60 keeps checkpoint blobs byte for byte', () async {
    final db = await _storage();
    await db.insert('day_checkpoint', _sampleRow());
    await db.insert('day_checkpoint', _sampleRow(version: kAlgoVersion - 1));
    await db.insert('day_checkpoint', _sampleRow(day: '2020-01-03'));
    final before = await db.query('day_checkpoint', orderBy: 'day_id,algo_version');
    final storeId = await LocalDb.storeIdentity();
    await db.setVersion(59);
    await LocalDb.close();
    final reopened = await LocalDb.instance;
    expect(LocalDb.lastRebuild, isNull);
    expect(await reopened.query('day_checkpoint', orderBy: 'day_id,algo_version'), before);
    expect(await LocalDb.storeIdentity(), storeId);
    expect(await _rows(reopened), hasLength(1));
    expect((await _rows(reopened)).single['state'], _sampleRow()['state']);
  });

  test('E16 standalone payload carries night and cardio only, format 2', () async {
    await _night();
    final engine = DerivationEngine();
    await _derive(engine);
    final diagnostics = engine.debugCheckpoints;
    expect(diagnostics.writes, greaterThan(0),
        reason: 'the worker must emit a checkpoint from real derived inputs');
    expect(diagnostics.lastEncodedPayload, isNotNull);
    expect(diagnostics.lastEncodedPayload, isNotEmpty);
    final payload = diagnostics.lastDecodedPayload;
    expect(payload, isNotNull,
        reason: 'observe the worker decode, without decoding on the UI isolate');
    expect(payload!['v'], nightCheckpointFormat,
        reason: 'RSA v3 and closed-bin states require the new format');
    expect(payload['night'], isNotNull, reason: 'fixture supplies a settled RR night');
    expect(payload['cardio'], isNotNull);
    // Inspect the actual worker-emitted inner checkpoint. In #99 capped
    // correctors carry their consumed input count at capped.n, not top-level n.
    final night = payload['night'] as Map;
    final tag = night['tag'] as Map;
    final corrector = (night['corrector'] as Map).cast<String, dynamic>();
    expect(corrector['version'], 2);
    expect((night['rsa'] as Map)['version'], 3);
    expect((night['rsa_bins'] as Map)['v'], 2);
    expect(corrector['type'], 'RrCorrector');
    expect(corrector['maxArtifactRun'], 32);
    expect((corrector['capped'] as Map)['n'], tag['count'],
        reason: 'the serialized capped corrector must describe exactly the tagged night prefix');
    expect(tag['count'], greaterThan(0));
    expect(ana.RrCorrector.fromJson(corrector).toJson(), corrector,
        reason: '#99 must accept the real inner checkpoint without changing its state');
    for (final key in ['day', 'minutes', 'bills', 'awake', 'activity', 'curves']) {
      expect(payload, isNot(contains(key)), reason: '$key is outside ED-2b adoption');
    }
  });

  test('E16 process restart resumes and equals cold derive byte for byte', () async {
    await _night();
    // Close the entire selected night before the checkpoint boundary, so a
    // restarted worker has no tail beats left to fold.
    await edRows(edStart + 2100, edStart + 2700, hr: 60, az: 1);
    final first = DerivationEngine();
    await _derive(first);
    final before = await edStored(edDay);
    final storeId = await LocalDb.storeIdentity();
    await LocalDb.close();
    await LocalDb.instance;
    expect(await LocalDb.storeIdentity(), storeId);
    final resumed = DerivationEngine()..debugNightStreams = Ed2bStreamDiagnostics();
    await _derive(resumed);
    final resumedBytes = await edStored(edDay);
    expect(resumedBytes, before);
    final cold = DerivationEngine()..debugCheckpoints.disabled = true;
    await _derive(cold);
    expect(await edStored(edDay), resumedBytes);
    expect(resumed.debugCheckpoints.hits, greaterThan(0),
        reason: 'a fresh engine after reopen must adopt the persisted night/cardio state');
    expect(resumed.debugNightStreams!.processedNightBeats, 0);
    expect(cold.debugCheckpoints.hits, 0);
  });

  test('E16 resumed append equals cold derive on the identical extended input', () async {
    await _night();
    await _derive(DerivationEngine());
    await edRows(edStart + 2100, edStart + 2400, hr: 61, az: 1);
    final resumed = DerivationEngine();
    await _derive(resumed);
    final actual = await edStored(edDay);
    final cold = DerivationEngine()..debugCheckpoints.disabled = true;
    await _derive(cold);
    expect(await edStored(edDay), actual);
    expect(resumed.debugCheckpoints.hits, greaterThan(0),
        reason: 'new open-bucket tail must not discard the valid closed prefix');
  });

  final damaged = <String, Map<String, Object?> Function(Map<String, Object?>)>{
    'truncated blob': (_) => {'state': Uint8List.fromList([1, 0, 255])},
    'checksum': (row) {
      final bytes = Uint8List.fromList(row['state'] as List<int>);
      bytes[bytes.length ~/ 2] ^= 1;
      return {'state': bytes};
    },
    'old format': (_) => {'fmt': 1},
    'future format': (_) => {'fmt': 999},
    'legacy RSA v2': (row) => _legacyRsa(row, bins: false),
    'legacy RSA-bin v2': (row) => _legacyRsa(row, bins: true),
    'old algorithm': (_) => {'algo_version': kAlgoVersion - 1},
    'foreign context': (_) => {'ctx_sig': 'foreign-owner-profile-and-window'},
    'misaligned boundary': (row) => {'cp_rec_ts': (row['cp_rec_ts'] as int) + 1},
    'corrupt revision vector': (_) => {'rev_vec': Uint8List.fromList([1])},
  };
  for (final entry in damaged.entries) {
    test('E16 ${entry.key} is refused whole and recomputed exactly', () async {
      await _night();
      await _derive(DerivationEngine());
      final db = await _storage();
      final rows = await _rows(db);
      expect(rows, hasLength(1), reason: 'real derive must persist a resume point');
      await db.update('day_checkpoint', entry.value(rows.single),
          where: 'day_id = ? AND algo_version = ?', whereArgs: [edDay, kAlgoVersion]);
      final engine = DerivationEngine();
      await _derive(engine);
      final rejectedOutput = await edStored(edDay);
      final cold = DerivationEngine()..debugCheckpoints.disabled = true;
      await _derive(cold);
      expect(await edStored(edDay), rejectedOutput);
      expect(engine.debugCheckpoints.hits, 0,
          reason: 'never salvage a night or cardio subset of an invalid checkpoint');
      if (entry.key == 'old algorithm') {
        expect(engine.debugCheckpoints.misses, greaterThan(0),
            reason: 'version-keyed lookup must miss the old algorithm row');
      } else {
        expect(engine.debugCheckpoints.rejections, isNotEmpty,
            reason: 'rejection must be observable after the real reader attempts it');
      }
      expect(engine.debugCheckpoints.writes, greaterThan(0), reason: 'cold recompute replaces bad state');
    });
  }

  test('E16 changed closed input revision refuses an otherwise valid checkpoint', () async {
    await _night();
    await _derive(DerivationEngine());
    await edRows(edStart, edStart + 1, hr: 60, az: 1);
    final engine = DerivationEngine();
    await _derive(engine);
    final revised = await edStored(edDay);
    await _derive(DerivationEngine()..debugCheckpoints.disabled = true);
    expect(await edStored(edDay), revised);
    expect(engine.debugCheckpoints.hits, 0);
    expect(engine.debugCheckpoints.rejections, isNotEmpty,
        reason: 'identical newest-wins replacement changes input_rev, so prefix must rebuild');
  });

  for (final sameEngine in [true, false]) {
    test('E16 reopen reuses checkpoints with unchanged revisions, '
        '${sameEngine ? 'retained' : 'fresh'} engine', () async {
      await _night();
      await edRows(edStart + 2100, edStart + 2700, hr: 60, az: 1);
      final storeId = await LocalDb.storeIdentity();
      final first = DerivationEngine()..debugNightStreams = Ed2bStreamDiagnostics();
      await _derive(first);
      final before = await LocalDb.inputDayFingerprint(edDay);
      final output = await edStored(edDay);
      final beats = first.debugNightStreams!.retainedNightBeats;
      final work = first.debugNightStreams!.processedNightBeats;
      final streamWork = {for (final key in ['frequency', 'rsa', 'cvhr', 'prsa', 'rsa_bins'])
        key: first.debugNightStreams!.processedBeats(key)};
      expect(beats, _manualBeatCount,
          reason: 'one seeded RR beat per second, including the manual-window end');
      final saved = await _rows(await _storage());
      expect(saved, hasLength(1));
      await LocalDb.close();
      final db = await LocalDb.instance;
      final after = await LocalDb.inputDayFingerprint(edDay);
      expect(after.revisionSum, before.revisionSum);
      expect(after.revisionMax, before.revisionMax);
      expect(after.generation, greaterThan(before.generation));
      expect(await _rows(db), saved,
          reason: 'ordinary reopen preserves the durable checkpoint');
      expect(await LocalDb.storeIdentity(), storeId);
      final engine = sameEngine ? first :
          (DerivationEngine()..debugNightStreams = Ed2bStreamDiagnostics());
      engine.debugCheckpoints.reset();
      await _derive(engine);
      expect(engine.debugCheckpoints.hits, 1,
          reason: 'the same store id permits disk adoption after RAM generation changes');
      expect(engine.debugCheckpoints.rejections, isEmpty);
      expect(engine.debugNightStreams!.processedNightBeats,
          sameEngine ? work : 0,
          reason: 'resume adds no night work and preserves cumulative RAM counters');
      for (final entry in streamWork.entries) {
        expect(engine.debugNightStreams!.processedBeats(entry.key), sameEngine ? entry.value : 0,
            reason: '${entry.key} counters survive same-engine disk adoption');
      }
      expect(await edStored(edDay), output);
      final replacement = await _rows(db);
      expect(replacement, hasLength(1));
      expect(replacement.single['ctx_sig'], saved.single['ctx_sig']);
      final rebuilt = engine.debugNightStreams!.processedNightBeats;
      await _derive(engine);
      expect(engine.debugNightStreams!.processedNightBeats, rebuilt,
          reason: 'the replacement RAM owner must be retained');
      expect(await edStored(edDay), output);
      final resumed = DerivationEngine();
      await _derive(resumed);
      expect(resumed.debugCheckpoints.hits, 1,
          reason: 'the checkpoint remains reusable in the same store');
      expect(await edStored(edDay), output);
    });
  }

  test('E16 committed import rejects stale disk state with unchanged raw revisions', () async {
    await _night();
    final engine = DerivationEngine();
    await _derive(engine);
    final before = await LocalDb.inputDayFingerprint(edDay);
    final storeId = await LocalDb.storeIdentity();
    final saved = (await _rows(await _storage())).single;
    final dir = await Directory.systemTemp.createTemp('ed2b_cp_generation_');
    final path = p.join(dir.path, 'source.db');
    try {
      final source = await databaseFactory.openDatabase(path);
      await source.execute('CREATE TABLE journal (date TEXT PRIMARY KEY, '
          "note TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL)");
      await source.insert('journal', {'date': edDay, 'note': 'generation-only', 'updated_at': 1});
      await source.close();
      await LocalDb.importFromDbFile(path);
      final after = await LocalDb.inputDayFingerprint(edDay);
      expect(after.revisionSum, before.revisionSum);
      expect(after.revisionMax, before.revisionMax);
      expect(after.generation, greaterThan(before.generation),
          reason: 'committed store replacement differs from a legitimate checkpoint restart');
      expect(await LocalDb.storeIdentity(), isNot(storeId));
      final db = await _storage();
      expect(await _rows(db), isEmpty);
      // Defeat scratch clearing deliberately: identity must reject stale bytes
      // even when the revision vector and raw inputs are unchanged.
      await db.insert('day_checkpoint', saved);
      await LocalDb.close();
      await LocalDb.instance;
      engine.debugCheckpoints.reset();
      await _derive(engine);
      final replaced = await edStored(edDay);
      await _derive(DerivationEngine()..debugCheckpoints.disabled = true);
      expect(await edStored(edDay), replaced);
      expect(engine.debugCheckpoints.hits, 0,
          reason: 'the original engine must not revive its pre-restore resume state');
      expect(engine.debugCheckpoints.misses, greaterThan(0),
          reason: 'the new store identity must force a cold night/cardio lookup');
      expect(engine.debugCheckpoints.rejections, isNotEmpty);
    } finally {
      await databaseFactory.deleteDatabase(path);
      await dir.delete(recursive: true);
    }
  });

  test('E16 wipe and re-import reject stale checkpoint when revisions repeat', () async {
    await _night();
    await _derive(DerivationEngine());
    final db = await _storage();
    final saved = (await _rows(db)).single;
    final before = await LocalDb.inputDayFingerprint(edDay);
    final storeId = await LocalDb.storeIdentity();
    final dir = await Directory.systemTemp.createTemp('ed2b_cp_wipe_');
    final path = p.join(dir.path, 'source.db');
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      await File(db.path).copy(path);
      await LocalDb.wipeAll();
      final wipedId = await LocalDb.storeIdentity();
      expect(wipedId, isNot(storeId));
      await LocalDb.importFromDbFile(path);
      expect(await LocalDb.storeIdentity(), isNot(wipedId));
      final after = await LocalDb.inputDayFingerprint(edDay);
      expect(after.revisionSum, before.revisionSum,
          reason: 'input_rev is local, so reset and identical restore can repeat it');
      expect(after.revisionMax, before.revisionMax);
      expect(await _rows(db), isEmpty);
      await db.insert('day_checkpoint', saved);
      await LocalDb.close();
      await LocalDb.instance;
      final engine = DerivationEngine()..debugNightStreams = Ed2bStreamDiagnostics();
      await _derive(engine);
      expect(engine.debugCheckpoints.hits, 0);
      expect(engine.debugCheckpoints.rejections, isNotEmpty);
      expect(engine.debugNightStreams!.processedNightBeats, _manualBeatCount);
      final actual = await edStored(edDay);
      await _derive(DerivationEngine()..debugCheckpoints.disabled = true);
      expect(await edStored(edDay), actual);
    } finally {
      await databaseFactory.deleteDatabase(path);
      await dir.delete(recursive: true);
    }
  });

  test('E16 replaced DB file rejects old checkpoint with identical inputs', () async {
    await _night();
    await _derive(DerivationEngine());
    final original = await _storage();
    final saved = (await _rows(original)).single;
    final before = await LocalDb.inputDayFingerprint(edDay);
    final storeId = await LocalDb.storeIdentity();
    final liveName = LocalDb.dbName;
    final livePath = original.path;
    final replacementPath = p.join(p.dirname(livePath), 'ed2b_cp_replacement.db');
    await LocalDb.close();
    try {
      await edFresh('ed2b_cp_replacement.db');
      await _night();
      final replacement = await _storage();
      final replacementId = await LocalDb.storeIdentity();
      expect(replacementId, isNot(storeId));
      await replacement.insert('day_checkpoint', saved);
      await replacement.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      await LocalDb.close();
      await databaseFactory.deleteDatabase(livePath);
      await File(replacementPath).copy(livePath);
      LocalDb.dbName = liveName;
      await LocalDb.instance;
      expect(await LocalDb.storeIdentity(), replacementId);
      final after = await LocalDb.inputDayFingerprint(edDay);
      expect(after.revisionSum, before.revisionSum);
      expect(after.revisionMax, before.revisionMax);
      expect(await _rows(await _storage()), [saved]);
      final engine = DerivationEngine()..debugNightStreams = Ed2bStreamDiagnostics();
      await _derive(engine);
      expect(engine.debugCheckpoints.hits, 0);
      expect(engine.debugCheckpoints.rejections, isNotEmpty,
          reason: 'an intact old blob must not certify a different database file');
      expect(engine.debugNightStreams!.processedNightBeats, _manualBeatCount);
    } finally {
      await LocalDb.close();
      LocalDb.dbName = liveName;
      await databaseFactory.deleteDatabase(replacementPath);
    }
  });

  test('E16 rebuild with tolerant salvage rotates identity and rejects old state', () async {
    await _night();
    await _derive(DerivationEngine());
    final db = await _storage();
    final saved = (await _rows(db)).single;
    final storeId = await LocalDb.storeIdentity();
    final before = await LocalDb.inputDayFingerprint(edDay);
    // Force the real ladder-rebuild path. The rename collision rolls back the
    // failed open; all input tables remain available to tolerant salvage.
    await db.execute('CREATE TABLE _raw_old (hex TEXT)');
    await db.execute('DROP TABLE baselines');
    await db.execute('CREATE TABLE baselines (key TEXT PRIMARY KEY)');
    await db.insert('baselines', {'key': 'unreadable-salvage-shape'});
    await db.setVersion(2);
    await LocalDb.close();
    try {
      final rebuilt = await LocalDb.instance;
      expect(LocalDb.lastRebuild, isNotNull);
      final rebuild = LocalDb.lastRebuild!;
      expect(rebuild.salvaged['baselines'], 0,
          reason: 'tolerant salvage must continue past a failed table');
      expect(rebuild.salvaged['decoded_onehz'], _nightSeconds);
      expect(rebuild.salvaged['decoded_rr'], _nightSeconds);
      expect(await LocalDb.storeIdentity(), isNot(storeId));
      expect(await _rows(rebuilt), isEmpty);
      final after = await LocalDb.inputDayFingerprint(edDay);
      expect(after.revisionSum, before.revisionSum);
      expect(after.revisionMax, before.revisionMax);
      await rebuilt.insert('day_checkpoint', saved);
      final engine = DerivationEngine()..debugNightStreams = Ed2bStreamDiagnostics();
      await _derive(engine);
      expect(engine.debugCheckpoints.hits, 0);
      expect(engine.debugCheckpoints.rejections, isNotEmpty);
      expect(engine.debugNightStreams!.processedNightBeats, _manualBeatCount);
    } finally {
      final rebuild = LocalDb.lastRebuild;
      if (rebuild != null) await databaseFactory.deleteDatabase(rebuild.quarantinePath);
    }
  });

  test('E16 wipe clears checkpoints with every other table', () async {
    final db = await _storage();
    await db.insert('day_checkpoint', _sampleRow());
    final storeId = await LocalDb.storeIdentity();
    await LocalDb.wipeAll();
    expect(await LocalDb.storeIdentity(), isNot(storeId));
    expect(await db.query('day_checkpoint'), isEmpty);
    expect(await _hasCheckpoint(db), isTrue, reason: 'wipe clears data and preserves schema');
  });

  for (final fail in [false, true]) {
    test('E16 ${fail ? 'partially failing' : 'successful'} restore clears local scratch', () async {
      final db = await _storage();
      await db.insert('day_checkpoint', _sampleRow());
      final storeId = await LocalDb.storeIdentity();
      await db.execute("CREATE TRIGGER require_rotated_identity BEFORE INSERT ON journal "
          "BEGIN SELECT CASE WHEN (SELECT id FROM store_identity WHERE singleton = 1) "
          "= '$storeId' OR EXISTS(SELECT 1 FROM day_checkpoint) "
          "THEN RAISE(ABORT, 'old checkpoint identity inside restore page') END; END");
      final dir = await Directory.systemTemp.createTemp('ed2b_cp_restore_');
      final path = p.join(dir.path, 'source.db');
      try {
        final source = await databaseFactory.openDatabase(path);
        await source.execute('CREATE TABLE journal (date TEXT PRIMARY KEY, '
            "note TEXT NOT NULL DEFAULT '', updated_at INTEGER NOT NULL)");
        await source.insert('journal', {'date': edDay, 'note': 'restored', 'updated_at': 1});
        // Even a source with matching schema/version must not import its
        // checkpoint into a different store's revision history.
        final ddl = (await db.rawQuery("SELECT sql FROM sqlite_master "
            "WHERE type='table' AND name='day_checkpoint'")).single['sql'] as String;
        await source.execute(ddl);
        await source.insert('day_checkpoint', {
          ..._sampleRow(), 'ctx_sig': 'foreign-store-checkpoint',
        });
        if (fail) {
          await source.execute('CREATE TABLE baselines (key TEXT PRIMARY KEY)');
          await source.insert('baselines', {'key': 'invalid-import'});
        }
        await source.close();
        if (fail) {
          await expectLater(LocalDb.importFromDbFile(path), throwsA(isA<DatabaseException>()));
        } else {
          await LocalDb.importFromDbFile(path);
        }
        expect(await LocalDb.storeIdentity(), isNot(storeId));
        expect((await db.query('journal')).single['note'], 'restored',
            reason: 'at least one replacement page committed');
        expect(await db.query('day_checkpoint'), isEmpty,
            reason: 'a committed restore invalidates local checkpoint inputs even if a later page fails');
      } finally {
        await databaseFactory.deleteDatabase(path);
        await dir.delete(recursive: true);
      }
    });
  }

  for (final fail in [false, true]) {
    test('E16 ${fail ? 'rolled-back first page' : 'empty import'} preserves identity and scratch', () async {
      final db = await _storage();
      await db.insert('day_checkpoint', _sampleRow());
      final saved = await _rows(db);
      final storeId = await LocalDb.storeIdentity();
      final generation = LocalDb.storeGeneration;
      final dir = await Directory.systemTemp.createTemp('ed2b_cp_no_commit_');
      final path = p.join(dir.path, 'source.db');
      try {
        final source = await databaseFactory.openDatabase(path);
        await source.execute('CREATE TABLE baselines (key TEXT PRIMARY KEY)');
        if (fail) await source.insert('baselines', {'key': 'invalid-first-page'});
        await source.close();
        if (fail) {
          await expectLater(LocalDb.importFromDbFile(path), throwsA(isA<DatabaseException>()));
        } else {
          await LocalDb.importFromDbFile(path);
        }
        expect(await LocalDb.storeIdentity(), storeId);
        expect(LocalDb.storeGeneration, generation);
        expect(await _rows(db), saved);
      } finally {
        await databaseFactory.deleteDatabase(path);
        await dir.delete(recursive: true);
      }
    });
  }

  test('E16 issue-report slices explicitly classify disposable checkpoints', () {
    expect(kSliceTables, contains('day_checkpoint'),
        reason: 'new storage must be classified, not silently use fallback');
    expect(kSliceTables['day_checkpoint']!.$1, SliceKeep.none);
    expect(kSliceTables['store_identity']!.$1, SliceKeep.none);
  });

  test('GUARD restore allow-list excludes disposable checkpoints', () {
    expect(LocalDb.restoreTablesForTest, isNot(contains('day_checkpoint')));
    expect(LocalDb.restoreTablesForTest, isNot(contains('store_identity')));
    expect(LocalDb.salvageTablesForTest, isNot(contains('store_identity')));
  });

  test('GUARD disabled checkpoint observations are inert and output-neutral', () async {
    await _night();
    final normal = DerivationEngine();
    await _derive(normal);
    final expected = await edStored(edDay);
    final disabled = DerivationEngine()..debugCheckpoints.disabled = true;
    await _derive(disabled);
    expect(await edStored(edDay), expected);
    expect(disabled.debugCheckpoints.hits, 0);
    expect(disabled.debugCheckpoints.writes, 0);
    disabled.debugCheckpoints.reset();
    expect(disabled.debugCheckpoints.disabled, isTrue);
    expect(disabled.debugCheckpoints.lastEncodedPayload, isNull);
    expect(jsonEncode(disabled.debugCheckpoints.lastDecodedPayload), 'null');
  });
  for (final mode in ['success', 'later table failure', 'later archive-page failure', 'first failure']) {
    test('E16 archive-only $mode rotates identity atomically with committed pages', () async {
      final db = await _storage();
      await db.insert('day_checkpoint', _sampleRow());
      final before = await _rows(db);
      final storeId = await LocalDb.storeIdentity();
      await db.execute('CREATE TRIGGER require_archive_identity BEFORE INSERT ON '
          '${LocalDb.rawArchiveTable} BEGIN SELECT CASE WHEN '
          "(SELECT id FROM store_identity WHERE singleton = 1) = '$storeId' "
          "OR EXISTS(SELECT 1 FROM day_checkpoint) THEN RAISE(ABORT, 'old archive identity') END; END");
      if (mode == 'first failure' || mode == 'later archive-page failure') {
        final refused = mode == 'first failure' ? 1 : 501;
        await db.execute('CREATE TRIGGER refuse_archive_page BEFORE INSERT ON '
            '${LocalDb.rawArchiveTable} WHEN NEW.counter = $refused '
            "BEGIN SELECT RAISE(ABORT, 'archive page failure'); END");
      }
      final dir = await Directory.systemTemp.createTemp('ed2b_archive_identity_');
      final path = p.join(dir.path, 'source.db');
      try {
        final source = await databaseFactory.openDatabase(path);
        await source.execute('CREATE TABLE raw_archive (hex TEXT PRIMARY KEY, '
            'counter INTEGER, packet_type INTEGER, rec_ts INTEGER, captured_at INTEGER, reason TEXT)');
        final batch = source.batch();
        final count = mode == 'later archive-page failure' ? 501 : 1;
        for (var i = 1; i <= count; i++) {
          batch.insert('raw_archive', {'hex': i.toRadixString(16).padLeft(4, '0'),
            'counter': i, 'packet_type': 0, 'rec_ts': edStart,
            'captured_at': edStart * 1000, 'reason': 'identity_test'});
        }
        await batch.commit(noResult: true);
        if (mode == 'later table failure') {
          await source.execute('CREATE TABLE baselines (key TEXT PRIMARY KEY)');
          await source.insert('baselines', {'key': 'missing-payload'});
        }
        await source.close();
        if (mode == 'success') {
          await LocalDb.importFromDbFile(path);
        } else {
          await expectLater(LocalDb.importFromDbFile(path), throwsA(isA<DatabaseException>()));
        }
        final copied = mode == 'first failure' ? 0 :
            mode == 'later archive-page failure' ? 500 : 1;
        expect(await db.query(LocalDb.rawArchiveTable), hasLength(copied));
        if (mode == 'first failure') {
          expect(await LocalDb.storeIdentity(), storeId);
          expect(await _rows(db), before);
        } else {
          expect(await LocalDb.storeIdentity(), isNot(storeId));
          expect(await db.query('day_checkpoint'), isEmpty);
        }
      } finally {
        await databaseFactory.deleteDatabase(path);
        await dir.delete(recursive: true);
      }
    });
  }

  test('E16 deleting a day removes every disposable raw prefix and keeps unrelated input', () async {
    await _night();
    final db = await _storage();
    final other = DateTime(2020, 1, 3, 10).millisecondsSinceEpoch ~/ 1000;
    await edRows(other, other + 2);
    await db.insert('day_checkpoint', _sampleRow());
    await db.insert('day_checkpoint', _sampleRow(day: '2020-01-03'));
    final identity = await LocalDb.storeIdentity();
    const learning = '{"nights":7,"folded_days":["2020-01-01"]}';
    await LocalDb.putBaseline('sleep_user_profile', learning);
    await LocalDb.deleteDays({edDay});
    expect(await db.query('day_checkpoint'), isEmpty,
        reason: 'a neighbouring checkpoint can contain the deleted evening too');
    expect(await LocalDb.storeIdentity(), isNot(identity));
    expect(await db.query('decoded_rr'), isEmpty);
    final remaining = await db.query('decoded_onehz');
    expect(remaining.map((row) => row['rec_ts']), [other, other + 1]);
    expect((await LocalDb.baseline('sleep_user_profile'))!['payload_json'], learning,
        reason: 'learned state cannot be rebuilt once old input is pruned');
  });

  test('E16 selected-day export omits scratch and uses a fresh identity', () async {
    final db = await _storage();
    await edRows(edStart, edStart + 2);
    final other = DateTime(2020, 1, 3, 10).millisecondsSinceEpoch ~/ 1000;
    await edRows(other, other + 2);
    await db.insert('day_checkpoint', _sampleRow());
    final identity = await LocalDb.storeIdentity();
    final dir = await Directory.systemTemp.createTemp('ed2b_selected_export_');
    final provider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _CheckpointPaths(dir.path);
    try {
      final path = await LocalDb.exportDaysDb({edDay});
      final out = await databaseFactory.openDatabase(path, options: OpenDatabaseOptions(readOnly: true));
      try {
        expect(await _hasCheckpoint(out), isTrue);
        expect(await out.query('day_checkpoint'), isEmpty);
        expect((await out.query('store_identity')).single['id'], isNot(identity));
        expect((await out.query('decoded_onehz')).map((r) => r['rec_ts']), [edStart, edStart + 1]);
        expect(await LocalDb.storeIdentity(), identity);
        expect(await _rows(db), hasLength(1));
      } finally {
        await out.close();
      }
    } finally {
      PathProviderPlatform.instance = provider;
      await dir.delete(recursive: true);
    }
  });

  test('E16 checkpoint and RAM reuse cannot finalize or fingerprint a held night', () async {
    await _night();
    final later = DateTime(2020, 1, 5, 10).millisecondsSinceEpoch ~/ 1000;
    await edRows(later, later + 1);
    DerivationEngine.debugHoldTonight = {edDay};
    await _derive(DerivationEngine());
    expect(await _rows(await _storage()), hasLength(1));
    final engine = DerivationEngine();
    for (var i = 0; i < 2; i++) {
      await engine.run(edProfile, heavy: true);
      expect(await LocalDb.finalizedDayIds(kAlgoVersion), isNot(contains(edDay)));
      expect(await LocalDb.deriveFingerprint(edDay), isNull);
    }
    expect(engine.debugCheckpoints.hits, greaterThan(0),
        reason: 'the hold must survive actual disk adoption');
    DerivationEngine.debugHoldTonight = {};
    await engine.run(edProfile, heavy: true);
    expect(await LocalDb.finalizedDayIds(kAlgoVersion), contains(edDay));
  });

}
