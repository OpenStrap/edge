// PairedDevice — the persisted pairing record, including the generation the
// connect route is chosen by.
//
// What this stands in for: the generation is a DEVICE property that steers
// the bond position of every reconnect. Persist it wrong and a gen5 band runs
// its bond in the wrong place (or a new band inherits the forgotten band's
// identity), so the save/load/clear semantics get pinned directly:
// same-device saves without a generation must preserve the stored one,
// a DIFFERENT remoteId must never inherit it, and a corrupted stored value
// must sanitize to null rather than steer the route.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `PairedDevice` is table-first now (the `device` row, schema 49) with the
  // prefs pair as the mirror that heals a rebuilt database, so both halves
  // have to be real here — mocking prefs alone would exercise neither the
  // authoritative read nor the COALESCE that preserves a known generation.
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_paired_device_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Both copies, or one test's pairing steers the next one's.
    await LocalDb.deleteDevice();
  });

  test('save/load round-trips remoteId, serial and generation', () async {
    await PairedDevice.save(
      'AA:BB:CC:DD:EE:FF',
      '5AG0000001',
      generation: 'gen5',
    );
    final p = await PairedDevice.load();
    expect(p!.remoteId, 'AA:BB:CC:DD:EE:FF');
    expect(p.serial, '5AG0000001');
    expect(p.generation, 'gen5');
  });

  test(
    'a same-device save without a generation preserves the stored one',
    () async {
      await PairedDevice.save(
        'AA:BB:CC:DD:EE:FF',
        '5AG0000001',
        generation: 'gen5',
      );
      // The serial-heal save site only carries the serial.
      await PairedDevice.save('AA:BB:CC:DD:EE:FF', '5AG0000002');
      final p = await PairedDevice.load();
      expect(p!.serial, '5AG0000002');
      expect(
        p.generation,
        'gen5',
        reason: 'not knowing the generation is not evidence it changed',
      );
    },
  );

  test(
    'pairing a DIFFERENT remoteId without a generation drops the old one',
    () async {
      await PairedDevice.save(
        'AA:BB:CC:DD:EE:FF',
        '5AG0000001',
        generation: 'gen4',
      );
      await PairedDevice.save('11:22:33:44:55:66', '5AG0000009');
      final p = await PairedDevice.load();
      expect(p!.remoteId, '11:22:33:44:55:66');
      expect(
        p.generation,
        isNull,
        reason:
            'a new band must never inherit the forgotten band\'s '
            'generation — its first connect probes gen5-first instead',
      );
    },
  );

  test(
    'a garbled generation is refused on save and sanitized on load',
    () async {
      await PairedDevice.save('AA:BB:CC:DD:EE:FF', null, generation: 'gen6');
      expect((await PairedDevice.load())!.generation, isNull);
    },
  );

  // BOTH read paths, separately: `load()` answers from the table whenever it
  // has the row, so a corrupted MIRROR is only ever reached with no row —
  // seeding one without deleting the row tests nothing.
  test('a corrupted stored generation never steers the route', () async {
    // The authoritative copy: a junk `adapter_id` on the device row.
    await LocalDb.upsertDevice(
      adapterId: 'banana',
      remoteId: 'AA:BB:CC:DD:EE:FF',
      label: '5AG0000001',
      tier: 'wristOptical',
    );
    var p = await PairedDevice.load();
    expect(p!.remoteId, 'AA:BB:CC:DD:EE:FF');
    expect(
      p.generation,
      isNull,
      reason: 'adapter_id is the whole registry id space; only a framed '
          'generation may route the connect',
    );

    // The mirror, with no row for the table branch to answer from.
    await LocalDb.deleteDevice();
    SharedPreferences.setMockInitialValues({
      'paired_remote_id': 'AA:BB:CC:DD:EE:FF',
      'paired_generation': 'banana',
    });
    p = await PairedDevice.load();
    expect(p!.remoteId, 'AA:BB:CC:DD:EE:FF');
    expect(p.generation, isNull);
    // The heal that just ran must not have written the junk through either.
    expect((await LocalDb.deviceRow())?['adapter_id'], isNull);
  });

  // A FRESH database never runs the v51 rung that stamps the primary row
  // `'primary'`, so the insert has to name the role itself or the same row
  // means two different things depending on install history.
  test('a fresh install gives the primary row the primary role', () async {
    await LocalDb.upsertDevice(remoteId: 'AA:BB:CC:DD:EE:FF');
    await LocalDb.upsertDevice(id: 'oura-A1B2', remoteId: 'oura-A1B2');
    expect((await LocalDb.deviceRow())?['role'], 'primary');
    expect((await LocalDb.deviceRow('oura-A1B2'))?['role'], 'paired');
  });

  test('a notify-only adapter id is not a band generation', () async {
    await LocalDb.upsertDevice(
      adapterId: 'ble_hrs',
      remoteId: 'AA:BB:CC:DD:EE:FF',
      tier: 'wristOptical',
    );
    expect((await PairedDevice.load())!.generation, isNull);
  });

  // The heal call sites are `unawaited(PairedDevice.save(...))`, so a save can
  // be between its awaits when the user's forget lands. If it wins, the band
  // the user just forgot is paired again on the next launch.
  test('a forget beats a save that was already in flight', () async {
    await PairedDevice.save(
      'AA:BB:CC:DD:EE:FF',
      '5AG0000001',
      generation: 'gen5',
    );

    // Start the save, do not await it, and forget while it is mid-flight.
    final inFlight = PairedDevice.save(
      'AA:BB:CC:DD:EE:FF',
      '5AG0000002',
      generation: 'gen5',
    );
    await PairedDevice.clear();
    await inFlight;

    expect(
      await PairedDevice.load(),
      isNull,
      reason: 'the forget stands — neither copy may be written back',
    );
    expect((await LocalDb.deviceRow())?['remote_id'], isNull);
  });

  // ...and it keeps winning as the forget slides later into that flight.
  // `save()` writes the table, then the mirror keys one at a time. This walks
  // the forget across the save's awaits and requires BOTH copies gone at each
  // one — orphan serial and generation included, since a mirror key written
  // after the forget describes a band the record no longer names.
  //
  // A SWEEP, NOT A PROOF: the hops are event-loop turns, not a handshake with
  // a specific `await`. It pins the invariant broadly; the narrow guarantee it
  // cannot express — that the two writers never overlap at all — is the next
  // test's.
  test('a forget keeps winning as it slides later into an in-flight save',
      () async {
    for (var hops = 0; hops < 14; hops++) {
      SharedPreferences.setMockInitialValues({});
      await LocalDb.deleteDevice();
      await PairedDevice.save(
        'AA:BB:CC:DD:EE:FF',
        '5AG0000001',
        generation: 'gen5',
      );

      final inFlight = PairedDevice.save(
        'AA:BB:CC:DD:EE:FF',
        '5AG0000002',
        generation: 'gen5',
      );
      // Let the save advance `hops` turns of the event loop, then forget.
      for (var i = 0; i < hops; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await PairedDevice.clear();
      await inFlight;

      expect(
        await PairedDevice.load(),
        isNull,
        reason: 'the forget lost to a save $hops turns in',
      );
      expect(
        (await SharedPreferences.getInstance()).getKeys(),
        isEmpty,
        reason: 'a mirror key left behind describes a forgotten band, '
            '$hops turns in',
      );
    }
  });

  // THE GUARANTEE UNDERNEATH BOTH: `save()` and `clear()` are serialized, so
  // three overlapping calls land in CALL order rather than interleaving across
  // each other's awaits. Guarding the windows between those awaits cannot get
  // this right — "a forget happened" is not the same claim as "this mirror is
  // still mine to clean up", so a guard that refuses a stale write is also a
  // guard that can delete the pairing the user just made.
  //
  // A CONTRACT PIN, NOT A REGRESSION CATCHER, and worth saying plainly: under
  // the prefs/sqflite test doubles every write completes in issue order on its
  // own, so this stays green with the queue removed. That is the whole reason
  // the queue is the fix rather than another guard — the ordering these
  // assertions describe should be structural, not a property of how fast the
  // store happens to answer.
  test('overlapping save/clear/save land in call order', () async {
    await PairedDevice.save('AA:BB:CC:DD:EE:FF', 'OLD001', generation: 'gen5');

    // A fire-and-forget heal for the OLD band, the user's forget, and the
    // re-pair — all issued without awaiting the one before it.
    final heal =
        PairedDevice.save('AA:BB:CC:DD:EE:FF', 'OLD002', generation: 'gen5');
    final forget = PairedDevice.clear();
    final repair =
        PairedDevice.save('11:22:33:44:55:66', 'NEW001', generation: 'gen5');
    await Future.wait([heal, forget, repair]);

    final p = await PairedDevice.load();
    expect(p?.remoteId, '11:22:33:44:55:66', reason: 'the last call wins');
    expect(p?.serial, 'NEW001');
    // The mirror is the rebuild-recovery copy, so it has to name the new band
    // too — a stale op reaching back to clean up would cost exactly this.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('paired_remote_id'), '11:22:33:44:55:66');
    expect(prefs.getString('paired_serial'), 'NEW001');
    expect(prefs.getString('paired_generation'), 'gen5');
  });

  // `load()` reads like an accessor and is not: with no table row it heals one
  // back FROM the mirror. A forget landing inside that read-then-heal would
  // take the one database delete and leave the heal to upsert the forgotten
  // band afterwards — into the copy `load()` answers from first.
  test('a forget landing inside a heal-from-mirror load still sticks',
      () async {
    // The state the heal exists for: a rebuilt/wiped database under a band
    // that is still paired — mirror present, no table row.
    SharedPreferences.setMockInitialValues({
      'paired_remote_id': 'AA:BB:CC:DD:EE:FF',
      'paired_serial': '5AG0000001',
      'paired_generation': 'gen5',
    });
    await LocalDb.deleteDevice();

    final healing = PairedDevice.load();
    final forget = PairedDevice.clear();
    await Future.wait<void>([healing, forget]);

    expect(
      await PairedDevice.load(),
      isNull,
      reason: 'the heal must not put the forgotten band back',
    );
    expect((await LocalDb.deviceRow())?['remote_id'], isNull);
  });

  test('clear removes the whole record, generation included', () async {
    await PairedDevice.save(
      'AA:BB:CC:DD:EE:FF',
      '5AG0000001',
      generation: 'gen5',
    );
    await PairedDevice.clear();
    expect(await PairedDevice.load(), isNull);
    // Re-pairing after a clear starts with no generation at all.
    await PairedDevice.save('AA:BB:CC:DD:EE:FF', null);
    expect((await PairedDevice.load())!.generation, isNull);
  });

  test('junk serials still sanitize to null on load', () async {
    SharedPreferences.setMockInitialValues({
      'paired_remote_id': 'AA:BB:CC:DD:EE:FF',
      'paired_serial': '?*',
    });
    expect((await PairedDevice.load())!.serial, isNull);
  });
}
