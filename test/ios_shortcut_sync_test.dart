import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/background_sync.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/sync/ios_shortcut_sync.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_shortcut_sync_test.db';
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
    await LocalDb.deleteDevice();
    HeadlessSyncGate.resetForTest();
    BandOwnership.resetForTest();
  });

  test(
    'reset is a failure, not an ignorable pairing or connectivity result',
    () async {
      addTearDown(ResetGate.resetForTest);
      ResetGate.enter();
      final result = await IosShortcutSync.run(
        'reset',
        const Duration(seconds: 2),
      );
      expect(result.status, 'failed');
      expect(HeadlessSyncGate.busy, isFalse);
      expect(BandOwnership.owner, isNull);
    },
  );

  test(
    'shared headless commit refuses ACK during reset and reports failure',
    () async {
      addTearDown(ResetGate.resetForTest);
      var committed = 0;
      Object? failure;
      final engine = createHeadlessSyncEngine(
        paired: PairedDevice('test', 'serial'),
        onCommitted: (_) => committed++,
        onCommitError: (error) => failure = error,
      );
      ResetGate.enter();
      await expectLater(
        engine.onCommitBatch!([], [], '0011223344556677'),
        throwsStateError,
      );
      expect(failure, isA<StateError>());
      expect(committed, 0);
      expect(engine.onReadyEcgRecovery, isNotNull);
    },
  );

  test('shared headless event callback retains alarm confirmation', () async {
    final engine = createHeadlessSyncEngine(
      paired: PairedDevice('test', 'serial'),
    );
    final onEvent = engine.onEvent! as Future<void> Function(int, int, String);
    await onEvent(56, 1, '');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('alarm_epoch_confirmed'), isTrue);
    await prefs.setBool('alarm_epoch_confirmed', false);
    addTearDown(ResetGate.resetForTest);
    ResetGate.enter();
    await onEvent(56, 2, '');
    expect(prefs.getBool('alarm_epoch_confirmed'), isFalse);
  });

  test(
    'unpaired invocation reports a prerequisite failure without touching Bluetooth',
    () async {
      final result = await IosShortcutSync.run(
        'unpaired',
        const Duration(seconds: 2),
      );
      expect(result.toMap(), {'status': 'notPaired', 'records': 0});
      expect(HeadlessSyncGate.busy, isFalse);
      expect(BandOwnership.owner, isNull);
    },
  );

  test('pending accessory setup must not create a Bluetooth central', () async {
    await PairedDevice.save(
      '00000000-0000-0000-0000-000000000001',
      'test',
      generation: 'gen4',
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(Prefs.kAskAddPendingKey, true);
    final result = await IosShortcutSync.run(
      'setup',
      const Duration(seconds: 2),
    );
    expect(result.status, 'setupRequired');
    expect(HeadlessSyncGate.busy, isFalse);
    expect(BandOwnership.owner, isNull);
  });

  test(
    'another wake owns the gate and the Shortcut does not run or claim success',
    () async {
      final release = Completer<void>();
      final wake = HeadlessSyncGate.tryRun('bg_task', () => release.future);
      final result = await IosShortcutSync.run(
        'overlap',
        const Duration(seconds: 2),
      );
      expect(result.status, 'alreadyRunning');
      expect(HeadlessSyncGate.busy, isTrue);
      release.complete();
      await wake;
      expect(HeadlessSyncGate.busy, isFalse);
      expect(
        (await IosShortcutSync.run('next', const Duration(seconds: 2))).status,
        'notPaired',
      );
    },
  );
}
