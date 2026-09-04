// M6 -- the first observation reader (spec-m6.md §12, §13.2 test 11).
//
// LocalDb.observationsForDay returns rows with their attribution, and no
// adapter in the tree declares vendorScalars today so the VendorScalars
// branch writes zero rows on every real install -- proved here, not shipped
// as an assertion about a number nobody can see move.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_edge/ble/adapters/ble_hrs.dart';
import 'package:openstrap_edge/ble/adapters/oura.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no adapter in the tree declares vendorScalars', () {
    expect(const BleHrsAdapter().signals.keys, isNot(contains(InputSignal.vendorScalars)));
    expect(
      OuraAdapter(key: const []).signals.keys,
      isNot(contains(InputSignal.vendorScalars)),
    );
  });

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'observation_reader_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance;
  });

  tearDown(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('observationsForDay returns rows with their attribution, ordered', () async {
    await LocalDb.putObservations(
      [
        Observation(
          at: DateTime(2026, 9, 1, 8),
          sourceKind: ObservationSource.vendor,
          vendorKey: 'Sleep score',
          value: 82,
          attribution: 'Oura',
        ),
      ],
      deviceId: 'oura-A1B2',
    );

    final rows = await LocalDb.observationsForDay('2026-09-01');
    expect(rows.length, 1);
    expect(rows.single['attribution'], 'Oura');
    expect(rows.single['vendor_key'], 'Sleep score');
    expect(rows.single['value'], 82.0);
  });

  test('an empty day returns no rows', () async {
    expect(await LocalDb.observationsForDay('2026-09-02'), isEmpty);
  });
}
