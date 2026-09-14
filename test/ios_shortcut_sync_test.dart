import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/sync/ios_shortcut_sync.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
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
