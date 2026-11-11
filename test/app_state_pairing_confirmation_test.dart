// Selecting a band in the system picker is not a completed BLE bootstrap.
// Pair through the real AppState entry point with only the radio replaced,
// so a failed first connect cannot persist a pairing or advance onboarding.
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ios_ble_restore.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/sync/band_ownership.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/app_state_sync_harness.dart';
import 'support/failing_preferences_store.dart';

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

  for (final throws in [true, false]) {
    test(
      'failed pairing persistence (throws=$throws) cleans up and can retry',
      syncCase((rig, timers) async {
        final before = await _history();
        final store = SharedPreferencesStorePlatform.instance;
        SharedPreferencesStorePlatform.instance = FailingPreferencesStore(
          store,
          key: 'paired_serial',
          throws: throws,
        );
        addTearDown(() => SharedPreferencesStorePlatform.instance = store);

        await expectLater(
          rig.app.pairWith(BluetoothDevice.fromId(kRemoteId)),
          throwsStateError,
        );

        expect(rig.app.isPaired, isFalse);
        expect(await PairedDevice.load(), isNull);
        expect(rig.engine.isConnected, isFalse);
        expect(rig.app.busy, isFalse);
        expect(BandOwnership.owner, isNull);
        expect(BandOwnership.foregroundIntent, isFalse);
        expect(IosBleRestore.foregroundActive, isFalse);
        expect(timers.activePeriodic(kSuperviseEvery), isEmpty);
        expect(await _history(), before);

        await rig.app.pairWith(BluetoothDevice.fromId(kRemoteId));
        expect(rig.app.isPaired, isTrue);
        expect((await PairedDevice.load())?.remoteId, kRemoteId);
        expect(await _history(), before);
      }, paired: false),
    );
  }

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
  group('replacement keeps the old pairing until READY', () {
    const replacementId = 'AA:BB:CC:DD:EE:99';

    test('held bootstrap keeps old identity; READY switches without losing history',
        syncCase((rig, timers) async {
      // WHY: discovering a replacement must not forget a working band.
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      final before = await _history();
      final old = await PairedDevice.load();
      final gate = rig.holdConnect();
      final replacing = rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      rig.engine.state.serial = 'NEW12345';
      rig.engine.state.generation = 'gen5';
      rig.app.debugFeedEngineState('', rig.engine.state);
      expect((await PairedDevice.load())?.remoteId, old!.remoteId);
      expect((await PairedDevice.load())?.serial, old.serial);
      expect(rig.app.isPaired, isTrue);
      gate.complete();
      await replacing;
      expect((await PairedDevice.load())?.remoteId, replacementId);
      expect((await PairedDevice.load())?.serial, 'NEW12345');
      expect((await PairedDevice.load())?.generation, 'gen5');
      expect(await _history(), before);
    }));

    for (final error in [false, StateError('bootstrap refused')]) {
      test('failed replacement ($error) preserves the old pairing',
          syncCase((rig, timers) async {
        // WHY: a failed new band must leave a saved old band to reconnect.
        await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      final before = await _history();
        rig.engine.connectScript.add(error);
        await expectLater(rig.app.replaceWith(BluetoothDevice.fromId(replacementId)),
            throwsA(isA<Object>()));
        expect((await PairedDevice.load())?.remoteId, kRemoteId);
        expect(rig.app.paired?.remoteId, kRemoteId);
        expect(rig.app.isPaired, isTrue);
        expect(rig.app.busy, isFalse);
        expect(rig.engine.events.where((e) => e.startsWith('connect:')), [
          'connect:$replacementId:-', 'connect:$kRemoteId:gen4',
        ]);
        expect(await _history(), before);
      }));
    }

    test('failed replacement save rolls back to the old pairing',
        syncCase((rig, timers) async {
      // WHY: READY alone cannot publish a primary the database did not save.
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      final before = await _history();
      final store = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance = FailingPreferencesStore(
          store, key: 'paired_serial', throws: true);
      addTearDown(() => SharedPreferencesStorePlatform.instance = store);
      await expectLater(rig.app.replaceWith(BluetoothDevice.fromId(replacementId)),
          throwsStateError);
      expect((await PairedDevice.load())?.remoteId, kRemoteId);
      expect(rig.app.paired?.remoteId, kRemoteId);
      expect(await _history(), before);
    }));

    test('forget wins while replacement waits',
        syncCase((rig, timers) async {
      // WHY: cancelling the old pairing must not resurrect it on rollback.
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      final gate = rig.holdConnect();
      final replacing = rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
      final failed = expectLater(replacing, throwsA(isA<Object>()));
      await rig.waitFor(() => rig.engine.count('connect') == 1);
      await rig.app.unpair();
      gate.complete();
      await failed;
      expect(await PairedDevice.load(), isNull);
      expect(rig.app.isPaired, isFalse);
    }));
    test('a cancelled system picker keeps the old pairing and requests addAnother',
        syncCase((rig, timers) async {
      // WHY: an already-provisioned old band must not silently win the picker.
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      const channel = MethodChannel('openstrap/accessory_setup');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Object? argument;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'showPicker') {
          argument = call.arguments;
          throw PlatformException(code: 'cancelled');
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await expectLater(rig.app.replaceViaAccessorySetup(), throwsA(isA<PlatformException>()));
      expect(argument, isTrue);
      expect((await PairedDevice.load())?.remoteId, kRemoteId);
      expect(rig.app.isPaired, isTrue);
    }));

    test('forget during the replacement save does not recreate a pairing',
        syncCase((rig, timers) async {
      // WHY: unpair must win both before READY and while persistence awaits.
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      final store = SharedPreferencesStorePlatform.instance;
      final held = _HeldPreferences(store);
      SharedPreferencesStorePlatform.instance = held;
      addTearDown(() => SharedPreferencesStorePlatform.instance = store);
      final replacing = rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
      final failed = expectLater(replacing, throwsA(isA<Object>()));
      await held.entered.future;
      final forgetting = rig.app.unpair();
      held.release.complete();
      await forgetting;
      await failed;
      expect(await PairedDevice.load(), isNull);
      expect(rig.app.isPaired, isFalse);
    }));


  });
}

// Hold the actual preference write, keeping PairedDevice's real transaction.
class _HeldPreferences extends SharedPreferencesStorePlatform {
  _HeldPreferences(this.delegate);
  final SharedPreferencesStorePlatform delegate;
  final entered = Completer<void>();
  final release = Completer<void>();
  bool held = false;
  Future<bool> write(String key, Future<bool> Function() action) async {
    if (!held && key == 'flutter.paired_serial') {
      held = true;
      entered.complete();
      await release.future;
    }
    return action();
  }
  @override
  Future<Map<String, Object>> getAll() => delegate.getAll();
  @override
  Future<bool> clear() => delegate.clear();
  @override
  Future<bool> remove(String key) => write(key, () => delegate.remove(key));
  @override
  Future<bool> setValue(String type, String key, Object value) =>
      write(key, () => delegate.setValue(type, key, value));
}
