import 'dart:async';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/sync/background_sync.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/headless_gate.dart';
import 'package:openstrap_edge/sync/ios_shortcut_sync.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show BandProfile;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

base class _AdapterOn extends FlutterBluePlusPlatform {
  @override
  Future<BmBluetoothAdapterState> getAdapterState(
    BmBluetoothAdapterStateRequest request,
  ) async => BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on);
}

// Stuck turning on until told otherwise. FBP caches the adapter state it reads
// and keeps it fed from the first platform it saw, so the test using this runs
// before the one installing _AdapterOn and settles the cache to on when done.
base class _AdapterTurningOn extends FlutterBluePlusPlatform {
  final changes = StreamController<BmBluetoothAdapterState>.broadcast();

  @override
  Future<BmBluetoothAdapterState> getAdapterState(
    BmBluetoothAdapterStateRequest request,
  ) async => BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.turningOn);

  @override
  Stream<BmBluetoothAdapterState> get onAdapterStateChanged => changes.stream;
}

class _LiveEngine extends BleEngine {
  _LiveEngine() : super(onRecord: (_, _) async {}, onState: (_) {});

  @override
  bool get isConnected => true;

  @override
  Map<String, dynamic> get offloadSnapshot => {'batches_acked': 0};
}

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

  test('a Shortcut connect re-arms the alarm like every headless connect', () {
    final src = File('lib/sync/ios_shortcut_sync.dart').readAsStringSync();
    final headless =
        src.substring(src.indexOf('Future<ShortcutSyncResult> _headless('));
    final connected = headless.indexOf('if (!connected)');
    expect(headless.indexOf('await prepareHeadlessLink('),
        greaterThan(connected));
    expect(headless.indexOf('await rearmHeadlessAlarm('),
        greaterThan(connected));
    expect(headless.indexOf('await rearmHeadlessAlarm('),
        lessThan(headless.indexOf('engine.runSync(')));
  });

  test('native is told ready only once AppState registered its hooks', () {
    final src = File('lib/sync/ios_shortcut_sync.dart').readAsStringSync();
    final init = src.substring(
      src.indexOf('static Future<void> init()'),
      src.indexOf('static Future<ShortcutSyncResult> run('),
    );
    expect(init, isNot(contains("'ready'")));
    final attach = src.substring(
      src.indexOf('static void attachForeground('),
      src.indexOf('static Future<void> init()'),
    );
    expect(attach.indexOf("'ready'"),
        greaterThan(attach.indexOf('foregroundEngine = engine')));
    final app = File('lib/state/app_state.dart').readAsStringSync();
    expect(app, contains('IosShortcutSync.attachForeground('));
  });

  test('shared headless event callback retains alarm confirmation', () async {
    final engine = createHeadlessSyncEngine(
      paired: PairedDevice('test', 'serial'),
    );
    final onEvent = engine.onEvent!
        as Future<void> Function(int, int, String, BandProfile);
    await onEvent(56, 1, '', BandProfile.gen4);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('alarm_epoch_confirmed'), isTrue);
    await prefs.setBool('alarm_epoch_confirmed', false);
    addTearDown(ResetGate.resetForTest);
    ResetGate.enter();
    await onEvent(56, 2, '', BandProfile.gen4);
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

  test(
    'an adapter that never settles is bluetoothUnavailable, not alreadyRunning',
    () async {
      final platform = _AdapterTurningOn();
      FlutterBluePlusPlatform.instance = platform;
      addTearDown(() async {
        platform.changes.add(
          BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on),
        );
        await pumpEventQueue();
      });
      await PairedDevice.save(
        '00000000-0000-0000-0000-000000000001',
        'test',
        generation: 'gen4',
      );
      final result = await IosShortcutSync.run(
        'adapter',
        const Duration(seconds: 10),
      );
      expect(result.status, 'bluetoothUnavailable');
      expect(HeadlessSyncGate.timedOutRuns, 0);
      expect(HeadlessSyncGate.busy, isFalse);
    },
  );

  test(
    'a Shortcut past its deadline releases the gate while the app burst runs on',
    () async {
      FlutterBluePlusPlatform.instance = _AdapterOn();
      await PairedDevice.save(
        '00000000-0000-0000-0000-000000000001',
        'test',
        generation: 'gen4',
      );
      final burst = Completer<SyncReport>();
      IosShortcutSync.foregroundEngine = _LiveEngine.new;
      IosShortcutSync.foregroundSync = (_) => burst.future;
      addTearDown(() {
        IosShortcutSync.foregroundEngine = null;
        IosShortcutSync.foregroundSync = null;
        if (!burst.isCompleted) burst.complete(SyncReport(0, 0, true));
      });
      final result = await IosShortcutSync.run(
        'deadline',
        const Duration(milliseconds: 300),
      );
      expect(result.status, 'partial');
      await pumpEventQueue();
      expect(HeadlessSyncGate.busy, isFalse);
      expect(
        (await HeadlessSyncGate.tryRun('bg_task', () async => true)),
        isTrue,
      );
    },
  );

  test('a Shortcut stopped mid-burst still reports committed records', () async {
    FlutterBluePlusPlatform.instance = _AdapterOn();
    await PairedDevice.save(
      '00000000-0000-0000-0000-000000000001',
      'test',
      generation: 'gen4',
    );
    final burst = Completer<SyncReport>();
    IosShortcutSync.foregroundEngine = _LiveEngine.new;
    IosShortcutSync.foregroundSync = (task) {
      task.update('syncing');
      IosShortcutSync.foregroundCommitted(42);
      return burst.future;
    };
    addTearDown(() {
      IosShortcutSync.foregroundEngine = null;
      IosShortcutSync.foregroundSync = null;
      if (!burst.isCompleted) burst.complete(SyncReport(0, 0, true));
    });
    final result = await IosShortcutSync.run(
      'committed',
      const Duration(milliseconds: 300),
    );
    expect(result.status, 'partial');
    expect(result.records, 42);
  });

  test('a joined app burst reports only what the Shortcut saw commit', () async {
    FlutterBluePlusPlatform.instance = _AdapterOn();
    await PairedDevice.save(
      '00000000-0000-0000-0000-000000000001',
      'test',
      generation: 'gen4',
    );
    IosShortcutSync.foregroundEngine = _LiveEngine.new;
    IosShortcutSync.foregroundSync = (task) async {
      IosShortcutSync.foregroundCommitted(3);
      // The burst's own total includes what landed before the Shortcut joined.
      return SyncReport(10, 2, false);
    };
    addTearDown(() {
      IosShortcutSync.foregroundEngine = null;
      IosShortcutSync.foregroundSync = null;
    });
    final result = await IosShortcutSync.run(
      'joined',
      const Duration(seconds: 5),
    );
    expect(result.status, 'partial');
    expect(result.records, 3);
  });
}
