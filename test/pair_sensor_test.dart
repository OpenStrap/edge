// THE DOOR — the pairing screen and the two pieces of HrsLink behind it.
//
// The whole heart-rate-sensor path shipped unreachable: `HrsLink.arm()` reads
// a `device` row and nothing created one, so it returned false on every call
// forever. What is pinned here is the part of the fix that can be wrong
// SILENTLY:
//
//   * the minted `device.id`. It is a PRIMARY KEY. If it is ever the BLE
//     remote id, one sensor becomes N identities; if it is ever `''`, a strap
//     writes its seconds into the primary band's rows; and if it is not stable
//     across restarts, re-pairing the same sensor orphans its own history.
//   * the live surface. A reading left on screen after the link died is the
//     one lie this surface can tell, and `null` vs `bpm == null` are different
//     sentences ("no sensor" vs "no signal yet"), neither of which is a zero.
//   * the screen's states. Rendered, not read: this project has paid three
//     times for layout faults that inspecting a widget tree does not find.
//
// The scan itself is not here and cannot be: `flutter_blue_plus` has no
// simulator path, so a scan test would only prove the fake.

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ui2/profile/pair_sensor.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

BandCandidate _cand(String id, {String? label, int rssi = -60}) => (
      device: BluetoothDevice.fromId(id),
      label: label,
      rssi: rssi,
      entryId: 'ble_hrs',
    );

Future<void> _pump(
  WidgetTester t,
  PairSensorView view, {
  double scale = 1,
}) async {
  t.view.physicalSize = Size(390 * 3, 2400 * 3 * scale);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: MaterialApp(theme: buildTheme(Brightness.light), home: view),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  group('the minted device id', () {
    test('is never the remote id and never the primary band', () {
      const remote = '0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9';
      final id = HrsLink.mintDeviceId(kBleHrs, remote);
      expect(id, isNot(remote));
      expect(id, isNot(LocalDb.kPrimaryDeviceId));
      expect(id, startsWith('${kBleHrs.id}-'));
    });

    test('is stable for the same remote id and distinct for another', () {
      // Stability is the whole point: `String.hashCode` is only promised
      // within one run, and this value has to name the same sensor tomorrow.
      expect(
        HrsLink.mintDeviceId(kBleHrs, 'AA:BB:CC:DD:EE:FF'),
        HrsLink.mintDeviceId(kBleHrs, 'AA:BB:CC:DD:EE:FF'),
      );
      expect(
        HrsLink.mintDeviceId(kBleHrs, 'AA:BB:CC:DD:EE:FF'),
        isNot(HrsLink.mintDeviceId(kBleHrs, 'AA:BB:CC:DD:EE:F0')),
      );
    });

    test('a different band mints a different id for the same peripheral', () {
      // Two adapters over one physical device are two sources with two
      // measurement tiers, and merging them under one key is the silent kind
      // of wrong.
      expect(
        HrsLink.mintDeviceId(kBleHrs, 'X'),
        isNot(HrsLink.mintDeviceId(kOura, 'X')),
      );
    });
  });

  group('the live surface', () {
    // `ingestForTest` flushes into the real substrate on its way out, so the
    // database has to be a real one — the reading is what is under test, not
    // the write, but a flush with nowhere to go would hang the seam.
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      await LocalDb.close();
      LocalDb.dbName = 'pair_sensor_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDown(() async => LocalDb.close());

    test('starts absent, follows the beats, and is absent again after disarm',
        () async {
      final link = HrsLink.instance;
      expect(link.reading.value, isNull, reason: 'no sensor armed');

      // flags 0x10 (RR present) + 72 bpm + one 1000 ms beat.
      await link.ingestForTest('hrs-test', [
        (1_700_000_000, [0x10, 72, 0x00, 0x04]),
      ]);
      expect(link.reading.value?.bpm, 72);
      expect(link.reading.value?.atSec, 1_700_000_000);

      await link.disarm();
      expect(link.reading.value, isNull,
          reason: 'a number left on screen after the link died is a lie');
    });
  });

  group('the paired lookup', () {
    // `PairSensorScreen` is generic over `BandEntry` — it is pushed for a
    // Colmi ring exactly as it is for a strap. `_load()` used to ask
    // `HrsLink.pairedSensorRow()`, which only ever matches `ble_hrs`; a ring
    // row was invisible to its own pairing screen and "already paired" never
    // rendered. Pinned against the real database, not a fake, because the bug
    // was in what column value the query matched, not in the widget tree.
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      await LocalDb.close();
      LocalDb.dbName = 'pair_sensor_paired_lookup_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDown(() async => LocalDb.close());

    testWidgets('a paired Colmi ring renders the Paired section for its own '
        'screen, not "nothing paired"', (t) async {
      // `t.runAsync` — a `testWidgets` body runs under `FakeAsync`, which
      // does not drive real I/O (sqflite_common_ffi's real isolate/FFI
      // round trip); the write here and the poll below both escape into it,
      // matching `ui2_labs_delete_test.dart`'s `_seed`/`_until` idiom.
      await t.runAsync(() => LocalDb.upsertDevice(
            id: 'colmi-aaaa1111',
            adapterId: kColmi.id,
            remoteId: 'AA:BB:CC:DD:EE:FF',
            label: 'R02_1234',
            tier: 'raw',
          ));

      t.view.physicalSize = const Size(390 * 3, 2400 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: PairSensorScreen(entry: kColmi),
      ));
      // `_load()`'s own real DB read (fired from `initState`, unawaited)
      // needs the same real-async escape to ever resolve under this zone.
      for (var i = 0; i < 60 && find.text('Paired').evaluate().isEmpty; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }

      expect(find.text('Paired'), findsOneWidget);
      expect(find.text('R02_1234'), findsOneWidget);
      expect(find.text('Forget this sensor'), findsOneWidget);
    });
  });

  group('the screen renders', () {
    testWidgets('nothing paired, nothing found: it says what would find one',
        (t) async {
      await _pump(t, const PairSensorView(entryLabel: 'Bluetooth heart rate '
          'sensor'));
      expect(layoutFaults, isEmpty);
      expect(find.text('Search for sensors'), findsOneWidget);
      expect(find.text('Nothing found yet'), findsOneWidget);
      // Never a promise the honesty contract cannot keep.
      expect(find.textContaining('recovery'), findsNothing);
    });

    testWidgets('the iOS gate replaces the button with the reason', (t) async {
      await _pump(
        t,
        const PairSensorView(
          entryLabel: 'Bluetooth heart rate sensor',
          heldBack: 'Your WHOOP is not paired yet.',
        ),
      );
      expect(layoutFaults, isEmpty);
      // The plain button is gone — the choice has to be made knowingly.
      expect(find.text('Search for sensors'), findsNothing);
      expect(find.text('Your WHOOP is not paired yet.'), findsOneWidget);
      expect(find.text('Search anyway'), findsOneWidget);
    });

    // Order is the scan's (strongest signal first) and is applied in
    // `HrsLink._ranked`, which cannot be reached without a radio — the view
    // draws what it is handed, which is what this pins.
    testWidgets('every candidate is a row, and an unnamed one is told apart',
        (t) async {
      final picked = <String>[];
      await _pump(
        t,
        PairSensorView(
          entryLabel: 'Bluetooth heart rate sensor',
          candidates: [
            _cand('AA:BB:CC:DD:EE:01', label: 'Polar H10', rssi: -42),
            _cand('AA:BB:CC:DD:EE:02', rssi: -77),
          ],
          onPick: (c) => picked.add(c.device.remoteId.str),
        ),
      );
      expect(layoutFaults, isEmpty);
      expect(find.text('Polar H10'), findsOneWidget);
      expect(find.text('-42 dBm'), findsOneWidget);
      // No name means the id tail is what tells two of them apart.
      expect(find.text('…EE:02 · -77 dBm'), findsOneWidget);

      await t.tap(find.text('Polar H10'));
      await t.pumpAndSettle();
      expect(picked, ['AA:BB:CC:DD:EE:01']);
    });

    testWidgets('a pair in flight locks the rest of the list', (t) async {
      final picked = <String>[];
      await _pump(
        t,
        PairSensorView(
          entryLabel: 'Bluetooth heart rate sensor',
          candidates: [
            _cand('AA:BB:CC:DD:EE:01', label: 'Polar H10', rssi: -42),
            _cand('AA:BB:CC:DD:EE:02', label: 'Wahoo TICKR', rssi: -77),
          ],
          busyRemoteId: 'AA:BB:CC:DD:EE:01',
          onPick: (c) => picked.add(c.device.remoteId.str),
        ),
      );
      expect(layoutFaults, isEmpty);
      expect(find.text('Pairing…'), findsOneWidget);
      await t.tap(find.text('Wahoo TICKR'));
      await t.pumpAndSettle();
      expect(picked, isEmpty, reason: 'two pairings at once is two GATT links');
    });

    testWidgets('forget says what it removes and what it does not', (t) async {
      final forgotten = <String>[];
      await _pump(
        t,
        PairSensorView(
          entryLabel: 'Bluetooth heart rate sensor',
          paired: (id: 'ble_hrs-0a1b2c3d', label: 'Polar H10'),
          onForget: forgotten.add,
        ),
      );
      expect(layoutFaults, isEmpty);
      expect(find.text('Polar H10'), findsOneWidget);
      expect(
        find.text('Removes the source. The readings it already took stay.'),
        findsOneWidget,
      );
      await t.tap(find.text('Forget this sensor'));
      await t.pumpAndSettle();
      expect(forgotten, ['ble_hrs-0a1b2c3d']);
    });

    testWidgets('a failure is a sentence, not a code', (t) async {
      await _pump(
        t,
        const PairSensorView(
          entryLabel: 'Bluetooth heart rate sensor',
          problem: 'That sensor did not answer.',
        ),
      );
      expect(layoutFaults, isEmpty);
      expect(find.text('That sensor did not answer.'), findsOneWidget);
    });

    testWidgets('nothing overflows at 3.1x text', (t) async {
      await _pump(
        t,
        PairSensorView(
          entryLabel: 'Bluetooth heart rate sensor',
          paired: (id: 'ble_hrs-0a1b2c3d', label: 'Polar H10'),
          candidates: [_cand('AA:BB:CC:DD:EE:01', label: 'Polar H10')],
          problem: 'That sensor did not answer.',
        ),
        scale: 3.1,
      );
      expect(layoutFaults, isEmpty);
    });
  });
}

/// Layout faults are reported as caught exceptions, not failed matchers — a
/// negative margin asserting on every build still leaves a findable tree.
List<Object> get layoutFaults {
  final out = <Object>[];
  while (true) {
    final e = TestWidgetsFlutterBinding.instance.takeException();
    if (e == null) break;
    out.add(e as Object);
  }
  return out;
}
