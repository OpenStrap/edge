// E22 phase 1: RED contracts against upstream's writer-only implementation.
// Real files matter: separate :memory: handles do not share a WAL database.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/ble_engine.dart' show DrainController;
import 'package:openstrap_edge/compute/derivation_engine.dart' show DerivationEngine, kAlgoVersion;
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/models.dart';

const _wait = Duration(seconds: 2);
const _day = '2026-01-10';
typedef _Sql = ({int id, int? txn, String sql, SqliteSqlCommandType type});

Future<void> _putDay(String day, {double readiness = 61}) =>
    LocalDb.putDayResult(
      dayId: day, algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({'scalars': {'readiness': readiness, 'rhr': 55}}),
      windowJson: '{}', readiness: readiness,
      series: {'rhr': 55},
    );

RawRecord _raw(int counter) => RawRecord(
    counter: counter, packetType: 0x2f, hex: '2f18aabbccdd',
    capturedAt: 1750000000000 + counter, recTs: 1750000000 + counter);
Sample _sample(int counter) =>
    Sample(tsEpoch: 1750000000 + counter, counter: counter, hr: 60,
        rrIntervalsMs: [900, 910]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sql = <_Sql>[];
  final opens = <SqfliteLoggerDatabaseOpenEvent>[];
  final closes = <int>[];
  late Directory dir;
  late DatabaseFactory? savedFactory;
  late String savedPath;
  late String savedName;
  late LocalRepositoryImpl repo;
  var serial = 0;

  setUpAll(() async {
    sqfliteFfiInit();
    savedFactory = databaseFactoryOrNull;
    savedPath = await databaseFactoryFfi.getDatabasesPath();
    savedName = LocalDb.dbName;
    dir = await Directory.systemTemp.createTemp('e22_wal_reader_');
    await databaseFactoryFfi.setDatabasesPath(dir.path);
    // ignore: experimental_member_use
    databaseFactory = SqfliteDatabaseFactoryLogger(databaseFactoryFfi,
      options: SqfliteLoggerOptions(log: (event) {
        if (event is SqfliteLoggerSqlEvent) {
          sql.add((id: event.databaseId, txn: event.transactionId,
              sql: event.sql.toLowerCase(), type: event.type));
        } else if (event is SqfliteLoggerBatchEvent) {
          for (final op in event.operations) {
            sql.add((id: event.databaseId, txn: event.transactionId,
                sql: op.sql.toLowerCase(), type: op.type));
          }
        } else if (event is SqfliteLoggerDatabaseOpenEvent) {
          opens.add(event);
        } else if (event is SqfliteLoggerDatabaseCloseEvent) {
          closes.add(event.databaseId);
        }
      }),
    );
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.debugReaderOpener = null;
    LocalDb.lastRebuild = null;
    await LocalDb.setForeground(false);
    LocalDb.dbName = 'reader_${serial++}.db';
    sql.clear();
    opens.clear();
    closes.clear();
    repo = LocalRepositoryImpl(getProfileMap: () => const {});
    await LocalDb.setForeground(true);
  });
  tearDown(() async {
    DerivationEngine.debugSecondHalfHook = null;
    LocalDb.debugReaderOpener = null;
    LocalDb.debugBeforeOrphanPinClear = null;
    await LocalDb.setForeground(false);
    await LocalDb.close();
    // Includes a handle opened by a delayed test opener if publication failed.
    for (final event in opens) {
      if (event.db?.isOpen ?? false) await event.db!.close();
    }
  });
  tearDownAll(() async {
    await LocalDb.close();
    LocalDb.dbName = savedName;
    databaseFactoryOrNull = savedFactory;
    await databaseFactoryFfi.setDatabasesPath(savedPath);
    await dir.delete(recursive: true);
  });

  int idOf(Database db) => opens.lastWhere((e) => identical(e.db, db)).databaseId!;

  Future<int> writerId() async => idOf(await LocalDb.instance);

  Future<void> readerQueries(String table, int writer) async {
    final hits = sql.where((e) => e.type == SqliteSqlCommandType.query &&
        RegExp('\\bfrom\\s+$table\\b').hasMatch(e.sql)).toList();
    expect(hits, isNotEmpty, reason: 'fixture must exercise $table');
    expect(hits.map((e) => e.id), everyElement(isNot(writer)),
        reason: '$table screen SELECT must use the second connection');
    expect(hits.map((e) => e.id), everyElement(idOf(await LocalDb.readExecutor())),
        reason: "$table must use LocalDb's owned reader handle");
  }

  // Release the writer even when a screen read times out on upstream, then
  // drain that read before teardown. A failing RED test must not wedge SQLite.
  Future<void> holdingWrite(Future<void> Function() body,
      {bool rollback = false}) async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final writer = await LocalDb.instance;
    final holding = writer.transaction((tx) async {
      await tx.insert('day_result', {
        'day_id': '2026-01-11', 'algo_version': kAlgoVersion,
        'payload_json': '{"scalars":{"readiness":88}}',
        'window_json': '{}', 'computed_at': 1, 'readiness': 88,
      });
      entered.complete();
      await release.future;
      if (rollback) throw StateError('intentional rollback');
    });
    final settled = holding.then<Object?>((_) => null,
        onError: (Object e, StackTrace s) => e);
    try {
      await entered.future.timeout(_wait);
      await body();
    } finally {
      release.complete();
      final outcome = await settled.timeout(_wait);
      if (!rollback && outcome != null) throw outcome;
      if (rollback) expect(outcome, isA<StateError>());
    }
  }

  test('reader is a lazy second handle to the same WAL file', () async {
    final writer = await LocalDb.instance;
    expect(opens, hasLength(1));
    await LocalDb.setForeground(true);
    expect(opens, hasLength(1), reason: 'foreground only permits lazy opening');
    final reader = await LocalDb.readExecutor();
    expect(identical(reader, writer), isFalse,
        reason: 'upstream serializes all reads on the writer');
    expect(opens, hasLength(2));
    expect(reader.path, writer.path);
    final files = await reader.rawQuery('PRAGMA database_list');
    expect(files.firstWhere((r) => r['name'] == 'main')['file'], writer.path);
    final option = opens.last.options!;
    expect(option.singleInstance, isFalse);
    expect(option.readOnly, isFalse, reason: 'WAL may need to create -shm');
    expect(option.version, isNull);
    expect(option.onCreate, isNull);
    expect(option.onUpgrade, isNull);
    expect(option.onOpen, isNull, reason: 'repair belongs only to writer');
    final readerId = idOf(reader);
    final wal = sql.where((e) => e.id == readerId &&
        e.sql.startsWith('pragma journal_mode')).toList();
    expect(wal, isNotEmpty, reason: 'verify WAL before publishing reader');
    expect(wal.map((e) => e.type), everyElement(SqliteSqlCommandType.query));
    expect((await reader.rawQuery('PRAGMA journal_mode')).first.values.first, 'wal');
  });

  test('cold reader waits for writer open and same-version schema repair', () async {
    final writer = await LocalDb.instance;
    final path = writer.path;
    await writer.execute('DROP TABLE metric_method');
    await LocalDb.close();
    opens.clear();
    final reader = await LocalDb.readExecutor();
    expect((await reader.rawQuery('PRAGMA user_version')).first.values.first,
        LocalDb.schemaVersion);
    expect(await reader.rawQuery("SELECT name FROM sqlite_master "
        "WHERE type='table' AND name='metric_method'"), hasLength(1));
    expect(opens, hasLength(2), reason: 'writer repair must precede second open');
    expect(opens.first.path, path);
    expect(opens.first.options!.onOpen, isNotNull);
    expect(opens.last.options!.onOpen, isNull);
  });

  test('query_only rejects a write through the reader', () async {
    final reader = await LocalDb.readExecutor();
    await expectLater(reader.insert('sync_cursor',
        {'name': 'reader_must_not_write', 'value': 'x', 'updated_at': 1}),
        throwsA(isA<DatabaseException>()));
    expect((await reader.rawQuery('PRAGMA query_only')).first.values.first, 1);
    expect(await LocalDb.getCursor('reader_must_not_write'), isNull);
  });

  test('screen read completes during held write and sees only committed rows', () async {
    await _putDay(_day);
    // Open the reader before taking the write lock; opening is tested above.
    await LocalDb.readExecutor();
    Future<Map<String, dynamic>>? pending;
    try {
      await holdingWrite(() async {
        pending = repo.getDayOverview(_day);
        expect((await pending!.timeout(_wait))['readiness'], 61);
        pending = repo.getDayOverview('2026-01-11');
        expect(await pending!.timeout(_wait), isEmpty,
            reason: 'in-flight insert is invisible to the reader');
      });
    } finally {
      await pending;
    }
  });

  test('a new routed read sees a completed writer commit', () async {
    await _putDay(_day);
    final writer = await writerId();
    await repo.getDayOverview(_day); // establish the first snapshot
    await _putDay('2026-01-11', readiness: 88);
    sql.clear();
    expect((await repo.getDayOverview('2026-01-11'))['readiness'], 88);
    await readerQueries('day_result', writer);
  });

  test('derive bookkeeping uses writer despite an older reader snapshot', () async {
    await _putDay(_day);
    await LocalDb.putDeriveFingerprint(_day, 'before');
    final writer = await LocalDb.instance;
    final reader = await LocalDb.readExecutor();
    final start = DateTime(2026, 1, 10).millisecondsSinceEpoch ~/ 1000;
    Future<String?> signature() => LocalDb.dayInputSignature(
        dayId: _day, prevDayId: '2026-01-09', nextDayId: '2026-01-11',
        fromSec: start, toSec: start + 3600, wearableDeviceId: null);
    final before = await signature();
    expect(before, isNotNull);
    await reader.execute('BEGIN');
    try {
      expect((await reader.query('day_result')).single['readiness'], 61);
      await _putDay(_day, readiness: 88);
      await writer.update('day_result', {'finalized': 1});
      await LocalDb.putDeriveFingerprint(_day, 'after');
      // Keep a real older WAL snapshot alive while the bookkeeping reads.
      expect((await reader.query('day_result')).single['readiness'], 61);
      sql.clear();
      expect(await signature(), isNot(before));
      expect(await LocalDb.deriveFingerprint(_day), 'after');
      expect(await LocalDb.finalizedDayIds(kAlgoVersion), {_day});
      final reads = sql.where((e) => e.type == SqliteSqlCommandType.query);
      expect(reads, isNotEmpty);
      expect(reads.map((e) => e.id), everyElement(idOf(writer)),
          reason: 'derive decisions must read the state committed on the writer');
    } finally {
      await reader.execute('ROLLBACK');
    }
  });

  test('an old day waits for the next night before finalizing', () async {
    SharedPreferences.setMockInitialValues({});
    final writer = await LocalDb.instance;
    int sec(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
    final evening = sec(DateTime(2026, 1, 10, 18));
    final onset = sec(DateTime(2026, 1, 10, 23));
    final wake = sec(DateTime(2026, 1, 11, 7));
    final edge = sec(DateTime(2026, 1, 14, 12));
    for (final t in [evening, onset + 1800, wake, edge]) {
      await writer.insert('decoded_onehz', {
        'ts_ms': t * 1000, 'rec_ts': t, 'counter': t, 'hr': 60,
        'ax': 0, 'ay': 0, 'az': 1, 'on_wrist': 1, 'hr_valid': 1,
        'device_family': 'gen4',
      });
    }
    const profile = Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
    final engine = DerivationEngine();
    Future<void> derive() async {
      expect(await engine.runDays(profile, {_day}, force: false), 1);
      expect((await LocalDb.dayResult(_day))!['partial'], 0);
    }
    await derive();
    expect((await LocalDb.dayResult(_day))!['finalized'], 0,
        reason: 'the next day has raw but has not stored its night yet');

    final reader = await LocalDb.readExecutor();
    await reader.execute('BEGIN');
    try {
      expect(await reader.query('day_result', where: 'day_id = ?',
          whereArgs: ['2026-01-11']), isEmpty);
      // The next night commits after preparation, before this day's persist.
      DerivationEngine.debugSecondHalfHook = (_) => LocalDb.putDayResult(
        dayId: '2026-01-11', algoVersion: kAlgoVersion,
        payloadJson: '{}',
        windowJson: jsonEncode({'onset_ms': onset * 1000, 'offset_ms': wake * 1000}),
      );
      await derive();
      expect((await LocalDb.dayResult(_day))!['finalized'], 0,
          reason: 'this pass did not consume the night that just committed');
      DerivationEngine.debugSecondHalfHook = null;
      await derive();
      expect((await LocalDb.dayResult(_day))!['finalized'], 1,
          reason: 'a pass using the committed next night may finalize');
      final bundle = jsonDecode((await LocalDb.dayResult(_day))!['payload_json'] as String);
      expect(bundle['clinical']['hr_dip']['note'], contains('have day=1, night=0'),
          reason: 'the 23:30 sample is tonight\'s sleep, not daytime input');
      expect(await reader.query('day_result', where: 'day_id = ?',
          whereArgs: ['2026-01-11']), isEmpty,
          reason: 'derive decisions must use the writer despite this older snapshot');
      await writer.delete('day_result', where: 'day_id = ?',
          whereArgs: ['2026-01-11']);
      await writer.delete('decoded_onehz', where: 'rec_ts = ?', whereArgs: [wake]);
      expect(await engine.runDays(profile, {_day}, force: true), 1);
      expect((await LocalDb.dayResult(_day))!['finalized'], 1,
          reason: 'a gap with no next-day input must not hold finalization');
    } finally {
      await reader.execute('ROLLBACK');
    }
  });

  test('rolled-back rows never become visible on the reader', () async {
    await _putDay(_day);
    await LocalDb.readExecutor();
    Future<Map<String, dynamic>>? pending;
    try {
      await holdingWrite(() async {
        pending = repo.getDayOverview('2026-01-11');
        expect(await pending!.timeout(_wait), isEmpty);
      }, rollback: true);
    } finally {
      await pending;
    }
    expect(await repo.getDayOverview('2026-01-11'), isEmpty);
  });

  test('failed reader open falls back to writer and returns stored values', () async {
    await _putDay(_day);
    var attempted = 0;
    LocalDb.debugReaderOpener = (path) async {
      attempted++;
      throw StateError('simulated reader open failure');
    };
    final writer = await writerId();
    sql.clear();
    expect((await repo.getDayOverview(_day))['readiness'], 61);
    expect(attempted, greaterThan(0), reason: 'must exercise the failed open');
    expect(sql.where((e) => e.sql.contains('from day_result')).map((e) => e.id),
        everyElement(writer));
    expect(opens.where((e) => e.db?.isOpen ?? false), hasLength(1));
  });

  test('failed reader open retries after background, not on every read', () async {
    await _putDay(_day);
    var attempted = 0;
    LocalDb.debugReaderOpener = (path) async {
      attempted++;
      throw StateError('simulated reader open failure');
    };
    await repo.getDayOverview(_day);
    await repo.getDayOverview(_day);
    expect(attempted, 1, reason: 'a broken open is not retried per screen read');
    await LocalDb.setForeground(false);
    await LocalDb.setForeground(true);
    LocalDb.debugReaderOpener = null;
    final writer = await LocalDb.instance;
    final reader = await LocalDb.readExecutor();
    expect(identical(reader, writer), isFalse, reason: 'next foreground retries');
  });

  test('a throwing reader close neither fails backgrounding nor blocks close', () async {
    LocalDb.debugReaderOpener = (path) async => _CloseThrows(
        await databaseFactory.openDatabase(path,
            options: OpenDatabaseOptions(singleInstance: false)));
    final writer = await LocalDb.instance;
    final reader = await LocalDb.readExecutor();
    expect(reader, isA<_CloseThrows>());
    await LocalDb.setForeground(false);
    await LocalDb.setForeground(true);
    await LocalDb.close();
    expect(writer.isOpen, isFalse, reason: 'close must still reach the writer');
  });

  test('non-WAL reader is rejected and closed before fallback', () async {
    await _putDay(_day);
    final writer = await LocalDb.instance;
    await writer.rawQuery('PRAGMA journal_mode=DELETE');
    Database? candidate;
    LocalDb.debugReaderOpener = (path) async => candidate =
        await databaseFactory.openDatabase(path,
            options: OpenDatabaseOptions(singleInstance: false));
    expect((await repo.getDayOverview(_day))['readiness'], 61);
    expect(candidate, isNotNull, reason: 'must attempt the second open');
    expect(candidate!.isOpen, isFalse, reason: 'failed candidate must not leak');
    expect(await LocalDb.readExecutor(), same(writer));
  });

  test('background reads use writer; resume permits a lazy fresh reader', () async {
    final writer = await LocalDb.instance;
    await LocalDb.setForeground(false);
    expect(await LocalDb.readExecutor(), same(writer));
    expect(opens, hasLength(1));
    await LocalDb.setForeground(true);
    expect(opens, hasLength(1));
    final reader = await LocalDb.readExecutor();
    expect(identical(reader, writer), isFalse);
    await LocalDb.setForeground(false);
    expect(reader.isOpen, isFalse);
    expect(writer.isOpen, isTrue);
    expect(await LocalDb.readExecutor(), same(writer));
    await LocalDb.setForeground(true);
    expect(opens, hasLength(2), reason: 'resume does not eagerly reopen');
    final reopened = await LocalDb.readExecutor();
    expect(identical(reopened, reader), isFalse);
    expect(identical(reopened, writer), isFalse);
  });

  test('LocalDb.close closes reader before writer', () async {
    final writer = await writerId();
    final reader = idOf(await LocalDb.readExecutor());
    closes.clear();
    await LocalDb.close();
    expect(closes, [reader, writer], reason: 'reader must not outlive its file owner');
  });

  for (final background in [true, false]) {
    test('${background ? 'background' : 'close'} drains an in-flight read lease', () async {
      await _putDay(_day);
      final entered = Completer<void>();
      final release = Completer<void>();
      final reading = LocalDb.withReadExecutor((db) async {
        entered.complete();
        await release.future;
        return db.query('day_result', where: 'day_id = ?', whereArgs: [_day]);
      }).then<Object?>((rows) => rows, onError: (Object e, StackTrace s) => e);
      await entered.future.timeout(_wait);
      var finished = false;
      final closing = (background ? LocalDb.setForeground(false) : LocalDb.close())
          .then((_) => finished = true);
      Object? result;
      try {
        // Only a failure bound. The lease/release completers define ordering.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(finished, isFalse, reason: 'close must wait for the active lease');
      } finally {
        release.complete();
        result = await reading.timeout(_wait);
        await closing.timeout(_wait);
      }
      expect(result, isA<List<Map<String, Object?>>>(),
          reason: 'the leased query must never run on a closed handle');
      expect(opens.where((e) => e.db?.isOpen ?? false),
          hasLength(background ? 1 : 0));
    });

    test('${background ? 'background' : 'close'} invalidates a pending reader open', () async {
      await _putDay(_day);
      final entered = Completer<void>();
      final release = Completer<void>();
      Database? candidate;
      LocalDb.debugReaderOpener = (path) async {
        final opened = await databaseFactory.openDatabase(path,
            options: OpenDatabaseOptions(singleInstance: false));
        candidate = opened;
        entered.complete();
        await release.future;
        return opened;
      };
      final reading = LocalDb.withReadExecutor((db) => db.query('day_result'))
          .then<Object?>((rows) => rows, onError: (Object e, StackTrace s) => e);
      Future<void>? closing;
      Object? result;
      try {
        await entered.future.timeout(_wait,
            onTimeout: () => fail('reader opener was never called'));
        closing = background ? LocalDb.setForeground(false) : LocalDb.close();
        await Future<void>.delayed(Duration.zero);
      } finally {
        release.complete();
        result = await reading.timeout(_wait);
        await closing?.timeout(_wait);
      }
      expect(result, isA<List<Map<String, Object?>>>(),
          reason: 'pending screen read must finish safely before shutdown');
      expect(candidate!.isOpen, isFalse, reason: 'stale opening must not leak');
      expect(opens.where((e) => e.db?.isOpen ?? false),
          hasLength(background ? 1 : 0));
    });
  }

  test('wipe invalidates the reader and the next read sees the empty store', () async {
    await _putDay(_day);
    final reader = await LocalDb.readExecutor();
    await LocalDb.wipeAll();
    expect(reader.isOpen, isFalse, reason: 'store reset invalidates reader');
    expect(await repo.getDayOverview(_day), isEmpty);
    expect(identical(await LocalDb.readExecutor(), reader), isFalse);
  });

  test('restore merge invalidates the reader and exposes restored rows', () async {
    await _putDay(_day);
    final writer = await LocalDb.instance;
    // This backup is a real current-schema file, not a hand-built partial schema.
    await writer.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    final backup = p.join(dir.path, 'restore_$serial.db');
    await File(writer.path).copy(backup);
    await LocalDb.wipeAll();
    final reader = await LocalDb.readExecutor();
    await LocalDb.importFromDbFile(backup);
    expect(reader.isOpen, isFalse, reason: 'merge invalidates old screen handle');
    expect((await repo.getDayOverview(_day))['readiness'], 61);
  });

  test('writer reopen retires an old reader before opening the file again',
      () async {
    // _openWriter retires the reader before _openOrRebuild touches the file,
    // which is what keeps a rebuild from quarantining a file a reader still
    // holds. A rebuild cannot be forced here: closing the live reader
    // checkpoints its WAL frames back into the main file first.
    await _putDay(_day);
    final writer = await LocalDb.instance;
    final reader = await LocalDb.readExecutor();
    expect(identical(reader, writer), isFalse, reason: 'needs a live reader');
    await writer.close();
    final reopened = await LocalDb.instance;
    expect(identical(reopened, writer), isFalse);
    expect(reader.isOpen, isFalse, reason: 'a reopened writer cannot keep the old reader');
    expect((await repo.getDayOverview(_day))['readiness'], 61);
    expect(identical(await LocalDb.readExecutor(), reader), isFalse);
  });

  // Explicit screen allow-list. Default LocalDb callers below remain writers.
  final routes = <({String name, Future<Object?> Function() read, List<String> tables})>[
    (name: '_bundle/dayResult', read: () => repo.getDayOverview(_day),
        tables: ['day_result']),
    (name: '_latestBundle/recentDayResults', read: () => repo.getDayOverview(todayLabel()),
        tables: ['day_result']),
    (name: '_crossDayArtifact/baseline', read: () => repo.getInsights(),
        tables: ['baselines', 'metric_method']),
    (name: 'availableDays/availableDayIds', read: () => repo.availableDays(),
        tables: ['day_result']),
    (name: 'sleepWindows/sleepWindowRows', read: () => repo.sleepWindows(),
        tables: ['day_result']),
    (name: 'getChart/series+provenance', read: () => repo.getChart('rhr'),
        tables: ['metric_series', 'metric_series_version', 'metric_method']),
    (name: 'getDayTimeline/events+sessions', read: () => repo.getDayTimeline(_day),
        tables: ['day_result', 'events', 'sessions', 'session_sensor', 'decoded_onehz']),
    (name: 'getSessions/sessionsInRange', read: () => repo.getSessions(from: 0, to: 1 << 40),
        tables: ['sessions', 'session_sensor', 'decoded_onehz']),
  ];
  for (final route in routes) {
    test('routes ${route.name} through reader', () async {
      await _putDay(_day);
      await LocalDb.putBaseline('crossday', '{}');
      final writer = await LocalDb.instance;
      await writer.insert('sessions', {'id': 's', 'start_ts': localDayStartSec(_day)!,
        'end_ts': localDayStartSec(_day)! + 60, 'status': 'done',
        'type': 'run', 'created_at': 1});
      final id = idOf(writer);
      sql.clear();
      await route.read();
      for (final table in route.tables) {
        await readerQueries(table, id);
      }
    });
  }

  test('routes getChart multi-device coverage through reader', () async {
    await _putDay(_day);
    final writer = await LocalDb.instance;
    await writer.insert('metric_series_version',
        {'date': _day, 'algo_version': kAlgoVersion, 'coverage_devices': 'a,b'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    final noon = localDayStartSec(_day)! + 12 * 3600;
    await writer.insert('device_coverage', {'device_id': 'b', 'signal': 'hr',
      'start_ts': noon, 'end_ts': noon + 3600});
    final id = idOf(writer);
    sql.clear();
    final chart = await repo.getChart('rhr', signals: {'hr'});
    expect(chart['coverage_recording'], isNotEmpty, reason: 'fixture must query coverage');
    await readerQueries('device_coverage', id);
  });

  test('shared LocalDb helpers still use writer by default for compute', () async {
    await _putDay(_day);
    await LocalDb.readExecutor();
    final writer = await writerId();
    sql.clear();
    await LocalDb.dayResult(_day);
    await LocalDb.recentDayResults(2);
    await LocalDb.availableDayIds();
    await LocalDb.sleepWindowRows(2);
    await LocalDb.baseline('crossday');
    await LocalDb.metricSeries('rhr');
    await LocalDb.metricSeriesVersions();
    await LocalDb.metricNotOursDates('rhr');
    await LocalDb.eventsInRange(0, 1 << 40);
    await LocalDb.sessionsInRange(0, 1 << 40);
    expect(sql, isNotEmpty);
    expect(sql.map((e) => e.id), everyElement(writer));
  });

  test('getToday freshness refresh and reread stay on writer', () async {
    await LocalDb.readExecutor();
    final writer = await writerId();
    sql.clear();
    final before = todayLabel();
    await repo.getToday(); // missing freshness triggers the real refresh
    final after = todayLabel();
    final freshness = sql.where((e) => e.sql.contains('compute_freshness')).toList();
    expect(freshness.any((e) => e.type == SqliteSqlCommandType.insert), isTrue);
    expect(freshness.where((e) => e.type == SqliteSqlCommandType.query).length,
        greaterThanOrEqualTo(2));
    expect(freshness.map((e) => e.id), everyElement(writer));
    final refreshed = await LocalDb.computeFreshness('today');
    expect(jsonDecode(refreshed!['payload_json'] as String)['today_day'], anyOf(before, after));
  });

  test('frozenHeadline orphan lookup and compare-delete stay on writer', () async {
    await LocalDb.setCursor(LocalDb.kFrozenHeadlineCursor,
        '{"day":"2026-01-01","value":71}');
    await LocalDb.readExecutor();
    final writer = await writerId();
    sql.clear();
    expect(await LocalDb.frozenHeadline(), isNull);
    expect(sql.any((e) => e.type == SqliteSqlCommandType.delete &&
        e.sql.contains('sync_cursor')), isTrue);
    expect(sql.map((e) => e.id), everyElement(writer));
    expect(await LocalDb.getCursor(LocalDb.kFrozenHeadlineCursor), isNull);
  });

  for (final failing in [false, true]) {
    test('safe-trim ${failing ? 'rollback' : 'commit'} keeps FULL bracket on writer', () async {
      await LocalDb.readExecutor();
      final writer = await writerId();
      final handle = await LocalDb.instance;
      if (failing) {
        await handle.execute('CREATE TRIGGER refuse_cursor BEFORE INSERT ON sync_cursor '
            "WHEN new.name = 'strap_trim' BEGIN SELECT RAISE(ABORT, 'refuse trim'); END");
      }
      final d = DrainController(onRecord: (sample, raw) async {},
        onRecordsBatch: null, onArchive: null, log: (_) {},
        onCommit: (raws, samples, token, {archives, ecgRawPackets, deviceFamily}) =>
            LocalDb.commitSyncBatch(raws, samples, trimToken: token,
                archives: archives, ecgRawPackets: ecgRawPackets, deviceFamily: deviceFamily));
      d.onHistoricalRecord(_raw(5001), _sample(5001), 24);
      sql.clear();
      final durable = await d.commit(const [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(durable, !failing, reason: 'false must withhold the engine ACK');
      final bracket = sql.where((e) => e.sql.startsWith('pragma synchronous=')).toList();
      expect(bracket.map((e) => e.sql), ['pragma synchronous=full', 'pragma synchronous=normal']);
      expect(bracket.map((e) => e.id), everyElement(writer));
      final boundary = sql.where((e) => e.sql.startsWith('begin') ||
          e.sql == 'commit' || e.sql == 'rollback').toList();
      expect(boundary, isNotEmpty);
      expect(boundary.map((e) => e.id), everyElement(writer));
      expect(sql.indexOf(bracket.first), lessThan(sql.indexOf(boundary.first)));
      expect(sql.indexOf(bracket.last), greaterThan(sql.indexOf(boundary.last)));
      expect((await handle.rawQuery('PRAGMA synchronous')).first.values.first, 1);
      expect(await LocalDb.getCursor('strap_trim'), failing ? null : '0102030405060708');
      final rows = await handle.query('decoded_onehz', where: 'counter = 5001');
      expect(rows, hasLength(failing ? 0 : 1));
      final beats = await handle.query('decoded_rr',
          where: 'device_id = ? AND ts_ms = ?', whereArgs: ['', 1750005001000]);
      expect(beats, hasLength(failing ? 0 : 2));
      expect(await LocalDb.getCursorInt('counter_hw'), failing ? null : 5001);
      expect(d.bufferedRecords, failing ? 1 : 0);
      if (!failing) {
        final writes = sql.where((e) => e.type == SqliteSqlCommandType.insert &&
            (e.sql.contains('decoded_onehz') || e.sql.contains('decoded_rr') ||
                e.sql.contains('sync_cursor'))).toList();
        expect(writes.any((e) => e.sql.contains('decoded_onehz')), isTrue);
        expect(writes.any((e) => e.sql.contains('decoded_rr')), isTrue);
        expect(writes.any((e) => e.sql.contains('sync_cursor')), isTrue);
        expect(writes.map((e) => e.id), everyElement(writer));
        expect(writes.first.txn, isNotNull);
        expect(writes.map((e) => e.txn).toSet(), {writes.first.txn},
            reason: 'decoded seconds, beats and ACK cursor share the durable transaction');
      }
    });
  }
}

// A reader whose native handle is already gone: close() throws, as on Android.
class _CloseThrows implements Database {
  _CloseThrows(this._db);
  final Database _db;
  @override
  String get path => _db.path;
  @override
  bool get isOpen => _db.isOpen;
  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      _db.execute(sql, arguments);
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      _db.rawQuery(sql, arguments);
  @override
  Future<void> close() async {
    await _db.close();
    throw StateError('simulated native close failure');
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

