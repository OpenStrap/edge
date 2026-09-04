// M5's DB-backed integration gate (spec-m5.md §8.1/§8.2): a hand-built
// two-device night derives through the REAL pipeline (DerivationEngine.
// runDays -> _prepareTargetDay -> _derivePreparedDay -> LocalDb.putDayResult)
// and the resolved coverage spans written into the bundle are re-derived
// independently, via the same production calls the engine itself makes
// (LocalDb.coverageIntervals/signalPriority + resolveOwnership), and compared
// for exact equality — the "equality invariant" spec §8.2 assertion 2 names.
//
// Documentation-safe ids only (never a real device serial): '' is the
// primary band, 'ring-TEST-0001' a synthetic ring. All timestamps derive from
// fixed local `DateTime(...)` literals, never `DateTime.now()`.
//
// Assertion 4 (the charging-masks-wrong-device regression) is added in M5
// commit 5, once the per-owner masking call site lands — this file only
// carries assertions 2, 3(structural) and 5 for now.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart' show napBoundaryBufferSec;
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/coverage_resolver.dart';
import 'package:openstrap_edge/data/db.dart';

const _primary = LocalDb.kPrimaryDeviceId; // ''
const _ring = 'ring-TEST-0001';
const _dayId = '2025-09-02'; // fixed, not `now`

int _sec(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

// Region boundaries, fixed local wall-clock instants (spec §8.1).
final _primaryStart = _sec(2025, 9, 1, 22, 0); // prior day 22:00
final _primaryEnd = _sec(2025, 9, 2, 2, 0); // this day 02:00
final _ringStart = _sec(2025, 9, 2, 1, 30); // this day 01:30 (the handover)
final _ringEnd = _sec(2025, 9, 2, 7, 0); // this day 07:00
final _chargeOn = _sec(2025, 9, 2, 3, 0); // inside the RING-owned window
final _chargeOff = _sec(2025, 9, 2, 4, 0);

Future<void> _insertOneHzRun(
  Database db, {
  required String deviceId,
  required int fromSec,
  required int toSec,
  required int hr,
  int stepSec = 10, // coarser than 1 Hz — mechanical correctness only, not
  // staging quality; the resolver's own coverage grid is seeded separately
  // (device_coverage) and does not depend on this density.
}) async {
  final batch = db.batch();
  var counter = 0;
  for (var ts = fromSec; ts < toSec; ts += stepSec) {
    batch.insert('decoded_onehz', {
      'device_id': deviceId,
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': counter++,
      'hr': hr,
      'ax': 0.0,
      'ay': 0.0,
      'az': 1.0,
      'device_family': 'gen4',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);
}

Future<void> _seedCoverageAndPriority(Database db) async {
  Future<void> coverage(String deviceId, String signal, int from, int to) =>
      db.insert('device_coverage', {
        'device_id': deviceId,
        'signal': signal,
        'start_ts': from,
        'end_ts': to,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
  for (final sig in const ['hr1Hz', 'rrIntervals']) {
    await coverage(_primary, sig, _primaryStart, _primaryEnd);
    await coverage(_ring, sig, _ringStart, _ringEnd);
  }
  Future<void> priority(String signal, String deviceId, int rank) =>
      db.insert('signal_priority', {
        'signal': signal,
        'device_id': deviceId,
        'rank': rank,
        'user_set': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
  // The ring outranks the primary for both signals — the handover this
  // fixture exists to exercise.
  for (final sig in const ['hr1Hz', 'rrIntervals']) {
    await priority(sig, _ring, 0);
    await priority(sig, _primary, 1);
  }
}

Future<void> _seedCharging(Database db) async {
  await db.insert('band_events', {
    'device_id': _primary,
    'hex': 'chargeon',
    'event_id': proto.EventId.chargingOn,
    'name': proto.EventId.name(proto.EventId.chargingOn),
    'ts': _chargeOn,
    'captured_at': _chargeOn * 1000,
  });
  await db.insert('band_events', {
    'device_id': _primary,
    'hex': 'chargeoff',
    'event_id': proto.EventId.chargingOff,
    'name': proto.EventId.name(proto.EventId.chargingOff),
    'ts': _chargeOff,
    'captured_at': _chargeOff * 1000,
  });
}

/// Independently reconstructs the SAME union window + ownership resolution
/// `_prepareTargetDay` computes, using only public calls (the real
/// production code, not a re-implementation) — so comparing against it
/// proves the wiring, not agreement between two hand-written formulas.
Future<Map<InputSignal, List<OwnedSpan>>> _expectedOwnership() async {
  final range = DerivationEngine().debugTargetDayWindow(_dayId);
  final dayStart = _sec(2025, 9, 2, 0, 0);
  final dayEnd = _sec(2025, 9, 3, 0, 0);
  final onsetSec = _primaryStart; // the override forces this exact window
  final offsetSec = _ringEnd;
  final unionFrom = [dayStart, range.$1, onsetSec].reduce(math.min);
  final unionTo =
      [dayEnd - 1 + napBoundaryBufferSec, range.$2, offsetSec].reduce(math.max);
  final out = <InputSignal, List<OwnedSpan>>{};
  for (final sig in const [InputSignal.hr1Hz, InputSignal.rrIntervals]) {
    final raw = await LocalDb.signalPriority(sig);
    out[sig] = resolveOwnership(
      coverage: await LocalDb.coverageIntervals(sig, unionFrom, unionTo),
      priority: raw.isEmpty ? const [LocalDb.kPrimaryDeviceId] : raw,
      from: unionFrom,
      to: unionTo,
      signal: sig,
    );
  }
  return out;
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'multidevice_coverage_derive_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('two-device night: coverage spans in the bundle equal the resolver\'s '
      'own independent recomputation, and the charging event stays inside '
      'the ring-owned window (no mask)', () async {
    final db = await LocalDb.instance;
    await _insertOneHzRun(
      db,
      deviceId: _primary,
      fromSec: _primaryStart,
      toSec: _primaryEnd,
      hr: 60,
    );
    await _insertOneHzRun(
      db,
      deviceId: _ring,
      fromSec: _ringStart,
      toSec: _ringEnd,
      hr: 100,
    );
    await _seedCoverageAndPriority(db);
    await _seedCharging(db);
    // Force the sleep window rather than relying on auto-staging over
    // synthetic accel — this test's claim is about OWNERSHIP RESOLUTION,
    // not staging quality.
    await LocalDb.putSleepOverride(
      dayId: _dayId,
      onsetTs: _primaryStart,
      offsetTs: _ringEnd,
      source: 'manual',
    );

    final done =
        await DerivationEngine().runDays(const Profile(), {_dayId}, force: true);
    expect(done, 1, reason: 'the day must actually derive, not be skipped');

    final row = await LocalDb.dayResult(_dayId);
    expect(row, isNotNull);
    final bundle = jsonDecode(row!['payload_json'] as String) as Map;

    // ── assertion 2: the equality invariant ──────────────────────────────
    final expected = await _expectedOwnership();
    final series = (bundle['series'] as Map).cast<String, dynamic>();
    expect(series.containsKey('coverage'), isTrue,
        reason: 'two real contributors this day — the key must be present');
    final coverage = (series['coverage'] as Map).cast<String, dynamic>();
    final inBundleHr1Hz = coverageFromJson(coverage['hr1Hz']);
    expect(inBundleHr1Hz, expected[InputSignal.hr1Hz],
        reason: 'records compare by value — this is the exact span list '
            '_prepareTargetDay resolved, not an approximation of it');
    final inBundleRr = coverageFromJson(coverage['rrIntervals']);
    expect(inBundleRr, expected[InputSignal.rrIntervals]);

    // ── assertion 3 (structural): the handover landed on the ring, and the
    // primary is not still claiming seconds only the ring covered ─────────
    expect(inBundleHr1Hz.length, greaterThan(1),
        reason: 'a real handover produces more than the identity single span');
    final atHandoverPlusHysteresis =
        spanAt(inBundleHr1Hz, _ringStart + 3 * kOwnershipBucketSeconds);
    expect(atHandoverPlusHysteresis?.deviceId, _ring,
        reason: 'three buckets after the ring first covers a bucket, it '
            'must own the span (hysteresis has resolved by then)');

    // ── assertion 4: the charging event belonging to the NON-OWNING device
    // (the primary) changed nothing. Re-derive with the primary's
    // chargingOn/chargingOff rows deleted; assert an identical payload.
    // This is the §5.1(b) regression — it is invisible in the span set
    // alone, which is why it needs a second real derive to catch. ────────
    final atCharge = spanAt(inBundleHr1Hz, _chargeOn);
    expect(atCharge?.deviceId, _ring,
        reason: 'the charging event this fixture seeds sits in a window the '
            'ring owns — the primary\'s charging must not be able to mask it');

    await db.delete('band_events',
        where: 'device_id = ? AND event_id IN (?, ?)',
        whereArgs: [_primary, proto.EventId.chargingOn, proto.EventId.chargingOff]);
    final done2 =
        await DerivationEngine().runDays(const Profile(), {_dayId}, force: true);
    expect(done2, 1);
    final row2 = await LocalDb.dayResult(_dayId);
    expect(row2!['payload_json'], row['payload_json'],
        reason: 'the primary\'s charging event sat inside a window the ring '
            'owned, so removing it must not change the derived payload at '
            'all — a day whose only charging event belongs to the '
            'non-owning device must stage identically to a day with no '
            'charging event at all');

    // ── decoded_onehz still holds BOTH devices' original rows — filtering
    // happens at substrate-load time only, never by deleting data. ────────
    final counts = await db.rawQuery(
      'SELECT device_id, COUNT(*) AS n FROM decoded_onehz GROUP BY device_id',
    );
    final byDevice = {for (final r in counts) r['device_id'] as String: r['n'] as int};
    expect(byDevice[_primary], greaterThan(0));
    expect(byDevice[_ring], greaterThan(0));
  });

  test('single device: no coverage key at all (the identity case)', () async {
    await LocalDb.close();
    LocalDb.dbName = 'multidevice_coverage_derive_single_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    final db = await LocalDb.instance;

    const dayId = '2025-09-05';
    final start = _sec(2025, 9, 4, 22, 0);
    final end = _sec(2025, 9, 5, 6, 0);
    await _insertOneHzRun(db, deviceId: _primary, fromSec: start, toSec: end, hr: 58);
    // device_coverage for the primary ONLY — no second device, no
    // signal_priority row (matches every real single-device install today).
    for (final sig in const ['hr1Hz', 'rrIntervals']) {
      await db.insert('device_coverage', {
        'device_id': _primary,
        'signal': sig,
        'start_ts': start,
        'end_ts': end,
      });
    }
    await LocalDb.putSleepOverride(
      dayId: dayId,
      onsetTs: start,
      offsetTs: end,
      source: 'manual',
    );

    final done = await DerivationEngine()
        .runDays(const Profile(), {dayId}, force: true);
    expect(done, 1);

    final row = await LocalDb.dayResult(dayId);
    expect(row, isNotNull);
    final bundle = jsonDecode(row!['payload_json'] as String) as Map;
    final series = (bundle['series'] as Map).cast<String, dynamic>();
    expect(series.containsKey('coverage'), isFalse,
        reason: 'one contributor this day — the key is OMITTED, not `{}`');

    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    LocalDb.dbName = 'multidevice_coverage_derive_test.db';
    await LocalDb.instance;
  });
}
