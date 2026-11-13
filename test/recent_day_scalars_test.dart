// The Cycle tab's biometric overlay reads three scalars across 120 days. It
// used to pull every full bundle (`SELECT r.*`) and decode it on the UI isolate
// to get them; `recentDayScalars` extracts them in SQLite instead. These tests
// hold the SQL read to exactly what the bundle decode answered, including the
// malformed and non-numeric cases where the answer is null.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/series_codec.dart';

Future<void> _put(String dayId, String payload, {int? version}) =>
    LocalDb.putDayResult(
      dayId: dayId,
      algoVersion: version ?? kAlgoVersion,
      payloadJson: payload,
      windowJson: '{}',
    );

const _keys = ['rhr', 'rmssd', 'skin_temp_z'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const name = 'recent_day_scalars_test.db';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = name;
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );

    final curve = [
      for (var i = 0; i < 50; i++) {'t': 1767225600 + i * 60, 'v': 60 + i % 5},
    ];
    await _put(
      '2026-03-01',
      jsonEncode({
        'scalars': {'rhr': 52, 'rmssd': 61.5, 'skin_temp_z': -0.4},
        'series': {'hr_curve': curve},
      }),
    );
    // Missing key, a string where a number belongs, and a JSON null.
    await _put(
      '2026-03-02',
      jsonEncode({
        'scalars': {'rhr': 'n/a', 'skin_temp_z': null},
      }),
    );
    // No scalars object at all, and scalars that is not an object.
    await _put('2026-03-03', jsonEncode({'skipped': true}));
    await _put('2026-03-04', jsonEncode({'scalars': [1, 2, 3]}));
    // A corrupt payload must null its own day, not fail the read.
    await _put('2026-03-05', '{"scalars": {"rhr": 50');
    // A newer build's row is never served.
    await _put('2026-03-06', jsonEncode({'scalars': {'rhr': 49}}));
    await _put(
      '2026-03-06',
      jsonEncode({'scalars': {'rhr': 99}}),
      version: kAlgoVersion + 1,
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });

  test('matches decoding each bundle and reading scalars[key] is num',
      () async {
    final got = await LocalDb.recentDayScalars(120, _keys);

    // The read it replaces, as the oracle.
    final oracle = [
      for (final r in await LocalDb.recentDayResults(120))
        {
          'date': r['date'],
          for (final k in _keys)
            k: switch ((SeriesCodec.decodePayloadJson(r['payload_json'])?['scalars'])) {
              final Map s when s[k] is num => s[k],
              _ => null,
            },
        },
    ];

    expect(
      [
        for (final r in got) {'date': r['date'], for (final k in _keys) k: r[k]},
      ],
      oracle,
    );
    expect([for (final r in got) r['date']], [
      '2026-03-06',
      '2026-03-05',
      '2026-03-04',
      '2026-03-03',
      '2026-03-02',
      '2026-03-01',
    ]);

    final byDay = {for (final r in got) r['date']: r};
    expect(byDay['2026-03-01']!['rhr'], 52);
    expect(byDay['2026-03-01']!['rmssd'], 61.5);
    expect(byDay['2026-03-01']!['skin_temp_z'], -0.4);
    expect(byDay['2026-03-02']!['rhr'], isNull);
    expect(byDay['2026-03-05']!['rhr'], isNull);
    expect(byDay['2026-03-06']!['rhr'], 49);
  });

  test('never returns the payload', () async {
    final got = await LocalDb.recentDayScalars(120, _keys);
    expect(got, isNotEmpty);
    for (final r in got) {
      expect(r.containsKey('payload_json'), isFalse);
    }
  });

  test('honours the limit, newest first', () async {
    final got = await LocalDb.recentDayScalars(2, _keys);
    expect([for (final r in got) r['date']], ['2026-03-06', '2026-03-05']);
  });

  test('refuses a key that is not a plain scalar name', () async {
    expect(
      () => LocalDb.recentDayScalars(10, ["rhr') --"]),
      throwsArgumentError,
    );
  });
}
