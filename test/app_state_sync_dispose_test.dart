// Sync area: what AppState.dispose does to the timers, the foreground
// claim and the live session, and what calls that arrive
// AFTER it still do. Through AppState with a [SyncFakeEngine].
//
// Dispose only guards the notification funnel and cancels the timers it owns;
// work already in flight, and a connection edge that arrives afterwards, still
// run their course on the disposed object. That is pinned as it is, not as it
// should be.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ios_ble_restore.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'app_state_sync_dispose.db';

Future<void> _open(SyncRig rig) => rig.openAndSettle();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  group('timers', () {
    test('dispose cancels the supervisor and the backfill timer',
        syncCase((rig, timers) async {
      await _open(rig);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      rig.app.dispose();
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      await rig.quiesce();
    }, dispose: false));

    test('debugArmOwnedTimers arms the backfill timer and dispose cancels it',
        syncCase((rig, timers) async {
      rig.app.debugArmOwnedTimers();
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      expect(timers.activeOneShot(const Duration(minutes: 5)), hasLength(1),
          reason: 'the alarm grace timer (alarm-owned, not sync)');
      rig.app.dispose();
      expect(timers.activePeriodic(kBackfillEvery), isEmpty);
      expect(timers.activeOneShot(const Duration(minutes: 5)), isEmpty);
    }, dispose: false));

    test('with nothing open it arms nothing and leaves nothing',
        syncCase((rig, timers) async {
      rig.app.dispose();
      expect(timers.live.where((t) => t.periodic), isEmpty);
    }, dispose: false));
  });

  group('what dispose leaves alone', () {
    test('the foreground claim is released, the link is not disconnected and '
        'the iOS restore flag is not touched', syncCase((rig, timers) async {
      await _open(rig);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      rig.engine.events.clear();
      rig.app.dispose();
      expect(BandOwnership.owner, isNull);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(rig.engine.count('disconnect'), 0);
      expect(rig.engine.isConnected, isTrue);
      expect(IosBleRestore.foregroundActive, isTrue);
      await rig.quiesce();
    }, dispose: false));

    test('dispose twice: the only failure is ChangeNotifier\'s own "disposed '
        'more than once" FlutterError', syncCase((rig, timers) async {
      rig.app.dispose();
      Object? thrown;
      try {
        rig.app.dispose();
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<FlutterError>());
    }, dispose: false));
  });

  group('calls that arrive after dispose', () {
    test('a drain finishing after dispose still re-reads the band prompt and '
        'queues the heavy derive, without throwing',
        syncCase((rig, timers) async {
      rig.engine.syncGate = Completer<void>();
      await rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      rig.app.dispose();
      rig.engine.events.clear();
      rig.engine.syncGate!.complete();
      await rig.waitFor(() => rig.engine.count('prompt') == 1);
      await rig.jobQueued('derive_heavy');
    }, dispose: false));

    test('an openSession parked in connect at dispose carries on when the '
        'connect answers: poll, prompt, drain and a fresh backfill timer, '
        'though the supervisor stays cancelled and no intent or lease is left',
        syncCase((rig, timers) async {
      final gate = rig.holdConnect();
      final open = rig.app.openSession();
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      rig.app.dispose();
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
      gate.complete();
      await open;
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      expect(rig.engine.count('getBattery'), 1);
      expect(rig.engine.count('reconcile'), 1);
      expect(rig.engine.count('disconnect'), 0);
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
      expect(timers.activePeriodic(kBackfillEvery), hasLength(1));
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(rig.app.busy, isFalse);
      await rig.quiesce();
    }, dispose: false));

    test('a link drop reported after dispose still starts a reconnect, which '
        'takes the foreground lease and intent again',
        syncCase((rig, timers) async {
      await _open(rig);
      rig.app.dispose();
      expect(BandOwnership.owner, isNull);
      rig.engine.events.clear();
      rig.engine.drop();
      await rig.waitFor(() => rig.engine.count('runSync') == 1);
      expect(rig.engine.count('markReconnecting'), 1);
      expect(rig.engine.count('connect'), 1);
      expect(BandOwnership.owner, BandOwnerKind.foreground);
      expect(BandOwnership.foregroundIntent, isTrue);
      await rig.quiesce();
    }, dispose: false));
  });
}
