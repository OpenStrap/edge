// The thermometer and the Mi scales: scripted devices in, observation rows
// out, through the REAL adapters, the shared [SessionLink] host and sqlite.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/session_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final DateTime _now = DateTime(2026, 10, 4, 7, 30);
int _nowSec() => _now.millisecondsSinceEpoch ~/ 1000;

List<int> _f32(int mantissa, int exp) {
  final m = mantissa & 0xffffff;
  return [m & 0xff, (m >> 8) & 0xff, (m >> 16) & 0xff, exp & 0xff];
}

List<int> _dt(DateTime t) => [
      t.year & 0xff, t.year >> 8, t.month, t.day, t.hour, t.minute, t.second,
    ];

Future<List<Map<String, Object?>>> _obs() async =>
    (await LocalDb.instance).query('observation', orderBy: 'ts_ms');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'session_devices_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('thermometer: sets the clock, saves plausible readings as body_temp',
      () async {
    final morning = DateTime(2026, 10, 4, 6, 41, 3);
    final link = await SessionLink.thermometer.ingestForTest(
      'thermo-1',
      nowSeconds: _nowSec,
      pushes: [
        // 36.52 C stamped at 06:41:03 (flags: timestamp present).
        (kHtpTemperatureMeasurement, [0x02, ..._f32(3652, -2), ..._dt(morning)]),
        // 97.7 F with no stamp -> 36.5 C at arrival.
        (kHtpTemperatureMeasurement, [0x01, ..._f32(977, -1)]),
        // 22.0 C: taken off the body, dropped.
        (kHtpTemperatureMeasurement, [0x00, ..._f32(220, -1)]),
      ],
    );
    expect(link.writes.first.$1, kCurrentTimeChar);
    expect(link.writes.first.$2, currentTimeValue(_now));
    final rows = await _obs();
    expect(rows.map((r) => (r['key'], r['value'])),
        [('body_temp', 36.5), ('body_temp', 36.52)].reversed.toList());
    expect(rows.first['ts_ms'], morning.millisecondsSinceEpoch);
    expect(rows.every((r) => r['attribution'] == kThermometer.label), isTrue);
    final archive = await (await LocalDb.instance).query('raw_archive');
    expect(archive.length, 3, reason: 'every indication is banked');
  });

  test('composition scale: settled weight + impedance; settling ignored',
      () async {
    // The scale's clock runs in UTC.
    final at = DateTime.utc(2026, 10, 4, 7, 29, 10);
    List<int> frame(int flags, int ohm, int raw) =>
        [0x02, flags, ..._dt(at), ohm & 0xff, ohm >> 8, raw & 0xff, raw >> 8];
    await SessionLink.miScaleComposition.ingestForTest(
      'scale-bc-1',
      nowSeconds: _nowSec,
      pushes: [
        (kMiScaleBodyCompositionChar, frame(0x02, 0, 14000)), // settling
        (kMiScaleBodyCompositionChar, frame(0x22, 512, 14368)), // 71.84 kg
      ],
    );
    final rows = await _obs();
    expect({for (final r in rows) (r['key'] ?? r['vendor_key']): r['value']},
        {'weight': 71.84, 'impedance': 512.0});
    expect(rows.first['ts_ms'], at.millisecondsSinceEpoch);
  });

  test('scale 2: reads back stored history, never acknowledges it', () async {
    List<int> rec(DateTime t, int raw) => [0x20, raw & 0xff, raw >> 8, ..._dt(t)];
    final link = await SessionLink.miScale2.ingestForTest(
      'scale2-1',
      nowSeconds: _nowSec,
      reply: (uuid, value) => switch ((uuid == kMiScaleHistoryChar, value.first)) {
        (true, 0x01) => [(kMiScaleHistoryChar, [0x01, 2, 0])],
        (true, 0x02) => [
            (kMiScaleHistoryChar, [
              ...rec(DateTime(2026, 10, 2, 7, 0), 14400),
              ...rec(DateTime(2026, 10, 3, 7, 0), 14380),
            ]),
            (kMiScaleHistoryChar, [0x03]),
          ],
        _ => const [],
      },
    );
    final history = [
      for (final (u, v) in link.writes)
        if (u == kMiScaleHistoryChar) v,
    ];
    expect(history, [
      [0x01, 1, 0, 0, 0],
      [0x02],
      [0x03],
    ], reason: 'request, send, stop; never the deleting 04 acknowledgement');
    final rows = await _obs();
    expect(rows.map((r) => r['value']), [72.0, 71.9]);
  });

  test('none of these devices is admitted to derivation', () {
    for (final e in [kThermometer, kMiScaleComposition, kMiScale2]) {
      expect(kDerivableSources, isNot(contains(e.id)));
      expect(kAdapterSignals[e.id], isEmpty);
    }
  });
}
