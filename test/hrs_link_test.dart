// The standard Bluetooth heart-rate sensor path: 0x2A37 in, `decoded_onehz` /
// `decoded_rr` out.
//
// THE DECODE ITSELF (`parseHeartRateMeasurement`) IS NOT PINNED HERE — it is
// pure protocol and its own tests live with it in the protocol package. This
// file is the WRITE half: given already-decoded bytes, do they land in the
// substrate correctly attributed. Still EXPERIMENTAL (ASSUMPTIONS R6) —
// nobody on this project owns a strap and `flutter_blue_plus` has no
// simulator path, so this proves the write is correct, not that any real
// strap sends these exact bytes.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/ble_state.dart'
    show acquireSecondaryLinkSlot, releaseSecondaryLinkSlot;
import 'package:openstrap_edge/ble/hrs_link.dart';
import 'package:openstrap_edge/data/db.dart';

/// Frames as the three common flag shapes put them on the wire.
///
/// The RR-Interval flag (bit 4) is OPTIONAL in the spec, and [bpmOnly] is the
/// case that matters most: plenty of optical armbands never set it, and the
/// parser has to degrade to "HR, no beats" rather than assume beats are there.
const List<int> kBpmOnly = <int>[0x00, 61]; // flags 0x00 — RR bit CLEAR
const List<int> kBpmOnlyWithContact = <int>[0x06, 61]; // contact reported
const List<int> kHrWithTwoRr = <int>[
  0x16, // uint8 HR + contact supported/detected + RR present
  120,
  0xF4, 0x01, // 500 ticks = 488 ms
  0x00, 0x02, // 512 ticks = 500 ms
];

void main() {
  group('substrate write', () {
    const deviceId = 'hrs-0a1b2c3d';

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      await LocalDb.close();
      LocalDb.dbName = 'hrs_link_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDown(() async => LocalDb.close());

    test('HR and beats land in the real substrate, attributed', () async {
      await HrsLink.instance.ingestForTest(deviceId, const [
        (1_800_000_000, kHrWithTwoRr),
        (1_800_000_001, kBpmOnly),
      ]);

      final db = await LocalDb.instance;
      final onehz = await db.query('decoded_onehz', orderBy: 'ts_ms');
      expect(onehz, hasLength(2));
      expect(onehz.first['device_id'], deviceId);
      expect(onehz.first['device_id'], isNot(LocalDb.kPrimaryDeviceId));
      expect(onehz.first['ts_ms'], 1_800_000_000 * 1000);
      expect(onehz.first['rec_ts'], 1_800_000_000);
      expect(onehz.first['hr'], 120);
      expect(onehz.first['source'], 'ble_hrs');
      expect(onehz.first['device_family'], 'ble_hrs');
      // A strap has no accelerometer, no optical block and no thermistor.
      // Absent is NULL — never a measurement of zero.
      for (final c in ['ax', 'ay', 'az', 'spo2_red_raw', 'skin_temp_raw']) {
        expect(onehz.first[c], isNull, reason: c);
      }
      // The RR-bit-clear second is still a heart rate.
      expect(onehz.last['hr'], 61);

      final rr = await db.query('decoded_rr', orderBy: 'ts_ms, beat_index');
      expect(rr, hasLength(2), reason: 'only the first second carried beats');
      expect(rr.map((r) => r['rr_ms']), [488, 500]);
      expect(rr.map((r) => r['beat_index']), [0, 1]);
      expect(rr.first['device_id'], deviceId);
      expect(rr.first['source'], 'ble_hrs');
      // THE LOAD-BEARING ONE. `beat_ts_ms` means "where the beat actually
      // was"; this source has no clock, so we do not know. An arrival anchor
      // written there would be a measured claim we cannot make.
      expect(rr.first['beat_ts_ms'], isNull);
      expect(rr.first['rr_ts_ms'], 1_800_000_000 * 1000,
          reason: 'the arrival second, which is all the anchor there is');
    });

    test('two notifications in one second do not evict each other', () async {
      // The failure this prevents: writing the second twice restarts
      // `beat_index` at 0 and REPLACE deletes the beats already stored.
      await HrsLink.instance.ingestForTest(deviceId, const [
        (1_800_000_000, kHrWithTwoRr),
        (1_800_000_000, kHrWithTwoRr),
      ]);
      final db = await LocalDb.instance;
      expect(await db.query('decoded_onehz'), hasLength(1));
      final rr = await db.query('decoded_rr', orderBy: 'beat_index');
      expect(rr.map((r) => r['beat_index']), [0, 1, 2, 3]);
    });

    test('an off-chest reading is refused, not stored as a low HR', () async {
      await HrsLink.instance.ingestForTest(deviceId, const [
        (1_800_000_000, <int>[0x04, 45]), // contact bits 0b10 = no contact
      ]);
      final db = await LocalDb.instance;
      expect(await db.query('decoded_onehz'), isEmpty);
    });

    test('the band-only readers cannot see a strap row', () async {
      await HrsLink.instance.ingestForTest(deviceId, const [
        (1_800_000_000, kHrWithTwoRr),
      ]);
      final db = await LocalDb.instance;
      final banded = await db.rawQuery(
        'SELECT COUNT(*) c FROM decoded_onehz WHERE source IS NULL',
      );
      expect(banded.first['c'], 0,
          reason: 'every derive/export read filters `source IS NULL`');
    });

    test('the primary device id is refused outright', () async {
      // `''` is the primary band, permanently (ASSUMPTIONS A1). A sensor
      // writing under it would interleave with the band's own seconds in a
      // REPLACE-keyed table, unrecoverably.
      await LocalDb.upsertDevice(
        adapterId: kBleHrs.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
      );
      expect(await HrsLink.instance.arm(), isFalse);
    });

    test('nothing paired means nothing armed', () async {
      expect(await HrsLink.instance.arm(), isFalse);
      expect(await HrsLink.pairedSensorRow(), isNull);
    });

    test('two arms in flight are ONE arm', () async {
      // Every caller fires this `unawaited`, and the body awaits a database
      // read, a 12 s connect and discovery before it publishes anything. A
      // second call used to walk straight past the `_armed` check and overwrite
      // the first one's `_device`, `_link`, `_runSub` and `_flushTimer` — the
      // originals then ran on with nothing holding them. Same future, one
      // attempt.
      final a = HrsLink.instance.arm();
      final b = HrsLink.instance.arm();
      expect(identical(a, b), isTrue);
      expect(await a, isFalse);
      expect(await b, isFalse);
      // And the memo clears, so a later arm is a real attempt again.
      expect(identical(HrsLink.instance.arm(), a), isFalse);
    });

    test('forgetting an unrelated watch9 row leaves this strap session alone',
        () async {
      // Regression: forgetDevice used to fall through to the generic branch
      // for any non-Oura row, which disarms `HrsLink.instance` — the
      // completely unrelated chest-strap singleton — even when the row being
      // forgotten belongs to Watch9Link's own session.
      await HrsLink.instance.ingestForTest(deviceId, const [
        (1_800_000_000, kHrWithTwoRr),
      ]);
      expect(HrsLink.instance.reading.value, isNotNull);

      const watch9Id = 'watch9-aa11bb22';
      await LocalDb.upsertDevice(
        id: watch9Id,
        adapterId: kWatch9.id,
        remoteId: '11:22:33:44:55:66',
      );
      await HrsLink.forgetDevice(watch9Id);

      // `disarm()` unconditionally nulls this on its way out — if it had
      // fired, this would be null too.
      expect(HrsLink.instance.reading.value, isNotNull);
      final row = (await LocalDb.deviceRows())
          .where((r) => r['id'] == watch9Id)
          .toList();
      expect(row, isEmpty, reason: 'the watch9 row itself is still forgotten');
    });
  });

  // WHY THESE LIVE AT THIS LEVEL. `flutter_blue_plus` has no simulator path,
  // so a test cannot hold a real 12 s connect open — but it does not have to.
  // `_arm` awaits a secondary-link slot immediately BEFORE `connect()`, so
  // exhausting the cap parks an attempt for as long as the test likes, in
  // pure Dart, at the exact point the traced races happen. Past that point
  // `connect()` throws (no plugin is registered under `flutter test`), which
  // is the failing-arm path these tests want anyway.
  group('arm/disarm serialisation', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      await LocalDb.close();
      LocalDb.dbName = 'hrs_arm_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.upsertDevice(
        id: 'hrs-0a1b2c3d',
        adapterId: kBleHrs.id,
        remoteId: 'AA:BB:CC:DD:EE:FF',
        label: 'Test Strap',
        tier: 'beatToBeat',
      );
    });

    tearDown(() async {
      // Before the disarm, or the cleanup throws the failure the test asked
      // for.
      HrsLink.failTeardownForTest = null;
      await HrsLink.instance.disarm();
      await LocalDb.close();
    });

    /// Both slots, so nothing can get past `_arm`'s acquire until the test
    /// says so. Returns them in the order they must be given back.
    Future<void> takeBothSlots() async {
      expect(await acquireSecondaryLinkSlot(), isTrue);
      expect(await acquireSecondaryLinkSlot(), isTrue);
    }

    /// Two acquires only BOTH succeed against a cap of two if the attempts
    /// under test released everything they took.
    Future<void> expectNoSlotLeak() async {
      const wait = Duration(seconds: 2);
      expect(await acquireSecondaryLinkSlot(timeout: wait), isTrue);
      expect(await acquireSecondaryLinkSlot(timeout: wait), isTrue,
          reason: 'a slot was never released');
      releaseSecondaryLinkSlot();
      releaseSecondaryLinkSlot();
    }

    test('arm → disarm → arm inside one window gives a FRESH attempt',
        () async {
      await takeBothSlots();
      final a = HrsLink.instance.arm();
      // Let it get as far as the acquire, where it now cannot proceed.
      await pumpEventQueue();
      await HrsLink.instance.disarm();
      final b = HrsLink.instance.arm();

      // THE REGRESSION. `_arming` was memoized but not generation-guarded and
      // `disarm()` never cleared it, so `b` was handed `a` — the attempt the
      // disarm had just cancelled, which can only answer `false` now. Both
      // callers got `false`, nothing was armed, and `b` had never tried.
      expect(identical(a, b), isFalse);

      releaseSecondaryLinkSlot();
      releaseSecondaryLinkSlot();
      // `a` was cancelled, so `false` is the honest answer for it. `b` really
      // tried: it took a slot and reached `connect()`, which has no plugin
      // registered under a test.
      expect(await a, isFalse);
      expect(await b, isFalse);
      // And the cancelled attempt did not take the fresh one down with it —
      // no dangling half-armed state either way.
      await expectNoSlotLeak();
    });

    test('the cancelled attempt resolves last and disturbs nothing', () async {
      // Same sequence, opposite wake order: the FRESH attempt finishes before
      // the cancelled one is even woken, so `a`'s cleanup lands on state `b`
      // has already finished with. Both must still answer cleanly and neither
      // may strand a slot.
      //
      // NOT the test for `_arm`'s generation-aware catch — that branch needs
      // the disarm to land INSIDE `connect()`, and `connect()` throws before
      // its first real await under a test (no plugin is registered), so `a`
      // bails at the post-acquire check here instead. That branch is
      // trace-verified only; a seam to reach it would be a fake connect,
      // which proves the fake.
      await takeBothSlots();
      final a = HrsLink.instance.arm();
      await pumpEventQueue();
      await HrsLink.instance.disarm();
      final b = HrsLink.instance.arm();
      releaseSecondaryLinkSlot();
      expect(await b, isFalse);
      releaseSecondaryLinkSlot();
      expect(await a, isFalse);
      await expectNoSlotLeak();
    });

    test('a teardown that throws still releases the slot it held', () async {
      HrsLink.failTeardownForTest = () => throw StateError('tail flush failed');
      // The arm reaches `connect()`, which throws (no plugin); its catch tears
      // down, and the teardown throws on top of that. `_disarm` had no
      // try/finally, so every line below `_host.stop()` was skipped — and the
      // secondary-link slot the arm took before connecting stayed held for the
      // life of the process, so the strap could never be armed again.
      expect(await HrsLink.instance.arm(), isFalse,
          reason: 'a failed teardown must not become a THROWN arm()');
      expect(await HrsLink.instance.arm(), isFalse);
      await expectNoSlotLeak();
    });

    test('a teardown that throws still clears what a surface reads', () async {
      // The rest of that `finally`, and the only part a test with no radio can
      // observe directly: `_reading` is cleared on the LAST line of it, after
      // `_armed = false`, `_host = null` and the slot release, so a null here
      // means all of those ran too. (`_armed` cannot be pinned on its own —
      // proving it stale needs an arm that SUCCEEDED, and `flutter_blue_plus`
      // has no path to one under a test.)
      await HrsLink.instance.ingestForTest('hrs-0a1b2c3d', const [
        (1_800_000_000, kHrWithTwoRr),
      ]);
      expect(HrsLink.instance.reading.value, isNotNull,
          reason: 'a replayed beat is what there is to leave behind');

      HrsLink.failTeardownForTest = () => throw StateError('tail flush failed');
      // The error still reaches the caller — someone awaiting a flush before
      // reading the session back must learn it failed. It just no longer takes
      // the state with it.
      await expectLater(
          HrsLink.instance.disarm(), throwsA(isA<StateError>()));
      expect(HrsLink.instance.reading.value, isNull,
          reason: 'a number left on screen after the link died is a lie');
    });

    test('an arm chained on a FAILING teardown still runs', () async {
      HrsLink.failTeardownForTest = () => throw StateError('tail flush failed');
      final d = HrsLink.instance.disarm();
      final a = HrsLink.instance.arm(); // chains on that teardown
      // The disarm's own caller still learns the flush failed. That error is
      // theirs — which is exactly why the arm must not inherit it.
      await expectLater(d, throwsA(isA<StateError>()));
      // `teardown.then((_) => arm())` had no `onError`: the chain broke, the
      // arm never ran, and a caller that only asked to be armed got the
      // flush's StateError thrown at it instead of an answer.
      expect(await a, isFalse);
      await expectNoSlotLeak();
    });

    test('a WHOOP-only install still exits before it touches anything',
        () async {
      // No `ble_hrs` row at all — the single-device case, which must reach the
      // same early return it always did: no slot taken, no connect, no state.
      await LocalDb.deleteDevice('hrs-0a1b2c3d');
      expect(await HrsLink.pairedSensorRow(), isNull);
      expect(await HrsLink.instance.arm(), isFalse);
      await expectNoSlotLeak();
    });
  });

  group('forgetDevice', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      await LocalDb.close();
      LocalDb.dbName = 'hrs_forget_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    });

    tearDown(() async => LocalDb.close());

    test(
        'an HPlus row goes through HPlusLink.instance, not the '
        'chest-strap disarm', () async {
      const id = 'hplus-11223344';
      await LocalDb.upsertDevice(
        id: id,
        adapterId: kHPlus.id,
        remoteId: 'AA:BB:CC:DD:EE:00',
        label: 'Test Band',
      );

      // No BLE plugin is registered under `flutter test`, so this only
      // proves the dispatch: it must reach `HPlusLink.instance.stop()`
      // (a no-op with nothing connected) rather than `HrsLink.instance
      // .disarm()`, and it must delete the row either way.
      await HrsLink.forgetDevice(id);

      final rows = await LocalDb.deviceRows();
      expect(rows.where((r) => r['id'] == id), isEmpty);
    });
  });

  // Pure derivation, no BLE plugin needed — pulled out of `pairNotifySensor`
  // specifically so this ternary has a test that doesn't need one.
  group('tier derivation', () {
    test('a strap that declares beat-to-beat gets that tier by default', () {
      expect(HrsLink.deriveTier(null, kBleHrs.id), 'beatToBeat');
    });

    test('a band that declares no signals stays null, not inherited', () {
      expect(HrsLink.deriveTier(null, kHPlus.id), isNull);
    });

    test('an explicit tier always wins over the derivation', () {
      expect(HrsLink.deriveTier('explicit', kHPlus.id), 'explicit');
      expect(HrsLink.deriveTier('explicit', kBleHrs.id), 'explicit');
    });
  });
}
