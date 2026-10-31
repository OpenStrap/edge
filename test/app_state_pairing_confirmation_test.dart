// Selecting a band in the system picker is not a completed BLE bootstrap.
// Pair through the real AppState entry point with only the radio replaced,
// so a failed first connect cannot persist a pairing or advance onboarding.
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ios_ble_restore.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/paired_device.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'app_state_pairing_confirmation.db';

Future<Map<String, Object?>> _history() async {
  final db = await LocalDb.instance;
  return {
    'raw': await db.query('decoded_onehz'),
    'days': await db.query('day_result'),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await deriveDbSetUp(_db);
    NotificationService.instance.invalidatePermissionCache();
    NotificationService.instance.debugRequestPermission = () async => false;
    NotificationService.instance.debugProbePermission = () async => false;
    await (await LocalDb.instance).insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': 1786233600000,
      'rec_ts': 1786233600,
      'counter': 7,
      'hr': 62,
    });
    await (await LocalDb.instance).insert('day_result', {
      'day_id': '2026-08-09',
      'algo_version': 61,
      'payload_json': '{"scalars":{"rhr":52.0}}',
      'window_json': '{}',
      'computed_at': 1,
      'finalized': 1,
      'skipped': 0,
      'partial': 0,
    });
  });
  tearDown(() async {
    NotificationService.instance.debugRequestPermission = null;
    NotificationService.instance.debugProbePermission = null;
    await deriveDbTearDown(_db);
  });

  test(
    'a failed first connect is not saved or reported as paired',
    syncCase((rig, timers) async {
      final before = await _history();
      final pairedTicks = <bool>[];
      rig.app.addListener(() => pairedTicks.add(rig.app.isPaired));
      rig.engine.connectScript.add(false);
      rig.engine.connectHook = () async {
        // Discovery can identify a gen5 before CCC registration fails. That
        // partial bootstrap must not create a persisted device binding.
        rig.engine.state.generation = 'gen5';
        rig.app.debugFeedEngineState('', rig.engine.state);
      };

      await expectLater(
        rig.app.pairWith(BluetoothDevice.fromId(kRemoteId)),
        throwsA(isA<Exception>()),
      );

      expect(rig.app.isPaired, isFalse);
      expect(await PairedDevice.load(), isNull);
      expect(pairedTicks, isNot(contains(true)));
      expect(rig.app.busy, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(BandOwnership.foregroundIntent, isFalse);
      expect(IosBleRestore.foregroundActive, isFalse);
      expect(
        timers.activePeriodic(kSuperviseEvery),
        isEmpty,
        reason: 'an unconfirmed band must not start auto-reconnect',
      );
      expect(await _history(), before);
    }, paired: false),
  );

  test(
    'pairing waits for bootstrap, then saves the discovered identity',
    syncCase((rig, timers) async {
      final before = await _history();
      final gate = rig.holdConnect();
      final pairing = rig.app.pairWith(BluetoothDevice.fromId(kRemoteId));
      await rig.waitFor(() => rig.engine.count('connect') == 1);

      expect(rig.app.isPaired, isFalse);
      expect(await PairedDevice.load(), isNull);
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);

      rig.engine.state.generation = 'gen5';
      rig.engine.state.serial = 'MGB12345';
      gate.complete();
      await pairing;

      final saved = await PairedDevice.load();
      expect(saved?.remoteId, kRemoteId);
      expect(saved?.serial, 'MGB12345');
      expect(saved?.generation, 'gen5');
      expect(rig.app.isPaired, isTrue);
      expect(rig.app.isConnected, isTrue);
      expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
      expect(await _history(), before);
    }, paired: false),
  );

  test(
    'a thrown bootstrap releases ownership and remains retryable',
    syncCase((rig, timers) async {
      final before = await _history();
      final failure = StateError('CCC registration failed');
      rig.engine.connectScript.add(failure);
      await expectLater(
        rig.app.pairWith(BluetoothDevice.fromId(kRemoteId)),
        throwsA(same(failure)),
      );
      expect(rig.app.isPaired, isFalse);
      expect(await PairedDevice.load(), isNull);
      expect(rig.app.busy, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(IosBleRestore.foregroundActive, isFalse);

      await rig.app.pairWith(BluetoothDevice.fromId(kRemoteId));
      expect(rig.app.isPaired, isTrue);
      expect(await _history(), before);
    }, paired: false),
  );

  test(
    'a failed attempt can be retried without forgetting or deleting data',
    syncCase((rig, timers) async {
      final before = await _history();
      rig.engine.connectScript.add(false);
      await expectLater(
        rig.app.pairWith(BluetoothDevice.fromId(kRemoteId)),
        throwsA(isA<Exception>()),
      );

      rig.engine.state.generation = 'gen5';
      await rig.app.pairWith(BluetoothDevice.fromId(kRemoteId));

      expect(rig.app.isPaired, isTrue);
      expect((await PairedDevice.load())?.remoteId, kRemoteId);
      expect(await _history(), before);
    }, paired: false),
  );

  test(
    'an ASK picker grant alone does not confirm pairing, and can be retried',
    syncCase((rig, timers) async {
      const channel = MethodChannel('openstrap/accessory_setup');
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'showPicker') return kRemoteId;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      rig.engine.connectScript.add(false);

      await expectLater(
        rig.app.pairViaAccessorySetup(),
        throwsA(isA<Exception>()),
      );
      expect(rig.app.isPaired, isFalse);
      expect(await PairedDevice.load(), isNull);

      await rig.app.pairViaAccessorySetup();
      expect(rig.app.isPaired, isTrue);
      expect(calls, ['showPicker', 'showPicker']);
    }, paired: false),
  );

  test(
    'forgetting while bootstrap waits cannot recreate the pairing',
    syncCase((rig, timers) async {
      final before = await _history();
      final gate = rig.holdConnect();
      final pairing = rig.app.pairWith(BluetoothDevice.fromId(kRemoteId));
      final failed = expectLater(pairing, throwsA(isA<Exception>()));
      await rig.waitFor(() => rig.engine.count('connect') == 1);

      await rig.app.unpair();
      gate.complete();
      await failed;

      expect(rig.app.isPaired, isFalse);
      expect(await PairedDevice.load(), isNull);
      expect(rig.engine.isConnected, isFalse);
      expect(rig.app.busy, isFalse);
      expect(BandOwnership.owner, isNull);
      expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
      expect(await _history(), before);
    }, paired: false),
  );
}
