// Sync area wiring that only the real AppState constructor sets up: the
// engine's commit callback (the ACK gate) as the Shortcut sees it, the
// stored-data callback behind `syncingNow` and the data edge, and the static
// hooks the iOS entry points call back into. forTesting wires none of these.
//
// The real constructor is safe here with no band paired: start-up finds
// nothing to open and the plugin calls it makes fail harmlessly.

import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/ios_bg_task.dart';
import 'package:openstrap_edge/sync/ios_shortcut_sync.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:openstrap_edge/sync/shortcut_sync_task.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'app_state_sync_commit.db';

base class _AdapterOn extends FlutterBluePlusPlatform {
  @override
  Future<BmBluetoothAdapterState> getAdapterState(
    BmBluetoothAdapterStateRequest request,
  ) async => BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on);
}

RawRecord _raw(int ts) =>
    RawRecord(counter: 1, hex: '00', capturedAt: 1750000000000, recTs: ts);

/// A real AppState, once its start-up has settled so nothing is mid-flight
/// when the test ends.
Future<AppState> _realApp() async {
  final app = AppState();
  await until(() => app.initialized || app.initError != null,
      what: 'start-up settled');
  // The unawaited tail of start-up (gesture bootstrap, status loads) must land
  // before a dispose, or its notify hits a disposed notifier.
  await settleMs(500);
  return app;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await deriveDbSetUp(_db);
    FlutterBluePlusPlatform.instance = _AdapterOn();
  });
  tearDown(() async {
    ResetGate.resetForTest();
    IosShortcutSync.foregroundSync = null;
    IosShortcutSync.foregroundEngine = null;
    await deriveDbTearDown(_db);
  });

  group('the commit callback, seen through a running Shortcut', () {
    // IosShortcutSync.run registers the callbacks the engine's commit reports
    // into, then calls the foreground sync; the stand-in below commits through
    // the real engine callback instead of draining a band.
    Future<ShortcutSyncResult> runWith(
      AppState app,
      Future<SyncReport> Function(ShortcutSyncTask task) body,
    ) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      IosShortcutSync.foregroundEngine = () => app.engine;
      IosShortcutSync.foregroundSync = body;
      return IosShortcutSync.run('commit', const Duration(seconds: 10));
    }

    test('a durable commit is reported to the Shortcut only after it landed',
        () async {
      final app = await _realApp();
      addTearDown(app.dispose);
      final db = await LocalDb.instance;
      final held = Completer<void>();
      final inside = Completer<void>();
      late Future<void> holding;
      late ShortcutSyncTask seen;
      var recordsWhileHeld = -1;
      final r = await runWith(app, (task) async {
        seen = task;
        // Hold the database's write lock so the commit has to wait for it.
        holding = db.transaction((txn) async {
          inside.complete();
          await held.future;
        });
        await inside.future;
        final commit = app.engine.onCommitBatch!(
            [_raw(1750000100)], [null], '0011223344556677');
        await settleMs(200);
        recordsWhileHeld = task.records;
        held.complete();
        await commit;
        return SyncReport(1, 1, true);
      });
      await holding;
      expect(recordsWhileHeld, 0, reason: 'nothing reported while the commit waits');
      expect(seen.records, 1);
      expect(r.records, 1);
      expect(await LocalDb.getCursorInt('rec_ts_hw'), 1750000100);
    });

    test('a refused commit is reported as a failure, then rethrown, and '
        'banks nothing', () async {
      final app = await _realApp();
      addTearDown(app.dispose);
      late ShortcutSyncTask seen;
      Object? thrown;
      var ran = false;
      final bodyDone = Completer<void>();
      final r = await runWith(app, (task) async {
        ran = true;
        seen = task;
        ResetGate.enter();
        try {
          await app.engine.onCommitBatch!(
              [_raw(1750000100)], [null], '0011223344556677');
        } catch (e) {
          thrown = e;
        } finally {
          ResetGate.leave();
          bodyDone.complete();
        }
        return SyncReport(0, 0, false);
      });
      // The failure report stops the Shortcut before the rethrow reaches the
      // caller, so the run can return first.
      await bodyDone.future;
      expect(ran, isTrue);
      expect(thrown, isA<StateError>());
      expect(seen.stopped, isTrue);
      expect(r.status, 'failed');
      expect(r.records, 0);
      expect(await LocalDb.getCursorInt('rec_ts_hw'), isNull);
    });
  });

  group('the stored-data callback', () {
    test('lights syncingNow at once, arms one quiet timer that notifies when '
        'the window closes, and refreshes the data edge from the cursor',
        () async {
      final timers = SyncTimers();
      await timers.run(() async {
        final app = await _realApp();
        addTearDown(app.dispose);
        await LocalDb.setCursor('rec_ts_hw', '1750000300');
        expect(app.syncingNow, isFalse);
        expect(app.lastRecordAt, isNull);
        final before = timers.activeOneShot(const Duration(seconds: 6)).length;
        final ticks = TickCounter(app);
        app.engine.onDataStored!();
        // Synchronously, before the cursor read lands.
        expect(app.syncingNow, isTrue);
        expect(app.lastRecordAt, isNull);
        final quiet = timers.activeOneShot(const Duration(seconds: 6));
        expect(quiet.length, before + 1);
        await until(() => app.lastRecordAt != null, what: 'data edge read');
        expect(app.lastRecordAt,
            DateTime.fromMillisecondsSinceEpoch(1750000300 * 1000));
        final afterEdge = ticks.ticks;
        // A second batch inside the window re-arms: the first timer is gone.
        app.engine.onDataStored!();
        expect(quiet.last.cancelled, isTrue);
        final latest = timers.activeOneShot(const Duration(seconds: 6)).last;
        await settleMs(50);
        final atFire = ticks.ticks;
        latest.fire();
        expect(ticks.ticks, atFire + 1, reason: 'the window closing notifies');
        expect(afterEdge, greaterThanOrEqualTo(1));
        ticks.stop();
      });
    });

    test('a cursor older than the edge does not move it back', () async {
      final app = await _realApp();
      addTearDown(app.dispose);
      await LocalDb.setCursor('rec_ts_hw', '1750000300');
      app.engine.onDataStored!();
      await until(() => app.lastRecordAt != null);
      await LocalDb.setCursor('rec_ts_hw', '1750000100');
      app.engine.onDataStored!();
      await settleMs(100);
      expect(app.lastRecordAt,
          DateTime.fromMillisecondsSinceEpoch(1750000300 * 1000));
    });
  });

  group('the static hooks the iOS entry points use', () {
    test('the BGTask pull and the Shortcut sync are this app\'s tear-offs',
        () async {
      final app = await _realApp();
      addTearDown(app.dispose);
      expect(IosBgTask.foregroundPull, app.foregroundCatchUp);
      expect(IosShortcutSync.foregroundSync, app.syncForShortcut);
      expect(IosShortcutSync.foregroundEngine!(), same(app.engine));
    });

    test('disposing an app detaches only its own Shortcut registration',
        () async {
      final first = await _realApp();
      final second = await _realApp();
      expect(IosShortcutSync.foregroundSync, second.syncForShortcut);
      first.dispose();
      expect(IosShortcutSync.foregroundSync, second.syncForShortcut,
          reason: 'the first app is not the registered one');
      expect(IosShortcutSync.foregroundEngine!(), same(second.engine));
      second.dispose();
      expect(IosShortcutSync.foregroundSync, isNull);
      expect(IosShortcutSync.foregroundEngine, isNull);
    });
  });
}
