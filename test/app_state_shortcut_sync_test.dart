import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:openstrap_edge/sync/shortcut_sync_task.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ConnectedEngine extends BleEngine {
  final reply = Completer<SyncReport>();
  int requests = 0;
  int runs = 0;
  int disconnects = 0;
  int probes = 0;
  Duration quietFor = Duration.zero;
  bool? background;

  _ConnectedEngine() : super(onRecord: (_, _) async {}, onState: (_) {});

  @override
  bool get isConnected => true;

  @override
  Duration get sinceLastRx => quietFor;

  @override
  Future<bool> probeLink({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    probes++;
    return true;
  }

  @override
  Future<void> requestHistorySync() async => requests++;

  @override
  Future<SyncReport> runSync({
    Duration timeout = const Duration(seconds: 600),
  }) {
    runs++;
    return reply.future;
  }

  @override
  Future<void> disconnect() async => disconnects++;

  @override
  void setBackground(bool value) => background = value;
}

/// Session 1 banks records and advances the frontier with backlog left on the
/// strap; session 2 gets nothing because the link dropped.
class _TwoSessionEngine extends _ConnectedEngine {
  @override
  int? get strapHistoryNewestTs => 1000000;

  @override
  Future<SyncReport> runSync({
    Duration timeout = const Duration(seconds: 600),
  }) async {
    runs++;
    if (runs > 1) return SyncReport(0, 0, false);
    await LocalDb.setCursor('rec_ts_hw', '500');
    return SyncReport(42, 3, false);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_app_state_shortcut_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  // openSession needs the plugin stack and an iOS host to reach the restore
  // bridge, so this pins the source instead. A background Shortcut whose
  // connect fails must hand the band back to the restore path, or
  // foregroundActive stays true with no link and every restore wake and
  // BG-task sync skips until the user next opens the app.
  test('a failed background openSession re-arms iOS recovery', () {
    final src = File('lib/state/sync_controller.dart').readAsStringSync();
    final start = src.indexOf('Future<void> openSession(');
    expect(start, isNot(-1));
    final body = src.substring(start, src.indexOf('\n  }\n', start));
    final fin = body.lastIndexOf('} finally {');
    expect(fin, isNot(-1));
    const rearm =
        'if (_keepAlive && background && !engine.isConnected) {\n'
        '        await _armRecovery();';
    expect(body.substring(fin).contains(rearm), isTrue);
  });

  // A background Shortcut connect holds `busy`; opening the app mid-connect
  // bounces off it. The foreground flip must still land, or the visible app
  // runs in background mode (derive deferred, live HR off) until the next
  // pause/resume.
  test('opening the app during a background session still foregrounds', () async {
    final engine = _ConnectedEngine();
    final app = AppState.forTesting(engine: engine)..initialized = true;
    addTearDown(app.dispose);
    await app.pauseForBackground();
    expect(app.debugLiveOwners.foreground, isFalse);
    app
      ..paired = PairedDevice('band', null)
      ..busy = true;
    await app.openSession();
    expect(app.debugLiveOwners.foreground, isTrue);
  });

  test(
    'a data reset prevents a Shortcut from touching the app-owned band',
    () async {
      final engine = _ConnectedEngine();
      engine.reply.complete(SyncReport(0, 0, true));
      final app = AppState.forTesting(engine: engine)..initialized = true;
      addTearDown(app.dispose);
      addTearDown(ResetGate.resetForTest);
      ResetGate.enter();
      await expectLater(
        app.syncForShortcut(
          ShortcutSyncTask('reset', const Duration(seconds: 5)),
        ),
        throwsStateError,
      );
      expect(engine.requests, 0);
      expect(engine.disconnects, 0);
    },
  );

  test('a quiet non-streaming link is probed and reused', () async {
    final engine = _ConnectedEngine()..quietFor = const Duration(minutes: 5);
    final app = AppState.forTesting(engine: engine)..initialized = true;
    addTearDown(app.dispose);
    engine.reply.complete(SyncReport(0, 0, true));
    final report = await app.syncForShortcut(
      ShortcutSyncTask('quiet', const Duration(seconds: 5)),
    );
    expect(report.complete, isTrue);
    expect(engine.probes, 1);
    expect(engine.disconnects, 0);
    expect(engine.requests, 1);
  });

  test('concurrent callers join the app-owned sync burst', () async {
    final engine = _ConnectedEngine();
    final app = AppState.forTesting(engine: engine)..initialized = true;
    addTearDown(app.dispose);
    final first = app.syncForShortcut(
      ShortcutSyncTask('first', const Duration(seconds: 5)),
    );
    final second = app.syncForShortcut(
      ShortcutSyncTask('second', const Duration(seconds: 5)),
    );
    while (engine.runs == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(engine.requests, 1);
    expect(engine.runs, 1);
    engine.reply.complete(SyncReport(0, 0, true));
    expect((await first).complete, isTrue);
    expect((await second).complete, isTrue);
    expect(engine.disconnects, 0);
  });

  test(
    'cancellation while waiting for initialization never touches the band',
    () async {
      final engine = _ConnectedEngine();
      final app = AppState.forTesting(engine: engine);
      addTearDown(app.dispose);
      final task = ShortcutSyncTask('starting', const Duration(seconds: 5));
      final work = app.syncForShortcut(task);
      task.stop('cancelled');
      expect((await work).complete, isFalse);
      expect(engine.requests, 0);
      expect(engine.disconnects, 0);
    },
  );

  test(
    'cancellation while the app is busy never starts another burst',
    () async {
      final engine = _ConnectedEngine();
      final app = AppState.forTesting(engine: engine)
        ..initialized = true
        ..busy = true;
      addTearDown(app.dispose);
      final task = ShortcutSyncTask('busy', const Duration(seconds: 5));
      final work = app.syncForShortcut(task);
      expect(task.phase, 'waiting');
      task.stop('cancelled');
      expect((await work).complete, isFalse);
      expect(engine.requests, 0);
      expect(engine.disconnects, 0);
    },
  );

  test('joining the burst after waiting reports syncing, not waiting', () async {
    final engine = _ConnectedEngine();
    final app = AppState.forTesting(engine: engine)
      ..initialized = true
      ..busy = true;
    addTearDown(app.dispose);
    final task = ShortcutSyncTask('join', const Duration(seconds: 5));
    final work = app.syncForShortcut(task);
    expect(task.phase, 'waiting');
    app.busy = false;
    while (engine.runs == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(task.phase, 'syncing');
    expect(task.expired.status, 'partial');
    engine.reply.complete(SyncReport(0, 0, true));
    await work;
  });

  test('cancelling a waiter preserves the app-owned transfer', () async {
    final engine = _ConnectedEngine();
    final app = AppState.forTesting(engine: engine)..initialized = true;
    addTearDown(app.dispose);
    final task = ShortcutSyncTask('cancel', const Duration(seconds: 5));
    final work = app.syncForShortcut(task);
    while (engine.runs == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    task.stop('cancelled');
    expect(engine.disconnects, 0);
    engine.reply.complete(SyncReport(0, 0, true));
    await work;
    expect(engine.disconnects, 0);
    expect(task.stopped, isTrue);
  });

  test('a stopped Shortcut stops waiting on the app-owned burst', () async {
    final engine = _ConnectedEngine();
    final app = AppState.forTesting(engine: engine)..initialized = true;
    addTearDown(app.dispose);
    final task = ShortcutSyncTask('deadline', const Duration(seconds: 5));
    final work = app.syncForShortcut(task);
    while (engine.runs == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    task.stop();
    // Returns while the burst is still running, so the gate is not held for it.
    final report = await work.timeout(const Duration(seconds: 1));
    expect(report.complete, isFalse);
    expect(engine.reply.isCompleted, isFalse);
    expect(engine.disconnects, 0);
    engine.reply.complete(SyncReport(0, 0, true));
  });

  test('a deadline after waiting on a busy app reports partial', () async {
    final engine = _ConnectedEngine();
    final app = AppState.forTesting(engine: engine)
      ..initialized = true
      ..busy = true;
    addTearDown(app.dispose);
    final task = ShortcutSyncTask('waited', const Duration(seconds: 5));
    final work = app.syncForShortcut(task);
    expect(task.phase, 'waiting');
    app.busy = false;
    while (engine.runs == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(task.expired.status, 'partial');
    task.stop();
    await work;
    engine.reply.complete(SyncReport(0, 0, true));
  });

  test('a burst reports records banked by every session, not the last', () async {
    await LocalDb.deleteCursor('rec_ts_hw');
    final engine = _TwoSessionEngine();
    final app = AppState.forTesting(engine: engine)..initialized = true;
    addTearDown(app.dispose);
    final report = await app.syncForShortcut(
      ShortcutSyncTask('two', const Duration(seconds: 5)),
    );
    expect(engine.runs, 2);
    expect(report.records, 42);
    expect(report.batches, 3);
    expect(report.complete, isFalse);
  });

  test('opening the app during an in-flight session foregrounds it', () async {
    final engine = _ConnectedEngine();
    final app = AppState.forTesting(engine: engine)
      ..paired = PairedDevice('r1', 's1', generation: 'gen4')
      ..busy = true;
    addTearDown(app.dispose);
    await app.openSession();
    expect(engine.background, isFalse);
  });
}
