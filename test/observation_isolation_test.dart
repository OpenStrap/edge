// THE INVARIANT that the `observation` table exists to have.
//
// OBSERVATION_SPEC §3: *nothing reads `observation` into a baseline, into a
// trend that also contains derived values, or into any input to a derivation.*
//
// The table is easy. The guarantee is the work, because a violation of it is
// SILENT — no exception, no wrong-looking row, just an unexplained step change
// in a 28- or 90-day number that surfaces months later with no way to tell
// which day broke it. This project has re-encountered that exact failure mode
// (the duplicate-day baseline pollution behind the blank readiness ring), and
// the lesson banked from it was that a comment saying "don't" is not a control.
//
// Three layers, each reusing a mechanism this repo already has:
//
//  1. STRUCTURAL — the table name may only be reached from `lib/data/db.dart`.
//     Uses the same source scan the other structural tests are built on. This
//     is the layer that catches the realistic violation: phase 4 adds a reader
//     for the UI, and six months later someone joins it into a series.
//  2. DIFFERENTIAL — every baseline / trend / derivation read in the app is
//     snapshotted, poison observations are written on the SAME dates under the
//     SAME key names with absurd values, and every read must come back
//     byte-identical. This is the layer that catches a violation added INSIDE
//     db.dart, where layer 1 cannot see.
//  3. THE COACH BTREE GATE — already fail-closed on anything outside the coach
//     views, so it needs no code. Asserted here so that adding `observation`
//     to a `v_*` view (the one edit that would open it to an LLM prompt) goes
//     red instead of shipping.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/coach/coach_db.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// `exportCopy` writes a real file, so the backup round trip needs somewhere
/// to put it.
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

/// The ONLY files allowed to name the `observation` table.
///
/// Adding to this list is the deliberate act the invariant asks for. Before
/// you do: a READER for the UI is fine (§6 — show their number, attributed).
/// A reader that feeds `metric_series`, `day_result`, a `baselines` row, a
/// rolling window, or any argument to an analytics function is the thing this
/// whole file exists to stop.
const _allowedToNameTheTable = {'lib/data/db.dart'};

/// How a Dart file actually reaches a SQLite table: as a quoted table name
/// handed to sqflite, or named in SQL text. Case-insensitive on the keyword,
/// case-SENSITIVE on the table name so `ui2/grammar.dart`'s `Observation`
/// widget (a different thing that is correctly named the same word) is not a
/// match.
///
/// `'observation':` is excluded — a trailing colon is a Dart MAP KEY and never
/// a table name. `ui2/profile/gallery.dart` keys its widget catalogue that way.
final _reachesTable = RegExp(
  r"""(?:['"]observation['"](?!\s*:))"""
  r"""|(?:\b(?:from|join|into|update|table)\s+observation\b)""",
  caseSensitive: false,
);

/// `observation` is lower-case in every table-name position; the widget is not.
bool _namesTheTable(String line) =>
    _reachesTable.hasMatch(line) && line.contains('observation');

/// A line that is nothing but a comment cannot reach a table.
final _pureComment = RegExp(r'^\s*(///|//|\*|/\*)');

Observation _obs(
  String iso,
  String key,
  double v, {
  ObservationSource kind = ObservationSource.vendor,
}) => Observation(
  key: key,
  value: v,
  unit: 'x',
  attribution: 'Amazfit',
  at: DateTime.parse(iso),
  sourceKind: kind,
);

Future<void> _measured(String date, double rhr, double lnRmssd) =>
    LocalDb.putDayResult(
      dayId: date,
      algoVersion: 1,
      payloadJson: '{"date":"$date"}',
      windowJson: '{}',
      finalized: true,
      source: 'band',
      rhr: rhr,
      series: {'rhr': rhr, 'ln_rmssd': lnRmssd, 'readiness': 60},
    );

/// Every read in the app that a baseline, a trend or a derivation runs on.
/// Rendered to a single string so a difference of any kind fails.
Future<String> _everyDerivedRead() async {
  final db = await LocalDb.instance;
  final out = StringBuffer();
  for (final key in const ['rhr', 'ln_rmssd', 'readiness', 'skin_temp_adc']) {
    // The production rolling-baseline loader itself, not a stand-in.
    out.writeln('window($key)=${await debugBaselineWindow(key)}');
    out.writeln('trail($key)=${await LocalDb.trailingSeriesValues(key, 90)}');
    out.writeln(
      'trailAll($key)='
      '${await LocalDb.trailingSeriesValues(key, 90, measuredOnly: false)}',
    );
    out.writeln('series($key)=${await LocalDb.metricSeries(key)}');
    out.writeln(
      'seriesMeasured($key)='
      '${await LocalDb.metricSeries(key, measuredOnly: true)}',
    );
    out.writeln('baseline($key)=${await LocalDb.baseline(key)}');
  }
  out.writeln('importedDates=${(await LocalDb.importedDates()).toList()..sort()}');
  // The frozen day bundles: a vendor scalar reaching one is spec §7's first
  // "must never happen".
  for (final r in await db.query('day_result', orderBy: 'day_id')) {
    out.writeln('day ${r['day_id']}|${r['algo_version']}=${r['payload_json']}');
  }
  for (final r in await db.query('metric_series', orderBy: 'date, key')) {
    out.writeln('ms ${r['date']}|${r['key']}=${r['value']}');
  }
  return out.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  // ── LAYER 1 — structural ────────────────────────────────────────────────────
  test('only lib/data/db.dart may reach the observation table', () {
    final offenders = <String>[];
    for (final e in Directory('lib').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final rel = p.relative(e.path).replaceAll(r'\', '/');
      if (_allowedToNameTheTable.contains(rel)) continue;
      final lines = e.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_pureComment.hasMatch(lines[i])) continue;
        if (_namesTheTable(lines[i])) offenders.add('$rel:${i + 1}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'A vendor/typed-in/imported scalar must never reach a baseline, a '
          'mixed trend, or a derivation input (OBSERVATION_SPEC §3). If this '
          'is a DISPLAY reader, add the file to _allowedToNameTheTable and say '
          'in its doc comment that nothing computed reads it. If it feeds a '
          'number we compute, it is the bug this test exists to catch.',
    );
  });

  test('the scanner would actually catch a violation', () {
    // A guard whose primitive is broken fails green. These are the shapes a
    // real violation takes.
    for (final line in const [
      "    final rows = await db.query('observation');",
      '  "SELECT value FROM observation WHERE key = ?",',
      "      'JOIN observation o ON o.date = m.date '",
      r'''      "INSERT INTO observation (key) VALUES (?)",''',
    ]) {
      expect(_namesTheTable(line), isTrue, reason: line);
    }
    // …and the shapes that are not.
    for (final line in const [
      '  const Observation(headline, detail),',
      '/// One battery observation from `band_battery`.',
      '  class Observation extends StatelessWidget {',
      // The widget catalogue's map key — a Dart map key, not a table.
      "      'observation': const Observation(",
    ]) {
      expect(
        _pureComment.hasMatch(line) || !_namesTheTable(line),
        isTrue,
        reason: line,
      );
    }
  });

  group('runtime', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      PathProviderPlatform.instance = _FakePathProvider(
        (await Directory.systemTemp.createTemp('openstrap_obs_')).path,
      );
      LocalDb.dbName = 'openstrap_observation_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDownAll(() async {
      await CoachDb.close();
      await LocalDb.close();
    });

    // ── LAYER 2 — differential ───────────────────────────────────────────────
    test('observations move NO derived number, anywhere', () async {
      await _measured('2026-01-01', 50, 4.0);
      await _measured('2026-01-02', 52, 4.2);
      await _measured('2026-01-03', 51, 4.1);
      await LocalDb.putBaseline('rhr', '{"median":51}');

      final before = await _everyDerivedRead();
      expect(before, contains('window(rhr)=[50.0, 52.0, 51.0]'));

      // Poison: OUR key names, THOSE days, values no baseline could survive,
      // one of every source_kind. If any read below admits one of these, the
      // window/median/trend moves and the snapshot stops matching.
      expect(
        await LocalDb.putObservations([
          _obs('2026-01-01T09:00:00Z', 'rhr', 999),
          _obs('2026-01-02T09:00:00Z', 'rhr', -999),
          _obs('2026-01-03T09:00:00Z', 'rhr', 999),
          _obs('2026-01-01T09:00:00Z', 'ln_rmssd', 999),
          _obs(
            '2026-01-02T09:00:00Z',
            'readiness',
            0,
            kind: ObservationSource.imported,
          ),
          _obs(
            '2026-01-03T09:00:00Z',
            'skin_temp_adc',
            999,
            kind: ObservationSource.entered,
          ),
        ]),
        6,
      );
      final db = await LocalDb.instance;
      expect(
        ((await db.rawQuery('SELECT COUNT(*) c FROM observation')).first['c']
                as num)
            .toInt(),
        6,
      );

      expect(
        await _everyDerivedRead(),
        before,
        reason:
            'Something now reads `observation` into a computed number. That is '
            'OBSERVATION_SPEC §3, and the failure it causes in production is '
            'silent — an unexplained step change in a long-horizon metric.',
      );
    });

    // ── LAYER 3 — the coach's read surface ───────────────────────────────────
    test('the coach btree gate cannot reach observations', () async {
      for (final sql in const [
        'SELECT * FROM observation LIMIT 50',
        'SELECT value FROM v_metric UNION ALL SELECT value FROM observation',
        "SELECT * FROM v_daily WHERE date IN (SELECT date FROM observation)",
      ]) {
        await expectLater(
          CoachDb.debugAssertAllowedBtrees(sql),
          throwsA(isA<SqlGuardError>()),
          reason: 'an LLM prompt reached the observation store: $sql',
        );
      }
    });

    // ── the storage layer itself ─────────────────────────────────────────────
    test('identity is COALESCE(vendor_key, key) and REPLACE actually replaces',
        () async {
      final db = await LocalDb.instance;
      await db.delete('observation');
      final at = DateTime.parse('2026-02-01T08:00:00Z');
      Observation biocharge(double v) => Observation(
        vendorKey: 'BioCharge',
        value: v,
        attribution: 'Amazfit',
        at: at,
        sourceKind: ObservationSource.vendor,
      );

      // THE TRAP a plain composite PRIMARY KEY falls into: `key` is NULL on a
      // proprietary composite, SQLite treats NULLs in a UNIQUE index as
      // DISTINCT, so the second write would not collide and a re-import would
      // silently double every composite it carries. The expression index has
      // no NULL to be distinct about.
      await LocalDb.putObservation(biocharge(40));
      await LocalDb.putObservation(biocharge(70));
      final rows = await db.query('observation');
      expect(rows, hasLength(1));
      expect(rows.single['value'], 70.0);
      expect(rows.single['vendor_key'], 'BioCharge');
      expect(rows.single['key'], isNull);
      // The primary band, permanently — same standing rule as decoded_onehz.
      expect(rows.single['device_id'], '');

      // Our-vocabulary rows key off `key` instead, and do not collide with it.
      await LocalDb.putObservation(
        Observation(
          key: 'steps',
          value: 8000,
          attribution: 'Amazfit',
          at: at,
          sourceKind: ObservationSource.vendor,
        ),
      );
      // Nor does the same name under a different source_kind: 'you typed 8000'
      // and 'the band counted 8000' are two facts, not one.
      await LocalDb.putObservation(
        Observation(
          key: 'steps',
          value: 8000,
          attribution: 'you',
          at: at,
          sourceKind: ObservationSource.entered,
        ),
      );
      expect(await db.query('observation'), hasLength(3));
    });

    test('date is the LOCAL day label, including across a DST boundary',
        () async {
      final db = await LocalDb.instance;
      await db.delete('observation');
      // 00:30 local on a spring-forward morning: a UTC-derived label puts this
      // on the wrong day for every user west of Greenwich, which is the exact
      // bug class `day_label.dart` exists to prevent.
      final at = DateTime(2026, 3, 29, 0, 30);
      await LocalDb.putObservation(
        Observation(
          key: 'mood',
          value: 3,
          attribution: 'you',
          at: at,
          sourceKind: ObservationSource.entered,
        ),
      );
      final row = (await db.query('observation')).single;
      expect(row['date'], '2026-03-29');
      expect(row['ts_ms'], at.millisecondsSinceEpoch);
    });

    test('a row with no name at all is refused by the database', () async {
      final db = await LocalDb.instance;
      // Not just the Dart assert — the CHECK is what makes COALESCE non-NULL,
      // and therefore what makes the unique index enforce anything.
      await expectLater(
        db.insert('observation', {
          'ts_ms': 1,
          'date': '2026-01-01',
          'source_kind': 'vendor',
          'value': 1.0,
          'attribution': 'Amazfit',
        }),
        throwsA(anything),
      );
    });

    test('the table survives a backup/restore round trip', () async {
      final db = await LocalDb.instance;
      await db.delete('observation');
      await LocalDb.putObservation(
        _obs('2026-04-01T10:00:00Z', 'sleep_score', 82),
      );
      final snapshot = await LocalDb.exportCopy();
      await db.delete('observation');
      await LocalDb.importFromDbFile(snapshot);
      final rows = await db.query('observation');
      expect(
        rows,
        hasLength(1),
        reason: 'a table absent from the merge manifest silently vanishes on '
            'restore — nothing regenerates a vendor scalar or a typed-in one',
      );
      expect(rows.single['value'], 82.0);
      await File(snapshot).delete();
    });

    test('schemaHealth requires it', () async {
      final health = await LocalDb.schemaHealth();
      expect(health['ok'], isTrue, reason: '$health');
      final db = await LocalDb.instance;
      await db.execute('DROP TABLE observation');
      final broken = await LocalDb.schemaHealth();
      expect(broken['missing_tables'], contains('observation'));
      // …and the every-open repair puts it back.
      await LocalDb.close();
      await LocalDb.instance;
      expect((await LocalDb.schemaHealth())['ok'], isTrue);
    });
    // ── the v48 rung, against a REAL export ──────────────────────────────────
    // `OPENSTRAP_TEST_DBS=/path/one.db,/path/two.db`. `onUpgrade` runs inside
    // openDatabase on iOS's launch-path CPU watchdog, so a rung's cost is a
    // number, not an assurance — and phase 3 must move no computed value, which
    // means every `day_result` payload has to come back byte-identical.
    for (final src in (Platform.environment['OPENSTRAP_TEST_DBS'] ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)) {
      test(
        'v48 on ${p.basename(src)}: creates the table, moves no number',
        () async {
          final name = 'v48_${p.basenameWithoutExtension(src)}.db';
          await LocalDb.close();
          LocalDb.dbName = name;
          final dir = await databaseFactory.getDatabasesPath();
          await databaseFactory.deleteDatabase(p.join(dir, name));
          final path = p.join(dir, name);
          await File(src).copy(path);

          Future<Map<String, Object?>> bundlesOf(DatabaseExecutor d) async => {
            for (final r in await d.query('day_result'))
              '${r['day_id']}|${r['algo_version']}': r['payload_json'],
          };

          // The BEFORE snapshot is read with NO version, so sqflite does not
          // migrate the file out from under it. Every later read goes through
          // the LocalDb handle: sqflite keeps ONE instance per path, so closing
          // a second "read-only" handle closes the live one too.
          final plain = await databaseFactory.openDatabase(
            path,
            options: OpenDatabaseOptions(readOnly: true),
          );
          final before = await bundlesOf(plain);
          await plain.close();
          expect(before, isNotEmpty);

          final whole = Stopwatch()..start();
          var db = await LocalDb.instance;
          whole.stop();
          expect(
            await bundlesOf(db),
            before,
            reason: 'the ladder moved a number',
          );

          // THE v48 RUNG ON ITS OWN. The export is at user_version 27, so the
          // open above pays for twenty-one rungs (the v47 re-key dominates).
          // Rewinding the stamp on the now-migrated file and re-opening runs
          // this rung and nothing else, which is the share it actually costs a
          // user upgrading from the shipped build.
          await db.execute('DROP TABLE observation');
          await db.execute('PRAGMA user_version = 47');
          await LocalDb.close();
          final rung = Stopwatch()..start();
          db = await LocalDb.instance;
          rung.stop();
          // ignore: avoid_print
          print(
            '[v48] ${p.basename(src)} whole ladder ${whole.elapsedMilliseconds}'
            ' ms; v48 rung alone ${rung.elapsedMilliseconds} ms',
          );
          expect(await bundlesOf(db), before);

          final info = await db.rawQuery('PRAGMA table_info(observation)');
          expect(info, isNotEmpty);
          expect(
            (await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type='index' "
              "AND tbl_name='observation'",
            )).map((r) => r['name']).toSet(),
            containsAll(['idx_observation_identity', 'idx_observation_date']),
          );
          // The new table starts empty and stays empty: nothing writes it yet.
          expect(
            ((await db.rawQuery(
              'SELECT COUNT(*) c FROM observation',
            )).first['c'] as num).toInt(),
            0,
          );
          expect((await LocalDb.schemaHealth())['ok'], isTrue);
          await LocalDb.close();
          await File(path).delete();
        },
        timeout: const Timeout(Duration(minutes: 15)),
      );
    }

  });
}
