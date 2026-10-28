// "Delete everything" must not be repopulated by the band it is deleting.
//
// `resetAllData()` wipes the database but leaves the strap CONNECTED — its own
// documented order puts `signOut` (and the `unpair` inside it) LAST, because
// that flips the route and unwinds the UI. So the band keeps handing over
// historical records straight across the wipe, and one that lands after it is
// written into the fresh database and re-advertised as the data edge: the
// deleted installation, visible again on Home, with nothing left to explain it.
//
// `AppState._resetting` is the refusal flag that closes that window. It is
// private, and `resetAllData` needs the whole plugin stack (preferences,
// notifications, widget, telemetry, keychain) to run at all, so there is no
// behavioural test to write here. This greps instead — the same approach, and
// for the same reason, as `link_priority_structural_test.dart` and
// `no_debug_only_apis_test.dart`: the failure mode is a NEW ingest path added
// later that simply forgets the guard, which no test that runs the code can
// see.
//
// What is pinned:
//   1. every record-ingest callback AppState hands the engine checks
//      `_resetting` before it writes
//   2. `resetAllData` raises the flag, and lowers it in a `finally` (a
//      half-reset install that silently drops every record is worse than the
//      race it was closing)
//   3. `LocalDb.insertRecordsBatch` is not passed as a bare tear-off anywhere
//      in AppState — that is exactly how the drain path bypassed the guard

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';

void main() {
  final src = File('lib/state/app_state.dart').readAsStringSync();
  final bg = File('lib/sync/background_sync.dart').readAsStringSync();

  test('both ingest callbacks refuse while a reset is in flight', () {
    // The singles path.
    final onRecord = RegExp(
      r'Future<void> _onRecord\([^)]*\) async \{\s*\n\s*if \(_resetting\) return;',
    );
    expect(onRecord.hasMatch(src), isTrue,
        reason: '_onRecord must refuse before it writes');

    // The drain path, which is wired straight to LocalDb and so bypasses every
    // check AppState makes unless the closure carries one itself.
    final batch = RegExp(
      r'onRecordsBatch: \([^)]*\) async \{\s*\n\s*if \(_resetting\) return;',
    );
    expect(batch.hasMatch(src), isTrue,
        reason: 'onRecordsBatch must refuse before it writes');
  });

  test('_onLiveEvent refuses while a reset is in flight', () {
    // The live/foreground event path — wristOn/wristOff, battery, alarm
    // fired, etc. It is wired straight to LocalDb.insertEvent just like
    // onRecordsBatch/onArchiveRecord above, and was missing this guard: an
    // event notification landing after ResetGate.enter() but before the
    // band disconnects would resurrect deleted data.
    final onLiveEvent = RegExp(
      r'void _onLiveEvent\([^)]*\) \{\s*\n\s*if \(_resetting\) return;',
    );
    expect(onLiveEvent.hasMatch(src), isTrue,
        reason: '_onLiveEvent must refuse before it writes');
  });

  test('_onEngineState refuses while a reset is in flight', () {
    // The device-state path — battery %, charging, wrist-on, generation —
    // wired straight to LocalDb.upsertDevice/insertBandBatterySample just
    // like _onLiveEvent above, and was missing this guard: a DeviceState
    // notification landing after ResetGate.enter() but before the band
    // disconnects would resurrect a deleted device/band_battery row.
    final onEngineState = RegExp(
      r'void _onEngineState\([^)]*\) \{\s*\n\s*if \(_resetting\) return;',
    );
    expect(onEngineState.hasMatch(src), isTrue,
        reason: '_onEngineState must refuse before it writes');
  });

  test('insertRecordsBatch is never handed over as a bare tear-off', () {
    // `onRecordsBatch: LocalDb.insertRecordsBatch` is the shape of the bug:
    // it hands the database straight to the engine with nothing in between.
    expect(
      src.contains('onRecordsBatch: LocalDb.insertRecordsBatch'),
      isFalse,
      reason: 'wrap it in a closure that checks _resetting',
    );
  });

  test('resetAllData raises the flag and always lowers it', () {
    final body = src.substring(src.indexOf('Future<String?> resetAllData() async'));
    final raise = body.indexOf('ResetGate.enter();');
    final wipe = body.indexOf('DerivationEngine.whileIdle(LocalDb.wipeAll)');
    final lower = body.indexOf('ResetGate.leave();');
    final fin = body.indexOf('} finally {');

    expect(raise, greaterThanOrEqualTo(0), reason: 'the flag must be raised');
    expect(raise, lessThan(wipe),
        reason: 'raised BEFORE the wipe, or the window it closes is still open');
    expect(fin, greaterThanOrEqualTo(0), reason: 'lowering must be in a finally');
    expect(fin, lessThan(lower), reason: 'lowered inside that finally');
  });

  test('the reset replaces the primary band host, inside the finally', () {
    // The host captures ResetGate.generation when built and refuses every
    // commit once a reset has run since. Kept across a reset, it refused every
    // batch for the rest of the process: no ACK, and a band paired again never
    // synced until a restart.
    expect(src.contains('late final BandHost _bandHost;'), isFalse);
    final body = src.substring(src.indexOf('Future<String?> resetAllData() async'));
    final fin = body.indexOf('} finally {');
    final rebuild = body.indexOf('_bandHost = _newPrimaryBandHost();');
    final lower = body.indexOf('ResetGate.leave();');
    expect(rebuild, greaterThan(fin), reason: 'even when the reset throws');
    expect(rebuild, lessThan(lower),
        reason: 'built while the gate is still up, so it reads the new '
            'generation and refuses until the gate lowers');
  });

  test('the data edge is cleared by the reset, not left in memory', () {
    final body = src.substring(src.indexOf('Future<String?> resetAllData() async'));
    final end = body.indexOf('} finally {');
    final scope = body.substring(0, end);
    expect(scope.contains('_lastRecTs = null;'), isTrue);
    expect(scope.contains('lastSynced = null;'), isTrue);
  });

  // ── the secondary sensors ─────────────────────────────────────────────────
  //
  // signOut's unpair reaches only the primary band. An armed chest strap or an
  // Oura offload kept committing across the wipe, and the ring's and Mi Band's
  // pairing keys stayed in the keychain with no device row left to find them.

  test('resetAllData stops the secondary sensors before the wipe', () {
    final body = src.substring(src.indexOf('Future<String?> resetAllData() async'));
    final stop = body.indexOf('await _stopSecondaryLinksForReset();');
    final ids = body.indexOf('await _secondaryDeviceIdsForReset();');
    final wipe = body.indexOf('DerivationEngine.whileIdle(LocalDb.wipeAll)');
    expect(stop, greaterThanOrEqualTo(0));
    expect(stop, lessThan(wipe));
    expect(ids, greaterThanOrEqualTo(0));
    expect(ids, lessThan(wipe),
        reason: 'the wipe deletes the device rows the key ids come from');

    final helper = src.substring(
        src.indexOf('Future<void> _stopSecondaryLinksForReset() async'));
    final helperBody = helper.substring(0, helper.indexOf('\n  }\n'));
    for (final call in [
      '_workoutController.discardForReset',
      'OuraLink.instance.stop',
      'UltrahumanLink.instance.stop',
      'ColmiLink.instance.stop',
      'GarminLink.instance.stop',
      'MiBand234Link.instance.stop',
      'PebbleLink.instance.stop',
      'CorosLink.instance.stop',
      'SessionLink.all',
    ]) {
      expect(helperBody.contains(call), isTrue, reason: '$call not stopped');
    }
  });

  test('resetAllData drops the sensor pairing keys', () {
    final body = src.substring(src.indexOf('Future<String?> resetAllData() async'));
    final scope = body.substring(0, body.indexOf('} finally {'));
    expect(scope.contains('OuraLink.dropStoredKey(id)'), isTrue);
    expect(scope.contains('MiBand234Link.dropStoredKey(id)'), isTrue);
  });

  test('BandHost refuses every database write during a reset', () {
    final host = File('lib/ble/adapters/host.dart').readAsStringSync();
    for (final write in [
      'LocalDb.commitSyncBatch(',
      'LocalDb.putObservations(',
      'LocalDb.putVendorSleepEpochs(',
    ]) {
      var at = host.indexOf(write);
      expect(at, greaterThanOrEqualTo(0), reason: '$write not found');
      while (at >= 0) {
        // The refusal sits inside the same try, just above the write.
        final tryAt = host.lastIndexOf('try {', at);
        final window = host.substring(tryAt, at);
        expect(window.contains('_refuseDuringReset();'), isTrue,
            reason: '$write at offset $at is not gated');
        at = host.indexOf(write, at + write.length);
      }
    }
  });

  test('the headless piggyback does not sync secondaries during a reset', () {
    final run = bg.substring(bg.indexOf('Future<bool> runHeadlessSync('));
    final fin = run.substring(run.indexOf('} finally {'));
    expect(fin.contains('if (!ResetGate.active) await _syncPairedSensors();'),
        isTrue);
    expect(fin.substring(0, fin.indexOf('\n}\n')).contains('.instance.sync()'),
        isFalse, reason: 'every secondary sync goes through the gated helper');
  });

  // ── the OTHER engine ──────────────────────────────────────────────────────
  //
  // `runHeadlessSync` builds its own BleEngine with callbacks wired straight to
  // LocalDb and no AppState in scope, so nothing AppState guards reaches it.
  // Same isolate (see reset_gate.dart), so one static covers both.

  test('the headless drain refuses to start while a reset is running', () {
    // Sliced to runHeadlessSync: the shared engine factory above it has its
    // own ResetGate checks, which must not stand in for this one.
    final run = bg.substring(bg.indexOf('Future<bool> runHeadlessSync('));
    expect(run.contains('if (ResetGate.active) {'), isTrue,
        reason: 'runHeadlessSync must bail before it drains');
    // Ahead of PairedDevice.load(), which is the only thing standing between a
    // reset and a fresh drain today — and only by accident, via prefs.clear().
    // The real CALL, not the mention of it in the comment above the guard.
    expect(run.indexOf('ResetGate.active'),
        lessThan(run.indexOf('final paired = await PairedDevice.load();')));
  });

  test('every headless write path is gated', () {
    for (final cb in ['onRecord:', 'onEvent:', 'onRecordsBatch:',
                      'onArchiveRecord:', 'onCommitBatch:']) {
      final at = bg.indexOf(cb);
      expect(at, greaterThanOrEqualTo(0), reason: '$cb not found');
      // Slice to the NEXT callback at the same indent, so a guard belonging to
      // a neighbour can never be mistaken for this one's.
      final next = bg.indexOf('\n    on', at + cb.length);
      final window = bg.substring(at, next < 0 ? bg.length : next);
      expect(window.contains('ResetGate.active'), isTrue,
          reason: '$cb writes without consulting ResetGate');
    }
  });

  test('no write sink is handed over as a bare LocalDb tear-off', () {
    // This shape — the database passed straight to the engine with nothing in
    // between — is exactly how the guard was bypassed.
    for (final bare in [
      'onRecord: (sample, raw) => LocalDb.insertRecord',
      'onRecordsBatch: LocalDb.insertRecordsBatch',
      'onArchiveRecord: LocalDb.archiveRawRecord',
    ]) {
      expect(bg.contains(bare), isFalse, reason: 'bare tear-off: $bare');
      expect(src.contains(bare), isFalse, reason: 'bare tear-off: $bare');
    }
  });

  test('the ACK-bearing commit THROWS rather than silently succeeding', () {
    // Only `onCommit` can bank raws + archives + trim cursor in one
    // transaction, and DrainController reads durability from a throw. A quiet
    // return would ACK and let the band trim flash that was never stored —
    // a race turned into real data loss.
    for (final f in [src, bg]) {
      final at = f.indexOf('onCommitBatch:');
      final window = f.substring(at, at + 900);
      expect(window.contains('ResetGate.active'), isTrue);
      expect(window.contains('throw StateError'), isTrue,
          reason: 'the commit gate must throw, not return');
    }
  });

  test('the gate opens on enter and shuts on leave', () {
    addTearDown(ResetGate.resetForTest);
    expect(ResetGate.active, isFalse);
    ResetGate.enter();
    expect(ResetGate.active, isTrue);
    ResetGate.leave();
    expect(ResetGate.active, isFalse);
  });

  test('a second reset on top of the first does not reopen the window', () {
    // `resetAllData()` is awaited but does not block the UI, so a user can
    // confirm a second wipe while the first is still running. A bare bool let
    // the first to finish lower the flag mid-wipe.
    addTearDown(ResetGate.resetForTest);
    ResetGate.enter();
    ResetGate.enter();
    ResetGate.leave();
    expect(ResetGate.active, isTrue,
        reason: 'the second reset is still wiping');
    ResetGate.leave();
    expect(ResetGate.active, isFalse);
  });

  test('every reset moves the generation, so a session that started before '
      'one can tell after the gate lowers', () {
    addTearDown(ResetGate.resetForTest);
    final before = ResetGate.generation;
    expect(ResetGate.changedSince(before), isFalse);
    ResetGate.enter();
    expect(ResetGate.changedSince(before), isTrue);
    ResetGate.leave();
    expect(ResetGate.active, isFalse);
    expect(ResetGate.changedSince(before), isTrue,
        reason: 'the reset ran after this session read the generation');
    expect(ResetGate.changedSince(ResetGate.generation), isFalse);
  });

  test('a queued Oura sync re-checks the device and the reset once it gets '
      'the slot', () {
    final oura = File('lib/ble/oura_link.dart').readAsStringSync();
    final slot = oura.indexOf('return await withSecondaryLinkSlot(() async {');
    expect(slot, greaterThanOrEqualTo(0));
    final head = oura.substring(slot, slot + 600);
    expect(
        head.contains(
            'if (_deviceId != deviceId || ResetGate.changedSince(_resetGen))'),
        isTrue,
        reason: 'the first thing the slot callback does');
  });

  test('the wipe runs on the sync-commit gate', () {
    final db = File('lib/data/db.dart').readAsStringSync();
    expect(db.contains('static Future<int> wipeAll() => '
        '_withCommitGate(_wipeAllLocked);'), isTrue);
  });

  test('an unbalanced leave cannot drive the gate below shut', () {
    // A count below zero would make the NEXT reset's enter() fail to open the
    // gate — the failure mode that loses data.
    addTearDown(ResetGate.resetForTest);
    ResetGate.leave();
    ResetGate.leave();
    ResetGate.enter();
    expect(ResetGate.active, isTrue);
  });
}
