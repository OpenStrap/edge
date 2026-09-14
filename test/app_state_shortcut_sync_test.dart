import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/shortcut_sync_task.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ConnectedEngine extends BleEngine {
  final reply = Completer<SyncReport>();
  int requests = 0;
  int runs = 0;
  int disconnects = 0;

  _ConnectedEngine() : super(onRecord: (_, _) async {}, onState: (_) {});

  @override
  bool get isConnected => true;

  @override
  Duration get sinceLastRx => Duration.zero;

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
}
