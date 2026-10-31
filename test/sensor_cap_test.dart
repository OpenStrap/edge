// The two-sensor pairing cap is decided from the paired `device` rows, and it
// is asked where the pair actually runs — not only on the way into a screen
// that then stays open for "Pair another".

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/ble_state.dart'
    show kMaxConcurrentSecondaryLinks;
import 'package:openstrap_edge/data/db.dart' show LocalDb;
import 'package:openstrap_edge/ui2/profile/devices.dart' show sensorCapReached;
import 'package:openstrap_edge/ui2/profile/pair_sensor.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

List<Map<String, Object?>> _rows(int secondaries,
        {bool band = true, String adapter = 'ble_hrs'}) =>
    [
      if (band) {'id': LocalDb.kPrimaryDeviceId, 'adapter_id': null},
      for (var i = 0; i < secondaries; i++)
        {'id': 'hrs:$i', 'adapter_id': adapter, 'remote_id': 'R-$i'},
    ];

const _limitText = 'This phone will pair at most $kMaxConcurrentSecondaryLinks '
    'sensors alongside your band. Remove one to add another.';

void main() {
  group('the decision', () {
    test('the primary band never counts against the cap', () {
      expect(
          sensorCapReached(_rows(kMaxConcurrentSecondaryLinks - 1)), isFalse);
      expect(
          sensorCapReached(
              _rows(kMaxConcurrentSecondaryLinks - 1, band: false)),
          isFalse);
    });

    test('reaching the cap refuses the next sensor', () {
      expect(sensorCapReached(_rows(kMaxConcurrentSecondaryLinks)), isTrue);
      expect(
          sensorCapReached(_rows(kMaxConcurrentSecondaryLinks + 1)), isTrue);
    });

    test('pairing a sensor that already has its row again is not an addition',
        () {
      final rows = _rows(kMaxConcurrentSecondaryLinks);
      expect(sensorCapReached(rows, repairingId: 'hrs:0'), isFalse);
      expect(sensorCapReached(rows, repairingId: 'hrs:new'), isTrue);
      // The band's own id is never a sensor re-pair.
      expect(sensorCapReached(rows, repairingId: LocalDb.kPrimaryDeviceId),
          isTrue);
    });

    test('the ring has one row, so any ring pair rewrites it', () {
      final rows = [
        ..._rows(kMaxConcurrentSecondaryLinks - 1),
        {'id': 'oura-1', 'adapter_id': kOura.id, 'remote_id': 'R-oura'},
      ];
      expect(sensorCapReached(rows, adapterId: kOura.id), isFalse);
      // A strap of the same kind is not single-slot: a new one is a new row.
      expect(sensorCapReached(rows, adapterId: 'ble_hrs'), isTrue);
    });

    test('a Mi Band pair replaces the Mi Band row, so it is not an addition',
        () {
      // The pick callback cannot name the row before the band is chosen, so
      // the exact check runs with no repairingId. The pair either reuses the
      // same band's row or forgets the other Mi Band rows once it succeeds.
      final rows = [
        ..._rows(kMaxConcurrentSecondaryLinks - 1),
        {
          'id': 'miband234-0a0b0c0d',
          'adapter_id': kMiBand234.id,
          'remote_id': 'R-mi'
        },
      ];
      expect(sensorCapReached(rows, adapterId: kMiBand234.id), isFalse);
      // With no Mi Band row yet, a first Mi Band is a new row and counts.
      expect(
          sensorCapReached(_rows(kMaxConcurrentSecondaryLinks),
              adapterId: kMiBand234.id),
          isTrue);
    });

    test('the soft check lets a paired kind through to its own screen', () {
      final rows = _rows(kMaxConcurrentSecondaryLinks);
      expect(sensorCapReached(rows, adapterId: 'ble_hrs', anyOfAdapter: true),
          isFalse);
      expect(
          sensorCapReached(rows, adapterId: kMiBand234.id, anyOfAdapter: true),
          isTrue);
    });
  });

  // The screen stays open after a pair and offers "Pair another", and every
  // route into it only checked on the way in. These pin the check inside the
  // pair step itself, against the real database.
  group('the pairing screen', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      await LocalDb.close();
      LocalDb.dbName = 'sensor_cap_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDown(() async => LocalDb.close());

    Future<void> seed(WidgetTester t, List<(String, String)> rows) =>
        t.runAsync(() async {
          for (final (id, adapter) in rows) {
            await LocalDb.upsertDevice(
                id: id, adapterId: adapter, remoteId: 'R-$id', label: id);
          }
        });

    Future<void> settle(WidgetTester t, bool Function() done) async {
      for (var i = 0; i < 80 && !done(); i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
    }

    Future<void> open(WidgetTester t, BandEntry entry,
        Future<String?> Function(BluetoothDevice) onPicked) async {
      t.view.physicalSize = const Size(390 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: PairSensorScreen(
          entry: entry,
          onPicked: onPicked,
          debugFound: [
            (
              device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:01'),
              label: 'New sensor',
              rssi: -50,
              entryId: entry.id,
            ),
          ],
        ),
      ));
      await settle(t, () => false); // let `_load()` finish
    }

    testWidgets('at the cap, a new sensor is refused before it pairs',
        (t) async {
      await seed(t, [
        for (var i = 0; i < kMaxConcurrentSecondaryLinks; i++)
          ('ble_hrs-$i', 'ble_hrs'),
      ]);
      var calls = 0;
      await open(t, kMiBand234, (_) async {
        calls++;
        return null;
      });
      await t.tap(find.text('New sensor'));
      await settle(t, () => find.text(_limitText).evaluate().isNotEmpty);
      expect(find.text(_limitText), findsOneWidget);
      // Dismissing the sheet is the end of it, not a way through.
      await t.tapAt(const Offset(20, 20));
      await t.pumpAndSettle();
      await settle(t, () => calls > 0);
      expect(find.text(_limitText), findsNothing);
      expect(calls, 0, reason: 'the pair must not run past the cap');
    });

    testWidgets('below the cap the pair runs', (t) async {
      await seed(t, [('ble_hrs-0', 'ble_hrs')]);
      var calls = 0;
      await open(t, kMiBand234, (_) async {
        calls++;
        return null;
      });
      await t.tap(find.text('New sensor'));
      await settle(t, () => calls > 0);
      expect(calls, 1);
      expect(find.text(_limitText), findsNothing);
    });

    testWidgets('at the cap, re-pairing the ring rewrites its row', (t) async {
      await seed(t, [
        for (var i = 0; i < kMaxConcurrentSecondaryLinks - 1; i++)
          ('ble_hrs-$i', 'ble_hrs'),
        ('oura-1', kOura.id),
      ]);
      var calls = 0;
      await open(t, kOura, (_) async {
        calls++;
        return null;
      });
      await t.tap(find.text('New sensor'));
      await settle(t, () => calls > 0);
      expect(calls, 1);
      expect(find.text(_limitText), findsNothing);
    });
  });
}
