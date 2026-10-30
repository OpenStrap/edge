// Report an issue: the OSR1 seal, the archive's manifest, and the screen's
// defaults.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/recent_slice.dart';
import 'package:openstrap_edge/support/issue_report.dart';
import 'package:openstrap_edge/support/report_crypto.dart';
import 'package:openstrap_edge/ui2/profile/report_issue.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _TempPaths extends PathProviderPlatform {
  _TempPaths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// writeReportZip into a temp file, returned as bytes.
Future<Uint8List> _zip(
    {bool shot = false, bool db = false, bool full = false, File? gz, int? rawDays}) async {
  final dir = await Directory.systemTemp.createTemp('zip');
  try {
    var dbGz = gz;
    if (dbGz == null && (db || full)) {
      dbGz = File('${dir.path}/x.db.gz')..writeAsBytesSync([4, 5]);
    }
    final f = await writeReportZip(
      '${dir.path}/r.zip',
      draft: ReportDraft(
        category: ReportCategory.sync,
        title: 'Sync stuck',
        description: 'It never finishes',
        screenshotPath: shot ? '/tmp/x/Shot.PNG' : null,
        includeDatabase: db,
        fullDatabase: full,
      ),
      meta: {'installId': '00000000-0000-4000-8000-000000000000'},
      device: {'band': {}},
      state: {'syncStatus': 'idle'},
      syncLog: 'line one\n',
      telemetry: const [],
      screenshot: shot ? Uint8List.fromList([1, 2, 3]) : null,
      databaseGz: dbGz,
      rawDays: rawDays,
    );
    return f.readAsBytesSync();
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  group('OSR1', () {
    test('layout against the shipped public key', () {
      final plain = Uint8List.fromList(utf8.encode('hello report'));
      final blob = osr1Encrypt(plain);
      expect(String.fromCharCodes(blob.sublist(0, 4)), 'OSR1');
      expect(blob[4], 0x04, reason: 'uncompressed P-256 point');
      expect(blob.length, 4 + 65 + 12 + plain.length + 16);
      // Fresh ephemeral key and nonce every time.
      expect(osr1Encrypt(plain).sublist(4, 81), isNot(blob.sublist(4, 81)));
    });

    test('round trip with a test keypair; a flipped byte fails the tag', () async {
      final pair = osr1TestKeyPair();
      final pub = (pair.publicKey as ECPublicKey).Q!.getEncoded(false);
      final priv = pair.privateKey as ECPrivateKey;
      final plain = await _zip();
      final blob = osr1Encrypt(plain, publicKeyB64: base64Encode(pub));
      expect(osr1Decrypt(blob, priv), plain);
      final bad = Uint8List.fromList(blob)..[blob.length - 1] ^= 1;
      expect(() => osr1Decrypt(bad, priv), throwsA(anything));
    });
  });

  test('sealReport encrypts file to file in a background isolate', () async {
    final dir = await Directory.systemTemp.createTemp('seal');
    addTearDown(() => dir.delete(recursive: true));
    // Past one 1 MB chunk and not a multiple of the AES block.
    final plain =
        Uint8List.fromList(List<int>.generate((1 << 20) * 2 + 37, (i) => i % 251));
    final zip = File('${dir.path}/r.zip')..writeAsBytesSync(plain);
    final blob = (await sealReport(zip)).readAsBytesSync();
    expect(String.fromCharCodes(blob.sublist(0, 4)), 'OSR1');
    expect(blob.length, kOsr1Overhead + plain.length);

    final pair = osr1TestKeyPair();
    final pub = base64Encode((pair.publicKey as ECPublicKey).Q!.getEncoded(false));
    osr1EncryptFile(zip.path, '${dir.path}/t.osr1', publicKeyB64: pub);
    expect(
        osr1Decrypt(File('${dir.path}/t.osr1').readAsBytesSync(),
            pair.privateKey as ECPrivateKey),
        plain);
  });

  test('server meta rides in a base64url header and carries rawDays', () {
    const d = ReportDraft(
        category: ReportCategory.sleep, title: 't', description: 'd',
        includeDatabase: true);
    final m = reportServerMeta(d, {'installId': 'x', 'rawDays': 7});
    expect(m['rawDays'], 7);
    final h = reportMetaHeader(m);
    expect(h, isNot(contains('=')));
    expect(jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(h)))), m);
    expect(reportServerMeta(const ReportDraft(
        category: ReportCategory.sleep, title: 't', description: 'd'),
        {'rawDays': 7}).containsKey('rawDays'), isFalse);
  });

  test('manifest lists exactly the files in the archive, same as the screen',
      () async {
    for (final (shot, db, full) in [
      (false, false, false),
      (true, false, false),
      (true, true, false),
      (false, false, true),
      (true, true, true),
    ]) {
      final a = ZipDecoder()
          .decodeBytes(await _zip(shot: shot, db: db, full: full, rawDays: 7));
      final manifest = jsonDecode(
              utf8.decode(a.findFile('manifest.json')!.content as List<int>))
          as Map<String, dynamic>;
      final listed = [
        for (final f in manifest['files'] as List) (f as Map)['path'] as String
      ];
      final expected = reportPaths(
          screenshotExt: shot ? 'png' : null, database: db, fullDatabase: full);
      expect(expected.last,
          full ? 'database.db.gz' : db ? 'database_14d.db.gz' : isNot(contains('.db')));
      expect(listed, expected);
      expect([for (final f in a.files) f.name], expected);
      for (final f in manifest['files'] as List) {
        expect((f as Map)['description'], isNotEmpty);
      }
      expect(manifest['rawDays'], db && !full ? 7 : isNull);
      if (db || full) {
        expect(a.files.last.content, [4, 5], reason: 'database copied in as is');
      }
    }
    // No health data unless the database is ticked.
    expect(reportPaths(), isNot(contains('database.db.gz')));
    expect(reportPaths(), isNot(contains('database_14d.db.gz')));
    // The manifest's English line for the slice says what it holds.
    final a = ZipDecoder().decodeBytes(await _zip(db: true));
    expect(utf8.decode(a.findFile('manifest.json')!.content as List<int>),
        contains('Last 14 days of health data, plus daily scores and settings'));
  });

  testWidgets('database switch is off and the list matches the manifest',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390 * 3, 3000 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const ReportIssueScreen()));
    await tester.pumpAndSettle();
    const slice = 'Include the last 2 weeks of health data';
    const full = 'Full health database (share locally only)';
    Switch sw(int i) => tester.widget<Switch>(find.byType(Switch).at(i));
    expect(find.text(slice), findsOneWidget);
    expect(find.text(full), findsOneWidget);
    expect(sw(0).value, isFalse);
    expect(sw(1).value, isFalse);
    expect(find.text('Create ticket'), findsOneWidget);
    expect(find.text('Share locally'), findsOneWidget);
    for (final path in reportPaths()) {
      expect(find.text(path), findsOneWidget, reason: path);
    }
    expect(find.text('database.db.gz'), findsNothing);

    BigButton ticket() => tester.widget<BigButton>(
        find.ancestor(of: find.text('Create ticket'), matching: find.byType(BigButton)));
    const noUpload =
        'The full database is too big to upload. Use Share locally and send the file to us.';

    await tester.tap(find.text(slice));
    await tester.pumpAndSettle();
    expect(sw(0).value, isTrue);
    expect(find.text('database_14d.db.gz'), findsOneWidget);
    expect(find.text('database.db.gz'), findsNothing);
    expect(ticket().onTap, isNotNull);

    // Full on: Create ticket is off, the 2-week switch is covered, and the
    // list shows the full file instead of the slice.
    await tester.tap(find.text(full));
    await tester.pumpAndSettle();
    expect(sw(1).value, isTrue);
    expect(ticket().onTap, isNull);
    expect(find.text(noUpload), findsOneWidget);
    expect(sw(0).value, isTrue);
    expect(sw(0).onChanged, isNull);
    expect(find.text('database.db.gz'), findsOneWidget);
    expect(find.text('database_14d.db.gz'), findsNothing);

    await tester.tap(find.text(full));
    await tester.pumpAndSettle();
    expect(ticket().onTap, isNotNull);
    expect(find.text(noUpload), findsNothing);
  });

  testWidgets('tapping a sent report asks before deleting it', (tester) async {
    final exp = DateTime.now().add(const Duration(days: 7)).toUtc();
    SharedPreferences.setMockInitialValues({
      'issue_reports_sent': jsonEncode([
        {'id': 'r-abc123', 'deleteToken': 't', 'expiresAt': exp.toIso8601String()}
      ]),
    });
    tester.view.physicalSize = const Size(390 * 3, 3000 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const ReportIssueScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('r-abc123'));
    await tester.pumpAndSettle();
    expect(find.text('Delete report r-abc123?'), findsOneWidget);
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(find.text('Delete report r-abc123?'), findsNothing);
    expect(find.text('r-abc123'), findsOneWidget);
    expect((await loadSentReports()).map((r) => r.id), ['r-abc123']);
  });

  test('local path has no size cap: a gzip past the upload limit builds a zip',
      () async {
    final dir = await Directory.systemTemp.createTemp('gz');
    addTearDown(() => dir.delete(recursive: true));
    final rnd = Random(1);
    final f = File('${dir.path}/db');
    final sink = f.openWrite();
    for (var i = 0; i < kReportMaxBytesWithDb ~/ (1 << 20) + 1; i++) {
      sink.add(List<int>.generate(1 << 20, (_) => rnd.nextInt(256)));
    }
    await sink.close();
    final gz = await gzipFile(f.path, '${dir.path}/db.gz');
    expect(gz.lengthSync(), greaterThan(kReportMaxBytesWithDb));
    final zip = await _zip(db: true, gz: gz);
    expect(zip.length, greaterThan(kReportMaxBytesWithDb));
  });

  test('stale report files left in temp are swept, others are kept', () async {
    final dir = await Directory.systemTemp.createTemp('sweep');
    addTearDown(() => dir.delete(recursive: true));
    final now = DateTime.now();
    final old = File('${dir.path}/openstrap_report_1.zip')..writeAsStringSync('db');
    old.setLastModifiedSync(now.subtract(const Duration(hours: 2)));
    final oldGz = File('${dir.path}/openstrap_report_2.db.gz')..writeAsStringSync('db');
    oldGz.setLastModifiedSync(now.subtract(const Duration(days: 3)));
    final fresh = File('${dir.path}/openstrap_report_3.zip')..writeAsStringSync('db');
    final other = File('${dir.path}/something_else.zip')..writeAsStringSync('x');
    other.setLastModifiedSync(now.subtract(const Duration(days: 3)));
    expect(await sweepStaleReports(dir.path, now: now), 2);
    expect(old.existsSync(), isFalse);
    expect(oldGz.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(other.existsSync(), isTrue);
    expect(await sweepStaleReports('${dir.path}/missing'), 0);
  });

  group('last-2-weeks slice', () {
    late Directory tmp;
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      tmp = await Directory.systemTemp.createTemp('slice');
      PathProviderPlatform.instance = _TempPaths(tmp.path);
      LocalDb.dbName = 'openstrap_slice_test.db';
      await deleteDatabase(
          p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
    });
    tearDownAll(() async {
      await LocalDb.close();
      await deleteDatabase(
          p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName));
      await tmp.delete(recursive: true);
    });

    test('every table in the schema is classified', () async {
      final db = await LocalDb.instance;
      final tables = [
        for (final r in await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata'"))
          r['name'] as String
      ];
      expect(tables.where((t) => !kSliceTables.containsKey(t)), isEmpty,
          reason: 'add new tables to kSliceTables in lib/data/recent_slice.dart');
      for (final t in tables) {
        final (keep, col, _) = kSliceTables[t]!;
        if (keep == SliceKeep.all || keep == SliceKeep.none) continue;
        if (col!.startsWith('(')) continue;
        final cols = {
          for (final c in await db.rawQuery('PRAGMA table_info("$t")'))
            c['name']
        };
        expect(cols, contains(col), reason: t);
      }
    });

    test('old raw rows go, recent stay, daily rows all stay, live untouched',
        () async {
      final db = await LocalDb.instance;
      final now = DateTime(2030, 1, 20, 12);
      final nowSec = now.millisecondsSinceEpoch ~/ 1000;
      final old = nowSec - 30 * 86400, recent = nowSec - 86400;
      for (final ts in [old, old + 1, recent, recent + 1]) {
        await db.insert('decoded_onehz', {
          'device_id': '',
          'ts_ms': ts * 1000,
          'rec_ts': ts,
          'counter': ts,
          'hr': 60,
        });
      }
      await db.insert('sync_ledger', {
        'chunk_id': 'old', 'kind': 'k', 'status': 's',
        'created_at': old * 1000, 'updated_at': old * 1000,
      });
      await db.insert('sync_ledger', {
        'chunk_id': 'new', 'kind': 'k', 'status': 's',
        'created_at': recent * 1000, 'updated_at': recent * 1000,
      });
      for (final day in ['2029-12-01', '2030-01-19']) {
        await db.insert('day_result', {
          'day_id': day, 'algo_version': 1, 'payload_json': '{}',
          'computed_at': nowSec, 'finalized': 1,
        });
      }
      Future<Map<String, int>> counts(Database d) async => {
            for (final t in ['decoded_onehz', 'sync_ledger', 'day_result'])
              t: (await d.rawQuery('SELECT COUNT(*) AS n FROM $t')).first['n']
                  as int,
          };
      final before = await counts(db);

      final path = await exportRecentSlice(now: now);
      addTearDown(() => deleteDatabase(path));
      final copy = await databaseFactory.openDatabase(path);
      addTearDown(copy.close);

      expect(await counts(copy),
          {'decoded_onehz': 2, 'sync_ledger': 1, 'day_result': 2});
      expect([
        for (final r in await copy.query('decoded_onehz', orderBy: 'rec_ts'))
          r['rec_ts']
      ], [recent, recent + 1]);
      expect(await counts(db), before, reason: 'live database untouched');

      // Fewer days of second-by-second data: only those tables shrink.
      final mid = nowSec - 5 * 86400;
      await db.insert('decoded_onehz', {
        'device_id': '', 'ts_ms': mid * 1000, 'rec_ts': mid, 'counter': mid, 'hr': 61,
      });
      await db.insert('sync_ledger', {
        'chunk_id': 'mid', 'kind': 'k', 'status': 's',
        'created_at': mid * 1000, 'updated_at': mid * 1000,
      });
      final narrow = await exportRecentSlice(now: now, rawDays: 3);
      addTearDown(() => deleteDatabase(narrow));
      final n = await databaseFactory.openDatabase(narrow);
      addTearDown(n.close);
      expect(await counts(n),
          {'decoded_onehz': 2, 'sync_ledger': 2, 'day_result': 2});
      await db.delete('decoded_onehz', where: 'rec_ts = ?', whereArgs: [mid]);
      await db.delete('sync_ledger', where: "chunk_id = 'mid'");
      // Same schema: every table, index, view and trigger, and user_version.
      Future<List<String>> schema(Database d) async => [
            for (final r in await d.rawQuery(
                "SELECT type || ':' || name AS n FROM sqlite_master "
                "WHERE name != 'android_metadata' ORDER BY 1"))
              r['n'] as String
          ];
      expect(await schema(copy), await schema(db));
      expect((await copy.rawQuery('PRAGMA user_version')).first.values.first,
          LocalDb.schemaVersion);
    });
  });
}
