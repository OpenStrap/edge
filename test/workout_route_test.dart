// workout_route persistence, run against the REAL LocalDb over sqflite_ffi:
//   • fresh schema (v22) passes schemaHealth() — workout_route present.
//   • appendRoutePoints → routePoints round-trip, ordered by seq.
//   • hrSamplesInRange returns only worn (hr > 0) seconds in the window.
//   • deleteSession cascades to the route rows.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/gps/route_models.dart';

RawRecord _raw(int ts, int counter) => RawRecord(
      counter: counter,
      packetType: 47,
      hex: 'feed$counter',
      capturedAt: ts * 1000,
      recTs: ts,
    );

Sample _sample(int ts, int counter, int hr) => Sample(
      tsEpoch: ts,
      counter: counter,
      hr: hr,
      rrIntervalsMs: const [],
      ax: 0,
      ay: 0,
      az: 0,
      spo2RedRaw: 0,
      spo2IrRaw: 0,
      skinTempRaw: 0,
    );

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_route_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('fresh v22 schema passes schemaHealth (workout_route present)',
      () async {
    final health = await LocalDb.schemaHealth();
    expect(health['ok'], true, reason: '$health');
    expect(health['missing_tables'], isEmpty);
  });

  test('append + read route points round-trips in seq order', () async {
    const id = 'w-route-1';
    await LocalDb.putSession({
      'id': id,
      'start_ts': 1000,
      'end_ts': 1100,
      'type': 'run',
      'status': 'done',
      'source': 'manual',
      'created_at': 1000000,
    });

    expect(await LocalDb.sessionHasRoute(id), false);

    final b1 = [
      const RoutePoint(seq: 0, tsMs: 1000000, lat: 1.0, lng: 2.0, accuracy: 5),
      const RoutePoint(seq: 1, tsMs: 1001000, lat: 1.1, lng: 2.1),
    ];
    final b2 = [
      const RoutePoint(seq: 2, tsMs: 1002000, lat: 1.2, lng: 2.2, alt: 30),
    ];
    await LocalDb.appendRoutePoints(id, [for (final p in b1) p.toRow(id)]);
    await LocalDb.appendRoutePoints(id, [for (final p in b2) p.toRow(id)]);

    expect(await LocalDb.sessionHasRoute(id), true);

    final rows = await LocalDb.routePoints(id);
    expect(rows.length, 3);
    final pts = [for (final r in rows) RoutePoint.fromRow(r)];
    expect(pts.map((e) => e.seq).toList(), [0, 1, 2]);
    expect(pts[0].lat, 1.0);
    expect(pts[0].accuracy, 5);
    expect(pts[2].alt, 30);
  });

  test('hrSamplesInRange returns only worn seconds in the window', () async {
    // Populate decoded_onehz via the normal insert path.
    await LocalDb.insertRecord(_raw(2000, 200), _sample(2000, 200, 120));
    await LocalDb.insertRecord(_raw(2001, 201), _sample(2001, 201, 0)); // unworn
    await LocalDb.insertRecord(_raw(2002, 202), _sample(2002, 202, 130));
    await LocalDb.insertRecord(_raw(9999, 203), _sample(9999, 203, 140)); // out

    final rows = await LocalDb.hrSamplesInRange(1999, 2003);
    expect(rows.length, 2); // hr 0 filtered, 9999 out of window
    final hrs = [for (final r in rows) (r['hr'] as num).toInt()];
    expect(hrs, [120, 130]); // ascending by rec_ts
  });

  test('deleteSession cascades to route rows', () async {
    const id = 'w-route-1';
    expect(await LocalDb.sessionHasRoute(id), true);
    await LocalDb.deleteSession(id);
    expect(await LocalDb.sessionHasRoute(id), false);
    expect(await LocalDb.routePoints(id), isEmpty);
  });
}
