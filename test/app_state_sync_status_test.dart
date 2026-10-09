// Sync area: the sync status AppState shows the UI (status
// string, busy, last-data timestamps, the deriving / pending flags) and how
// many times each transition notifies. Through AppState.
//
// `syncingNow` and the quiet timer behind it are fed only by the engine's
// onDataStored callback, which forTesting does not wire; they are covered with
// the real constructor in app_state_sync_commit_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'app_state_sync_status.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  group('a fresh app', () {
    test('shows nothing connected, nothing syncing, no data edge', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(app.status, 'disconnected');
      expect(app.isConnected, isFalse);
      expect(app.busy, isFalse);
      expect(app.syncingNow, isFalse);
      expect(app.deriving, isFalse);
      expect(app.derivePending, isFalse);
      expect(app.lastRecordAt, isNull);
      expect(app.lastDataAt, isNull);
      expect(app.lastSynced, isNull);
      expect(app.isPaired, isFalse);
      expect(app.initialized, isFalse);
    });
  });

  group('status follows the engine state', () {
    test('every state callback sets status and notifies exactly once',
        syncCase((rig, timers) async {
      final ticks = TickCounter(rig.app);
      for (final c in ['connecting', 'connected', 'disconnected']) {
        final before = ticks.ticks;
        rig.engine.state.connection = c;
        rig.app.debugFeedEngineState('', rig.engine.state);
        expect(rig.app.status, c);
        expect(ticks.ticks - before, 1, reason: c);
      }
      expect(rig.app.isConnected, isFalse);
      ticks.stop();
    }, paired: false));

    test('isConnected is the STATE string, not the engine\'s own flag',
        syncCase((rig, timers) async {
      rig.engine.link = true;
      expect(rig.app.isConnected, isFalse);
      rig.engine.state.connection = 'connected';
      expect(rig.app.isConnected, isTrue);
      rig.engine.link = false;
      expect(rig.app.isConnected, isTrue, reason: 'nobody reconciled the two');
    }, paired: false));

    test('lastDataAt is the engine\'s last-receive time',
        syncCase((rig, timers) async {
      expect(rig.app.lastDataAt, isNull);
      final at = DateTime.utc(2026, 1, 2, 3, 4, 5);
      rig.engine.rxAt = at;
      expect(rig.app.lastDataAt, at);
    }, paired: false));
  });

  group('busy', () {
    test('openSession raises it for the connect only', syncCase((rig, timers) async {
      final seen = <bool>[];
      rig.app.addListener(() => seen.add(rig.app.busy));
      await rig.app.openSession();
      expect(seen.first, isTrue);
      expect(rig.app.busy, isFalse);
      expect(seen.last, isFalse);
      await rig.waitFor(() => rig.engine.count('prompt') == 2);
    }));

    test('and it is lowered when the session start fails',
        syncCase((rig, timers) async {
      rig.engine.connectScript.add(StateError('boom'));
      await rig.app.openSession();
      expect(rig.app.busy, isFalse);
    }));
  });

  group('the data edge', () {
    test('a live reading never moves it (only stored records do)',
        syncCase((rig, timers) async {
      rig.engine.state.liveHr = 70;
      rig.engine.state.liveHrAt = 1750000000000;
      rig.engine.state.connection = 'connected';
      rig.app.debugFeedEngineState('', rig.engine.state);
      expect(rig.app.lastRecordAt, isNull);
    }, paired: false));
  });

  test('a DeviceState handed to the callback is the engine\'s own object', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    expect(identical(app.device, app.engine.state), isTrue);
    expect(app.device, isA<DeviceState>());
  });
}
