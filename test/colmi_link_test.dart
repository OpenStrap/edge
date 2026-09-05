// The Colmi HOST: scripted ring in, `raw_archive` out. Same reasoning as
// `oura_link_test.dart` — `flutter_blue_plus` has no simulator path, so the
// ring below is a script, and this file pins the HOST (banking every frame,
// `forgetRing`, `pairedRingRow`) rather than the adapter's own write sequence,
// which `test/adapters/colmi_test.dart` already covers.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/colmi.dart';
import 'package:openstrap_edge/ble/colmi_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'colmi-0a1b2c3d';
const int _nowSec = 1786000000;

/// Answers every write with one reply frame tagged with the request's own
/// command id — enough to exercise the archive path without hand-building a
/// real multi-day history reply (that shape is `colmi_test.dart`'s job).
List<List<int>> Function(int, List<int>) _ring() =>
    (int i, List<int> v) => [List<int>.from(v)..[1] = 0x2a];

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'colmi_link_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDown(() async => LocalDb.close());

  test('every reply frame is banked verbatim, decoded or not', () async {
    await ColmiLink.instance.ingestForTest(
      _deviceId,
      _ring(),
      nowSeconds: () => _nowSec,
    );
    final db = await LocalDb.instance;
    final archive = await db.query('raw_archive', orderBy: 'captured_at, hex');
    // One battery request + 7 days * 4 commands, same count the adapter test
    // pins the write sequence at.
    expect(archive, hasLength(1 + 7 * 4));
    for (final a in archive) {
      expect(a['hex'], hasLength(32), reason: 'every real frame is 16 bytes');
      expect(a['counter'], isNull);
      expect(a['rec_ts'], isNull);
      // NOT re-drivable: `redriveArchivedRecords` replays a row's hex through
      // the WHOOP R24 chain, the wrong decoder over a Colmi frame.
      expect(LocalDb.redrivableArchiveReasons, isNot(contains(a['reason'])));
    }
    expect(
      archive.map((a) => a['reason']).toSet(),
      {
        'colmi_cmd_0x${kColmiCmdBattery.toRadixString(16).padLeft(2, '0')}',
        'colmi_cmd_0x${kColmiCmdHrHistory.toRadixString(16).padLeft(2, '0')}',
        'colmi_cmd_0x${kColmiCmdStressHistory.toRadixString(16).padLeft(2, '0')}',
        'colmi_cmd_0x${kColmiCmdHrvHistory.toRadixString(16).padLeft(2, '0')}',
        'colmi_cmd_0x${kColmiCmdActivityHistory.toRadixString(16).padLeft(2, '0')}',
      },
    );
  });

  test('no decoded row lands — this ring supplies no signal today', () async {
    await ColmiLink.instance.ingestForTest(
      _deviceId,
      _ring(),
      nowSeconds: () => _nowSec,
    );
    final db = await LocalDb.instance;
    final onehz = await db.query('decoded_onehz');
    expect(onehz, isEmpty);
  });

  test('the battery note is held on the link, not banked as a sample', () async {
    await ColmiLink.instance.ingestForTest(
      _deviceId,
      _ring(),
      nowSeconds: () => _nowSec,
    );
    expect(ColmiLink.instance.batteryPct, 0x2a);
  });

  test('nothing paired means nothing to sync', () async {
    expect(await ColmiLink.pairedRingRow(), isNull);
    expect(await ColmiLink.instance.sync(), isFalse);
  });

  group('forgetRing', () {
    test('drops the device row', () async {
      await LocalDb.upsertDevice(
        id: _deviceId,
        adapterId: kColmi.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Ring',
      );
      expect(await ColmiLink.pairedRingRow(), isNotNull);
      final ok = await ColmiLink.forgetRing(_deviceId);
      expect(ok, isTrue);
      expect(await ColmiLink.pairedRingRow(), isNull);
    });

    test('refuses the primary device id outright', () async {
      final ok = await ColmiLink.forgetRing(LocalDb.kPrimaryDeviceId);
      expect(ok, isFalse);
    });

    test('a device id nothing paired is a harmless no-op', () async {
      final ok = await ColmiLink.forgetRing('colmi-never-paired');
      expect(ok, isTrue);
      expect(await ColmiLink.pairedRingRow(), isNull);
    });
  });
}
