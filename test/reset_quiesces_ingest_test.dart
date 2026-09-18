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
    final body = src.substring(src.indexOf('Future<void> resetAllData() async'));
    final raise = body.indexOf('ResetGate.enter();');
    final wipe = body.indexOf('LocalDb.wipeAll()');
    final lower = body.indexOf('ResetGate.leave();');
    final fin = body.indexOf('} finally {');

    expect(raise, greaterThanOrEqualTo(0), reason: 'the flag must be raised');
    expect(raise, lessThan(wipe),
        reason: 'raised BEFORE the wipe, or the window it closes is still open');
    expect(fin, greaterThanOrEqualTo(0), reason: 'lowering must be in a finally');
    expect(fin, lessThan(lower), reason: 'lowered inside that finally');
  });

  test('the data edge is cleared by the reset, not left in memory', () {
    final body = src.substring(src.indexOf('Future<void> resetAllData() async'));
    final end = body.indexOf('} finally {');
    final scope = body.substring(0, end);
    expect(scope.contains('_lastRecTs = null;'), isTrue);
    expect(scope.contains('lastSynced = null;'), isTrue);
  });

  // ── the OTHER engine ──────────────────────────────────────────────────────
  //
  // `runHeadlessSync` builds its own BleEngine with callbacks wired straight to
  // LocalDb and no AppState in scope, so nothing AppState guards reaches it.
  // Same isolate (see reset_gate.dart), so one static covers both.

  test('the headless drain refuses to start while a reset is running', () {
    expect(bg.contains('if (ResetGate.active) {'), isTrue,
        reason: 'runHeadlessSync must bail before it drains');
    // Ahead of PairedDevice.load(), which is the only thing standing between a
    // reset and a fresh drain today — and only by accident, via prefs.clear().
    // The real CALL, not the mention of it in the comment above the guard.
    expect(bg.indexOf('ResetGate.active'),
        lessThan(bg.indexOf('final paired = await PairedDevice.load();')));
  });

  test('every headless write path is gated', () {
    for (final cb in ['onRecord:', 'onEvent:', 'onRecordsBatch:',
                      'onArchiveRecord:', 'onCommitBatch:']) {
      final at = bg.indexOf(cb);
      expect(at, greaterThanOrEqualTo(0), reason: '$cb not found');
      // Slice to the NEXT callback at the same indent, so a guard belonging to
      // a neighbour can never be mistaken for this one's.
      final next = bg.indexOf('\n      on', at + cb.length);
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
