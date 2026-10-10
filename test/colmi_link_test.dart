// The Colmi HOST: scripted ring in, database rows out. `flutter_blue_plus` has
// no simulator path, so the ring below is a script driven through the REAL
// adapter, the real [BandHost] and real sqlite. This file pins where each
// decoded thing LANDS; `test/adapters/colmi_test.dart` pins what is decoded.

import 'package:flutter_blue_plus/flutter_blue_plus.dart' show Guid;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/gatt_link.dart';
import 'package:openstrap_edge/ble/colmi_link.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _deviceId = 'colmi-0a1b2c3d';
final DateTime _now = DateTime(2026, 10, 4, 12, 0);
int _nowSec() => _now.millisecondsSinceEpoch ~/ 1000;
DateTime _at(int daysAgo, int minute) =>
    DateTime(_now.year, _now.month, _now.day - daysAgo, 0, minute);

/// Battery, yesterday's HR, one night of sleep; everything else "no data".
List<List<int>> _ring(int _, List<int> w) {
  final cmd = w[0];
  switch (cmd) {
    case kColmiCmdBattery:
      return [colmiFrame(cmd, [64])];
    case kColmiCmdHrHistory:
      final ts = w[1] | (w[2] << 8) | (w[3] << 16) | (w[4] << 24);
      final y = _at(1, 0);
      if (ts != y.millisecondsSinceEpoch ~/ 1000 + y.timeZoneOffset.inSeconds) {
        return [colmiFrame(cmd, [0xff])];
      }
      return [
        colmiFrame(cmd, [0, 2]),
        colmiFrame(cmd, [1, 0, 0, 0, 0, 61, 63]),
      ];
    case kColmiCmdActivityHistory:
    case kColmiCmdHrvHistory:
    case kColmiCmdStressHistory:
      return [colmiFrame(cmd, [0xff])];
    case kColmiCmdBigData:
      if (w[1] != kColmiBigSleep) return const [];
      return [
        colmiBigDataRequest(kColmiBigSleep, [
          1, 0, 8, 0x64, 0x05, 0x68, 0x01, //
          kColmiStageLight, 240, kColmiStageDeep, 180,
        ]),
      ];
  }
  return const [];
}

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

  Future<void> sync() =>
      ColmiLink.instance.ingestForTest(_deviceId, _ring, nowSeconds: _nowSec);

  test('HR lands in decoded_onehz under source colmi, outside derivation',
      () async {
    await sync();
    final db = await LocalDb.instance;
    final rows = await db.query('decoded_onehz', orderBy: 'rec_ts');
    expect(rows.map((r) => (r['rec_ts'], r['hr'])), [
      (_at(1, 0).millisecondsSinceEpoch ~/ 1000, 61),
      (_at(1, 5).millisecondsSinceEpoch ~/ 1000, 63),
    ]);
    for (final r in rows) {
      expect(r['device_id'], _deviceId);
      expect(r['source'], kColmi.id);
    }
    // Not admitted to derivation until the decode has met a real ring.
    expect(kDerivableSources, isNot(contains(kColmi.id)));
  });

  test('the ring\'s sleep stages land in vendor_sleep_epoch', () async {
    await sync();
    final db = await LocalDb.instance;
    final epochs = await db.query('vendor_sleep_epoch', orderBy: 'start_ts');
    expect(epochs.map((e) => e['stage']), ['light', 'deep']);
    expect(epochs.first['device_id'], _deviceId);
    expect(epochs.first['source'], 'colmi');
    expect(epochs.last['end_ts'], _at(0, 360).millisecondsSinceEpoch ~/ 1000);
  });

  test('stage minutes land in observation, attributed, display-only',
      () async {
    await sync();
    final db = await LocalDb.instance;
    final obs = await db.query('observation', orderBy: 'vendor_key');
    expect(obs.map((o) => (o['vendor_key'], o['value'])),
        [
          ('sleep_deep_min', 180.0),
          ('sleep_light_min', 240.0),
          // A stage the night has none of is written as 0, so a re-report
          // overwrites an earlier report's minutes for it.
          ('sleep_rem_min', 0.0),
          ('sleep_wake_min', 0.0),
        ]);
    for (final o in obs) {
      expect(o['source_kind'], 'vendor');
      expect(o['attribution'], 'Colmi');
      expect(o['device_id'], _deviceId);
    }
  });

  test('every reply is banked verbatim, never re-drivable', () async {
    await sync();
    final db = await LocalDb.instance;
    final archive = await db.query('raw_archive');
    final reasons = archive.map((a) => a['reason']).toSet();
    expect(reasons,
        containsAll(['colmi_cmd_0x03', 'colmi_cmd_0x15', 'colmi_big_0x27']));
    for (final a in archive) {
      expect(a['counter'], isNull);
      expect(LocalDb.redrivableArchiveReasons, isNot(contains(a['reason'])));
    }
  });

  test('battery note is held on the link', () async {
    await sync();
    expect(ColmiLink.instance.batteryPct, 64);
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
      expect(await ColmiLink.forgetRing(_deviceId), isTrue);
      expect(await ColmiLink.pairedRingRow(), isNull);
    });

    test('refuses the primary device id outright', () async {
      expect(await ColmiLink.forgetRing(LocalDb.kPrimaryDeviceId), isFalse);
    });

    test('a device id nothing paired is a harmless no-op', () async {
      expect(await ColmiLink.forgetRing('colmi-never-paired'), isTrue);
      expect(await ColmiLink.pairedRingRow(), isNull);
    });
  });

  group('discovery', () {
    test('the scan filter takes the advertised 0xFEE7 beside the GATT service',
        () {
      expect(HrsLink.scanServiceFilter([kColmi]),
          [Guid(kColmiService), Guid('fee7')]);
      // A hint shared by nothing else in the sweep is added once.
      expect(HrsLink.scanServiceFilter([kBleHrs, kColmi]),
          [Guid(kBleHrs.service), Guid(kColmiService), Guid('fee7')]);
    });

    test('names: R01-R06/R09 prefix (no underscore needed), COLMI, Qore', () {
      final m = kColmi.nameMatcher!;
      for (final n in [
        'r01_ab12',
        'r05',
        'r02_x',
        'r04_1a2b',
        'r09_c3',
        'colmi r10_x',
        'qore 7f2a',
      ]) {
        expect(m(n), isTrue, reason: n);
      }
      for (final n in ['r1', 'rx02', 'r07_x', 'r08', 'core', 'colmi r11_x']) {
        expect(m(n), isFalse, reason: n);
      }
    });
  });

  test('reboot and factory reset never reach the ring', () async {
    final link = GattBandLink(entry: kColmi, services: const [], onLog: (_) {});
    final sent = <List<int>>[];
    link.debugWriteHook = (v) async {
      sent.add(v);
      return true;
    };
    expect(await link.write(kColmiWriteChar, colmiFrame(kColmiCmdReboot)),
        isFalse);
    expect(
        await link.write(kColmiWriteChar, colmiFrame(kColmiCmdFactoryReset)),
        isFalse);
    expect(await link.write(kColmiWriteChar, colmiBatteryRequest()), isTrue);
    expect(sent, [colmiBatteryRequest()]);
  });
}
