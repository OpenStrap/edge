// A backup restored onto a new phone must not bring back the old install's
// sensor handles. A sensor's `remote_id` is a per-install peripheral handle,
// and its row id is minted from it, so a verbatim copy is a row that never
// connects, is never overwritten by re-pairing the same strap, and still
// counts toward the sensor cap: two of them refused every pair.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart' show sensorCapReached;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const oldDb = 'openstrap_restore_sensor_old_test.db';
  const newDb = 'openstrap_restore_sensor_new_test.db';
  const oldStrap = '11111111-AAAA-4000-8000-000000000001';
  const oldPolar = '11111111-AAAA-4000-8000-000000000002';
  late String backup;

  Future<void> fresh(String name) async {
    await LocalDb.close();
    LocalDb.dbName = name;
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, name));
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await fresh(oldDb);
    await LocalDb.upsertDevice(remoteId: 'OLD-WHOOP-UUID');
    await LocalDb.upsertDevice(
        id: HrsLink.mintDeviceId(kBleHrs, oldStrap),
        adapterId: kBleHrs.id,
        remoteId: oldStrap,
        label: 'Chest strap');
    await LocalDb.upsertDevice(
        id: HrsLink.mintDeviceId(kPolarPmd, oldPolar),
        adapterId: kPolarPmd.id,
        remoteId: oldPolar,
        label: 'Polar');
    final tmp = await Directory.systemTemp.createTemp('restore_sensor');
    backup = await LocalDb.exportCopy(into: tmp);
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    for (final n in [oldDb, newDb]) {
      await databaseFactory.deleteDatabase(p.join(dir, n));
    }
  });

  test('a new-phone restore keeps sensor rows but not their old handles',
      () async {
    await fresh(newDb);
    await LocalDb.importFromDbFile(backup);
    final rows = await LocalDb.deviceRows();
    expect(rows.where((r) => r['id'] == LocalDb.kPrimaryDeviceId), isEmpty);
    expect(rows.map((r) => r['id']).toSet(), {
      HrsLink.mintDeviceId(kBleHrs, oldStrap),
      HrsLink.mintDeviceId(kPolarPmd, oldPolar),
    });
    expect(rows.map((r) => r['label']).toSet(), {'Chest strap', 'Polar'});
    expect(rows.every((r) => r['remote_id'] == null), isTrue);

    // Re-pairing the same strap: this phone sees a different peripheral id.
    final newId = HrsLink.mintDeviceId(
        kBleHrs, '22222222-BBBB-4000-8000-000000000001');
    expect(sensorCapReached(rows, repairingId: newId, adapterId: kBleHrs.id),
        isFalse);
    expect(sensorCapReached(rows), isFalse);
  });

  test('a restore never blanks a sensor this phone already has paired',
      () async {
    await fresh(newDb);
    final id = HrsLink.mintDeviceId(kBleHrs, oldStrap);
    await LocalDb.upsertDevice(
        id: id, adapterId: kBleHrs.id, remoteId: oldStrap, label: 'Mine');
    await LocalDb.importFromDbFile(backup);
    final row = await LocalDb.deviceRow(id);
    expect(row?['remote_id'], oldStrap);
    expect(row?['label'], 'Mine');
  });

  test('handle-less rows do not count toward the cap; live ones still do', () {
    final live = [
      {'id': 'ble_hrs-1', 'adapter_id': kBleHrs.id, 'remote_id': 'A'},
      {'id': 'polar_pmd-2', 'adapter_id': kPolarPmd.id, 'remote_id': 'B'},
    ];
    expect(sensorCapReached(live), isTrue);
    expect(
        sensorCapReached([
          ...live.take(1),
          {'id': 'polar_pmd-2', 'adapter_id': kPolarPmd.id, 'remote_id': null},
        ]),
        isFalse);
  });

  test('re-pairing a restored ring still counts when two sensors are linked',
      () {
    // The pair links the ring, so letting it through would leave three.
    final rows = [
      {'id': 'ble_hrs-1', 'adapter_id': kBleHrs.id, 'remote_id': 'A'},
      {'id': 'polar_pmd-2', 'adapter_id': kPolarPmd.id, 'remote_id': 'B'},
      {'id': 'oura-3', 'adapter_id': kOura.id, 'remote_id': ''},
    ];
    expect(sensorCapReached(rows, adapterId: kOura.id), isTrue);
    expect(sensorCapReached(rows, adapterId: kMiBand234.id), isTrue);
  });
}
