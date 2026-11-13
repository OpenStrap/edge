// A re-derive carries the stored night's clock forward. It reads two numbers
// off the stored row with json_extract instead of decoding the bundle; these
// tests hold that read to what decoding the bundle answered.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/crossday_pipeline.dart'
    show recordedClockShiftSec, storedNightClockShiftSec;
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/data/db.dart';

Map<String, dynamic> _bundle({int? onsetMs, double? clock}) => {
      'sleep': {
        'window': {
          'value': {'onset_ms': ?onsetMs, 'offset_ms': ?onsetMs},
        },
      },
      'scalars': {'rhr': 52, 'sleep_onset_sec': ?clock},
      'series': {
        'hr_curve': [
          for (var i = 0; i < 50; i++) {'t': 1767225600 + i * 60, 'v': 60},
        ],
      },
    };

Future<void> _put(String day, Object payload,
        {int? version, bool skipped = false}) =>
    LocalDb.putDayResult(
      dayId: day,
      algoVersion: version ?? kAlgoVersion,
      payloadJson: payload is String ? payload : jsonEncode(payload),
      windowJson: '{}',
      skipped: skipped,
    );

int _shift(({num? onsetMs, num? onsetClockSec})? c) => c == null
    ? 0
    : recordedClockShiftSec(
        onsetSec: c.onsetMs == null ? null : (c.onsetMs! / 1000).round(),
        onsetClockSec: c.onsetClockSec,
      );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const name = 'stored_night_clock_test.db';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = name;
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });

  tearDownAll(LocalDb.close);

  test('matches the decoded bundle for a night lived in another zone', () async {
    // 23:10 local onset, frozen two hours east of wherever the runner is.
    final onset = DateTime(2026, 9, 1, 23, 10);
    final onsetMs = onset.millisecondsSinceEpoch;
    final local = onset.hour * 3600 + onset.minute * 60;
    var clock = (local + 7200 - 4 * 3600) % 86400;
    if (clock > 43200) clock -= 86400;
    final b = _bundle(onsetMs: onsetMs, clock: clock.toDouble());
    await _put('2026-09-02', b);

    final got = await LocalDb.storedNightClock('2026-09-02');
    expect(got, isNotNull);
    expect(_shift(got), storedNightClockShiftSec(b));
    expect(_shift(got), isNot(0));
  });

  test('null for no row, a skip marker, or a malformed payload', () async {
    expect(await LocalDb.storedNightClock('2026-01-01'), isNull);

    await _put('2026-09-03', _bundle(onsetMs: 1, clock: 1), skipped: true);
    expect(await LocalDb.storedNightClock('2026-09-03'), isNull);

    await _put('2026-09-04', {'skipped': true});
    expect(await LocalDb.storedNightClock('2026-09-04'), isNull);

    await _put('2026-09-05', '{not json');
    expect(await LocalDb.storedNightClock('2026-09-05'), isNull);
  });

  test('reads the served version, not an older one under it', () async {
    await _put('2026-09-06', _bundle(onsetMs: 1000, clock: 60),
        version: kAlgoVersion - 1);
    await _put('2026-09-06', _bundle(), version: kAlgoVersion);
    final got = await LocalDb.storedNightClock('2026-09-06');
    expect(got, isNotNull);
    expect(got!.onsetMs, isNull);
    expect(got.onsetClockSec, isNull);

    // A newer skip marker hides the older real row, as dayResult does.
    await _put('2026-09-07', _bundle(onsetMs: 1000, clock: 60),
        version: kAlgoVersion - 1);
    await _put('2026-09-07', {'skipped': true},
        version: kAlgoVersion, skipped: true);
    expect(await LocalDb.storedNightClock('2026-09-07'), isNull);
  });
}
