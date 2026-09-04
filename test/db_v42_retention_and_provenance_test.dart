// Schema v42, over the REAL LocalDb on sqflite_ffi.
//
// Four separate things land in this version and every one of them is about a
// value being kept, dropped or attributed HONESTLY:
//
//   • decoded_onehz.ambient_raw — the gen4 ambient-light channel, with 0 (the
//     decoder's absent sentinel) mapped to NULL so an unconfirmed record never
//     reads as a real measurement of total darkness.
//   • metric_series_version — which build's maths wrote a day's scalars.
//   • band_events keeps its wear/charge transitions past the 3-day prune, so a
//     re-derive of an old day stops running the nap detector with both
//     rejection lists empty.
//   • raw_archive is thinned to a stated 1-in-60 sample behind the retention
//     edge instead of growing ~45 MB/day forever.
//
// The REAL-DB half (`OPENSTRAP_TEST_DBS=/path/one.db,/path/two.db`) runs the
// whole ladder over old-schema exports. Skipped when the env var is unset —
// those files are not in the repo.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/import/whoop_import.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

Sample _sample(int ts, int counter, {int? ambient}) => Sample(
  tsEpoch: ts,
  counter: counter,
  hr: 70,
  rrIntervalsMs: const [800],
  ax: 0.1,
  ay: 0.2,
  az: 0.9,
  spo2RedRaw: 1,
  spo2IrRaw: 2,
  skinTempRaw: 3,
  ambientRaw: ambient,
);

RawRecord _raw(int ts, int counter) => RawRecord(
  counter: counter,
  packetType: 47,
  hex: 'feed$counter',
  capturedAt: ts * 1000,
  recTs: ts,
);

Future<List<String>> _columns(String table) async {
  final db = await LocalDb.instance;
  return [
    for (final c in await db.rawQuery('PRAGMA table_info($table)'))
      c['name'] as String,
  ];
}

Future<int> _count(String sql, [List<Object?> args = const []]) async {
  final db = await LocalDb.instance;
  return (await db.rawQuery(sql, args)).first.values.first as int;
}

Future<void> _useFreshDb(String name) async {
  await LocalDb.close();
  LocalDb.dbName = name;
  final dir = await databaseFactory.getDatabasesPath();
  await databaseFactory.deleteDatabase(p.join(dir, name));
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    await LocalDb.close();
  });

  test('ambient_raw: 0 is absence, not a reading', () async {
    await _useFreshDb('v42_ambient_test.db');
    expect(await _columns('decoded_onehz'), contains('ambient_raw'));

    await LocalDb.commitSyncBatch(
      [_raw(1000, 1), _raw(1001, 2), _raw(1002, 3)],
      [
        _sample(1000, 1, ambient: 412), // a real reading
        _sample(1001, 2, ambient: 0), // unconfirmed optical block
        _sample(1002, 3), // decoder never produced one
      ],
    );

    final db = await LocalDb.instance;
    Future<Object?> ambientAt(int recTs) async => (await db.rawQuery(
      'SELECT ambient_raw AS a FROM decoded_onehz WHERE rec_ts = ?',
      [recTs],
    )).first['a'];

    expect(await ambientAt(1000), 412);
    // NOT 0 — writing the sentinel through turns "we did not read the channel"
    // into a measurement of total darkness.
    expect(await ambientAt(1001), isNull);
    expect(await ambientAt(1002), isNull);
    // And it round-trips back out as absent, not zero.
    final row = (await db.query(
      'decoded_onehz',
      where: 'rec_ts = ?',
      whereArgs: [1001],
    )).first;
    expect(Sample.fromDecodedRow(row).ambientRaw, isNull);
  });

  test('metric_series_version stamps the build that wrote the scalars',
      () async {
    await _useFreshDb('v42_series_version_test.db');
    Future<void> put(String day, int v, double value) => LocalDb.putDayResult(
      dayId: day,
      algoVersion: v,
      payloadJson: '{}',
      windowJson: '{}',
      series: {'rhr': value},
    );

    await put('2026-01-01', 68, 51);
    await put('2026-01-02', 70, 52);
    // A ROLLED-BACK build rewrites the same day at a LOWER version. This is the
    // case a MAX() over day_result gets wrong, and the reason the stamp is
    // written rather than queried.
    await put('2026-01-02', 69, 53);

    final rows = await LocalDb.metricSeriesVersions();
    expect(rows.map((r) => r['date']).toList(), [
      '2026-01-01',
      '2026-01-02',
    ]);
    expect(rows.last['algo_version'], 69);

    // A partial pass writes no scalars, so it must not claim the stamp either.
    await LocalDb.putDayResult(
      dayId: '2026-01-02',
      algoVersion: 99,
      payloadJson: '{}',
      windowJson: '{}',
      partial: true,
      series: {'rhr': 99},
    );
    expect((await LocalDb.metricSeriesVersions()).last['algo_version'], 69);
  });

  // export-provenance — the other half of the same side table.
  test('an imported day carries its vendor tag; an unattributed day stays NULL',
      () async {
    await _useFreshDb('provenance_source_test.db');
    // A WHOOP export CSV, through the real importer. Every number in it is
    // WHOOP's own derived score, and unlabelled it is byte-identical in our
    // export to a day this app derived from 1 Hz records.
    final dir = Directory.systemTemp.createTempSync('whoop_csv');
    final csv = File(p.join(dir.path, 'physiological_cycles.csv'))
      ..writeAsStringSync(
        'Cycle start time,Wake onset,Recovery score %,'
        'Resting heart rate (bpm),Day Strain\n'
        '2026-03-01 07:00:00,2026-03-01 07:00:00,61,54,11.2\n',
      );
    try {
      final r = await WhoopImporter.importFiles([csv.path]);
      expect(r.days, 1);
    } finally {
      dir.deleteSync(recursive: true);
    }
    final imported = (await LocalDb.metricSeriesVersions()).single;
    expect(imported['source'], 'whoop_export');

    // And the law that outranks it: a writer that does not know its own
    // provenance writes NULL. Never retro-filled to 'band' — `csvField`
    // already renders NULL as empty, which is the honest cell.
    await LocalDb.putDayResult(
      dayId: '2026-03-02',
      algoVersion: 41,
      payloadJson: '{}',
      windowJson: '{}',
      series: {'rhr': 50},
    );
    final rows = await LocalDb.metricSeriesVersions();
    expect(rows.last['date'], '2026-03-02');
    expect(rows.last['source'], isNull);
  });

  test('a strap swap is masked PER-METRIC, and only where the units differ',
      () async {
    await _useFreshDb('family_seam_test.db');
    // Three gen4 nights, then the athlete swaps to a gen5. `skin_temp_adc` is
    // ADC COUNTS on one side of that seam and CENTI-DEGREES on the other,
    // under one key, feeding one baseline — this is live today with no second
    // device involved.
    for (final d in const [
      ('2026-03-01', 'gen4'),
      ('2026-03-02', 'gen4'),
      ('2026-03-03', 'gen5'),
    ]) {
      await LocalDb.putDayResult(
        dayId: d.$1,
        algoVersion: 76,
        payloadJson: '{}',
        windowJson: '{}',
        source: 'band',
        deviceFamily: d.$2,
        series: {'rhr': 55, 'skin_temp_adc': 30000},
      );
    }
    // Foreign = not the newest stamped family. The gen5 night is the CURRENT
    // one, so the two gen4 nights are what a skin-temp baseline must drop.
    expect(await LocalDb.foreignFamilyDates(), {'2026-03-01', '2026-03-02'});
    // ...and only skin temp. RHR off a different WHOOP is the same quantity
    // measured slightly differently — masking it would delete real history to
    // fix a bias smaller than the window it is measured over.
    expect(LocalDb.familySeamKeys, {'skin_temp_adc'});

    // A day with NO stamp is UNKNOWN, never foreign — every day written before
    // the column existed reads NULL, and dropping those would empty a real
    // user's baseline.
    await LocalDb.putDayResult(
      dayId: '2026-03-04',
      algoVersion: 76,
      payloadJson: '{}',
      windowJson: '{}',
      series: {'rhr': 56},
    );
    expect(await LocalDb.foreignFamilyDates(), isNot(contains('2026-03-04')));
  });

  test('one family is never foreign to itself — the mask moves no number today',
      () async {
    await _useFreshDb('family_seam_single_test.db');
    for (final d in const ['2026-04-01', '2026-04-02']) {
      await LocalDb.putDayResult(
        dayId: d,
        algoVersion: 76,
        payloadJson: '{}',
        windowJson: '{}',
        source: 'band',
        deviceFamily: 'gen4',
        series: {'skin_temp_adc': 30000},
      );
    }
    expect(await LocalDb.foreignFamilyDates(), isEmpty);
  });

  test('the 3-day prune keeps wear/charge transitions and drops the rest',
      () async {
    await _useFreshDb('v42_band_events_test.db');
    const old = 1000;
    // Two transitions and one chatty event, all well behind the cutoff.
    await LocalDb.insertEvent(proto.EventId.wristOff, old, 'aa01',
        deviceId: LocalDb.kPrimaryDeviceId);
    await LocalDb.insertEvent(proto.EventId.wristOn, old + 100, 'aa02',
        deviceId: LocalDb.kPrimaryDeviceId);
    await LocalDb.insertEvent(33, old + 50, 'aa03',
        deviceId: LocalDb.kPrimaryDeviceId);

    await LocalDb.pruneDecodedBeforeRecTs(old + 10000);

    expect(
      await _count('SELECT COUNT(*) FROM band_events WHERE event_id = 33'),
      0,
    );
    expect(
      await _count(
        'SELECT COUNT(*) FROM band_events WHERE event_id IN (9, 10)',
      ),
      2,
    );
    // The point of keeping them: the off-wrist span detectNaps rejects against
    // is still reconstructable long after the substrate is gone.
    expect(
      await LocalDb.wristOffSpans(old - 10, old + 200,
          deviceId: LocalDb.kPrimaryDeviceId),
      [
        [old, old + 100],
      ],
    );
  });

  test(
    'wristOffSpans/chargingSpans are scoped per device: band B charging '
    'does not mask band A\'s worn night',
    () async {
      await _useFreshDb('v42_span_scoping_test.db');
      const t = 5000;
      final db = await LocalDb.instance;
      Future<void> bandEvent(String deviceId, int eventId, int ts) =>
          db.insert('band_events', {
            'device_id': deviceId,
            'hex': '$deviceId-$eventId-$ts',
            'event_id': eventId,
            'name': proto.EventId.name(eventId),
            'ts': ts,
            'captured_at': ts * 1000,
          });

      // Device A: wrist off [t, t+50). Device B: charging on [t, t+50).
      await bandEvent('device-a', proto.EventId.wristOff, t);
      await bandEvent('device-a', proto.EventId.wristOn, t + 50);
      await bandEvent('device-b', proto.EventId.chargingOn, t);
      await bandEvent('device-b', proto.EventId.chargingOff, t + 50);

      expect(
        await LocalDb.wristOffSpans(t - 10, t + 100, deviceId: 'device-a'),
        [
          [t, t + 50],
        ],
      );
      expect(
        await LocalDb.wristOffSpans(t - 10, t + 100, deviceId: 'device-b'),
        isEmpty,
        reason: 'device B never went off-wrist',
      );
      expect(
        await LocalDb.chargingSpans(t - 10, t + 100, deviceId: 'device-b'),
        [
          [t, t + 50],
        ],
      );
      expect(
        await LocalDb.chargingSpans(t - 10, t + 100, deviceId: 'device-a'),
        isEmpty,
        reason: 'device A was never on the charger — the bug this fixes '
            'is device B\'s charging spans suppressing device A\'s real '
            'worn night',
      );
    },
  );

  test('raw_archive thins to a 1-in-60 sample behind the retention edge',
      () async {
    await _useFreshDb('v42_archive_thin_test.db');
    const cutoffSec = 2000000;
    for (var i = 0; i < 600; i++) {
      await LocalDb.archiveRawRecord(
        ArchiveRecord(
          counter: i,
          hex: 'ab${i.toString().padLeft(6, '0')}',
          packetType: 47,
          recTs: null, // undecodable ⇒ we never learned its record time
          capturedAt: (cutoffSec - 86400) * 1000,
          reason: 'undecodable_rec_v20',
        ),
      );
    }
    // A different reason, same age — not this rule's business.
    await LocalDb.archiveRawRecord(
      ArchiveRecord(
        counter: 7,
        hex: 'cc0007',
        packetType: 47,
        recTs: null,
        capturedAt: (cutoffSec - 86400) * 1000,
        reason: 'undecodable_rec_v25',
      ),
    );
    // v20, but INSIDE the retention window — kept at full rate.
    await LocalDb.archiveRawRecord(
      ArchiveRecord(
        counter: 1,
        hex: 'dd0001',
        packetType: 47,
        recTs: null,
        capturedAt: (cutoffSec + 86400) * 1000,
        reason: 'undecodable_rec_v20',
      ),
    );

    await LocalDb.pruneDecodedBeforeRecTs(cutoffSec);

    // 600 rows at 1-in-60 ⇒ counters 0, 60, … 540.
    expect(
      await _count(
        "SELECT COUNT(*) FROM raw_archive WHERE reason = 'undecodable_rec_v20' "
        'AND captured_at < ?',
        [cutoffSec * 1000],
      ),
      10,
    );
    expect(
      await _count(
        "SELECT COUNT(*) FROM raw_archive WHERE reason = 'undecodable_rec_v25'",
      ),
      1,
    );
    expect(
      await _count(
        "SELECT COUNT(*) FROM raw_archive WHERE reason = 'undecodable_rec_v20' "
        'AND captured_at >= ?',
        [cutoffSec * 1000],
      ),
      1,
    );
    // Idempotent: running it again takes nothing more.
    await LocalDb.pruneDecodedBeforeRecTs(cutoffSec);
    expect(await _count('SELECT COUNT(*) FROM raw_archive'), 12);
  });

  test('band_backlog records a connect and never guesses a device', () async {
    await _useFreshDb('v42_backlog_test.db');
    await LocalDb.putBandBacklog(
      ts: 1700,
      written: 10,
      used: 4,
      capacity: 64,
      trimPage: 3,
      wrapCount: 2,
      freeRecords: 90000,
      deviceFamily: 'gen5',
    );
    await LocalDb.putBandBacklog(ts: 1800, wrapCount: 3, freeRecords: 80000);

    final rows = await LocalDb.bandBacklog();
    expect(rows.length, 2);
    expect(rows.first['ts'], 1800);
    // wrap_count moved between connects ⇒ the ring overwrote data we never saw.
    expect(rows.first['wrap_count'], 3);
    expect(rows.last['wrap_count'], 2);
    // Unknown provenance is NULL, never 'gen4'.
    expect(rows.first['device_family'], isNull);
    expect(rows.last['device_family'], 'gen5');
  });

  // Old-schema exports: the whole ladder, end to end.
  final real = (Platform.environment['OPENSTRAP_TEST_DBS'] ?? '')
      .split(',')
      .where((s) => s.trim().isNotEmpty)
      .toList();
  for (final src in real) {
    test(
      're-keys ${p.basename(src)} onto (device_id, ts_ms) — and how long the '
      'launch-path ladder takes to do it',
      () async {
        // `onUpgrade` runs inside openDatabase, on iOS's launch-path CPU
        // watchdog. The v47 rebuild is bounded by `rawRetentionDays` (~3 days
        // of 1 Hz), which is what makes it safe to run there — this test is
        // where that claim gets a number instead of an assurance.
        final name = 'v47_${p.basenameWithoutExtension(src)}.db';
        await _useFreshDb(name);
        final dir = await databaseFactory.getDatabasesPath();
        await File(src).copy(p.join(dir, name));

        // EVERY day_result BEFORE the ladder runs. Phase 2 must not move a
        // single computed number — no kAlgoVersion bump ships with it — so the
        // payloads have to come back byte-identical. Opened with NO version so
        // sqflite does not migrate it out from under the snapshot.
        final plain = await databaseFactory.openDatabase(
          p.join(dir, name),
          options: OpenDatabaseOptions(readOnly: true),
        );
        final beforeDays = {
          for (final r in await plain.query('day_result'))
            '${r['day_id']}|${r['algo_version']}': r['payload_json'],
        };
        await plain.close();
        expect(beforeDays, isNotEmpty);

        final sw = Stopwatch()..start();
        final db = await LocalDb.instance;
        sw.stop();
        final afterDays = {
          for (final r in await db.query('day_result'))
            '${r['day_id']}|${r['algo_version']}': r['payload_json'],
        };
        expect(afterDays, beforeDays,
            reason: 'the re-key must not touch a derived number');
        final before = <String, int>{};
        for (final t in const ['decoded_onehz', 'decoded_rr', 'samples']) {
          before[t] = await _count('SELECT COUNT(*) FROM $t');
        }
        // ignore: avoid_print
        print('[v47] ${p.basename(src)} whole ladder open: '
            '${sw.elapsedMilliseconds} ms  rows=$before');

        for (final t in const ['decoded_onehz', 'decoded_rr', 'samples']) {
          final info = await db.rawQuery('PRAGMA table_info($t)');
          expect(info.firstWhere((c) => c['name'] == 'device_id')['pk'], 1,
              reason: t);
          expect(info.firstWhere((c) => c['name'] == 'ts_ms')['pk'], 2,
              reason: t);
          // Every migrated row belongs to the primary band and carries the
          // time it always had. Nothing is rewritten, nothing is dropped.
          expect(
            await _count("SELECT COUNT(*) FROM $t WHERE device_id <> ''"),
            0,
            reason: t,
          );
        }
        expect(
          await _count(
            'SELECT COUNT(*) FROM decoded_onehz WHERE ts_ms <> rec_ts * 1000',
          ),
          0,
        );
        expect(
          await _count(
            'SELECT COUNT(*) FROM decoded_rr WHERE ts_ms <> rec_ts * 1000',
          ),
          0,
        );
        expect(await _count('SELECT COUNT(*) FROM samples WHERE ts_ms <> ts * 1000'), 0);

        // Re-opening is a no-op: the rung self-skips on a table that already
        // carries device_id, so a second launch pays nothing.
        await LocalDb.close();
        final sw2 = Stopwatch()..start();
        await LocalDb.instance;
        sw2.stop();
        // ignore: avoid_print
        print('[v47] ${p.basename(src)} second open (no ladder): '
            '${sw2.elapsedMilliseconds} ms');

        final health = await LocalDb.schemaHealth();
        expect(health['ok'], isTrue, reason: '$src $health');
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );
    test(
      'migrates ${p.basename(src)} to v42',
      () async {
        final name = 'v42_${p.basenameWithoutExtension(src)}.db';
        await _useFreshDb(name);
        final dir = await databaseFactory.getDatabasesPath();
        await File(src).copy(p.join(dir, name));

        final db = await LocalDb.instance;
        expect(await _columns('decoded_onehz'), contains('ambient_raw'));
        expect(await _columns('sessions'), contains('trace_json'));
        expect(await _columns('sessions'), contains('trace_samples'));
        // Never backfilled: no record before this version carried the channel,
        // and no session before it carried a trace.
        expect(
          await _count(
            'SELECT COUNT(*) FROM decoded_onehz WHERE ambient_raw IS NOT NULL',
          ),
          0,
        );

        // Every non-skipped, non-partial derived day gets its version stamped.
        final derived = await _count(
          'SELECT COUNT(DISTINCT day_id) FROM day_result '
          'WHERE skipped = 0 AND partial = 0',
        );
        expect(await _count('SELECT COUNT(*) FROM metric_series_version'),
            derived);

        final before = await _count('SELECT COUNT(*) FROM raw_archive');
        final byReason = await db.rawQuery(
          'SELECT reason, COUNT(*) AS n FROM raw_archive GROUP BY reason',
        );
        // Thin at "now", so the whole export is behind the retention edge.
        final thinned = await LocalDb.thinRawArchiveBefore(
          DateTime.now().millisecondsSinceEpoch,
        );
        final after = await _count('SELECT COUNT(*) FROM raw_archive');
        // ignore: avoid_print
        print('[v42] ${p.basename(src)} archive $before → $after '
            '(-$thinned) by_reason=$byReason');
        expect(after, before - thinned);
        // Nothing but the one thinned reason is touched.
        for (final r in byReason) {
          if (r['reason'] == 'undecodable_rec_v20') continue;
          expect(
            await _count(
              'SELECT COUNT(*) FROM raw_archive WHERE reason = ?',
              [r['reason']],
            ),
            r['n'],
            reason: '${r['reason']} must not be thinned',
          );
        }

        final health = await LocalDb.schemaHealth();
        expect(health['ok'], isTrue, reason: '$src $health');
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );
  }
}
