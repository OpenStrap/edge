// Sync area: the public AppState members the screens, the iOS entry points and
// the other AppState areas call are all still there with the same shape, and
// the writable fields tests and lifecycle code poke are still writable. A
// tear-off of each member type-checks its signature.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/models.dart' show DeviceState;
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/shortcut_sync_task.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'app_state_sync_facade.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  test('every public member of the area keeps its shape', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final Future<void> Function({bool foreground}) openSession = app.openSession;
    final Future<SyncReport> Function(ShortcutSyncTask) shortcut =
        app.syncForShortcut;
    final Future<void> Function() endSession = app.endSession;
    final Future<void> Function() pause = app.pauseForBackground;
    final Future<void> Function() unpair = app.unpair;
    final Future<void> Function() forceResync = app.forceResync;
    final Future<void> Function() catchUp = app.foregroundCatchUp;
    final Future<void> Function() syncNow = app.syncNow;
    final Future<bool> Function() bluetoothReady = app.bluetoothReady;
    final Future<void> Function() init = app.debugInit;
    final void Function(String, DeviceState) feed = app.debugFeedEngineState;
    for (final f in [openSession, shortcut, endSession, pause, unpair,
        forceResync, catchUp, syncNow, bluetoothReady, init, feed]) {
      expect(f, isNotNull);
    }
    final String status = app.status;
    final bool connected = app.isConnected;
    final bool busy = app.busy;
    final bool syncing = app.syncingNow;
    final bool deriving = app.deriving;
    final bool pending = app.derivePending;
    final DateTime? edge = app.lastRecordAt;
    final DateTime? rx = app.lastDataAt;
    final bool paired = app.isPaired;
    final BleEngine engine = app.engine;
    final String? initError = app.initError;
    final bool initialized = app.initialized;
    expect([status, connected, busy, syncing, deriving, pending, edge, rx,
        paired, engine, initError, initialized], hasLength(12));
    app.busy = false;
    app.paired = null;
    app.initialized = false;
    expect(app.logLines, isA<List<String>>());
  });

  test('the engine is one object for the life of the app and AppState reads '
      'the connection from its state', syncCase((rig, timers) async {
    final engine = rig.app.engine;
    rig.engine.state.connection = 'connected';
    expect(rig.app.status, 'connected');
    expect(rig.app.isConnected, isTrue);
    expect(identical(rig.app.engine, engine), isTrue);
    expect(identical(rig.app.device, rig.engine.state), isTrue);
  }, paired: false));

  test('busy is a plain writable flag: a held flag is respected and cleared '
      'by the writer, not by openSession', syncCase((rig, timers) async {
    rig.app.busy = true;
    await rig.app.openSession();
    expect(rig.app.busy, isTrue);
    rig.app.busy = false;
    expect(rig.app.busy, isFalse);
  }));
}
