// Selecting a band in the system picker is not a completed BLE bootstrap.
// Pair through the real AppState entry point with only the radio replaced,
// so a failed first connect cannot persist a pairing or advance onboarding.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:openstrap_edge/sync/background_sync.dart' show rearmHeadlessAlarm;
import 'package:openstrap_edge/data/models.dart' show DeviceState;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ios_ble_restore.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/state/app_state.dart' show SameBandSelectedException;
import 'package:openstrap_edge/state/alarm_schedule.dart' show kAlarmRemoteId, persistedAlarmEpoch;
import 'package:openstrap_edge/state/prefs.dart' show Prefs;
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

    // WHY: old accessory retirement can revoke the next replacement's approval.
    // CLAIM(pairing-retirement-lock); catches: clearing the lock before removeBand.
    test('replacement stays exclusive until old accessory retirement settles',
        syncCase((rig, timers) async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final retired = <String>[];
      rig.app.debugRetireBandApproval = (id) async {
        retired.add(id);
        entered.complete();
        await release.future;
      };
      final replacing = rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
      await entered.future;
      try {
        expect(rig.app.paired?.remoteId, replacementId);
        await expectLater(rig.app.pairWith(BluetoothDevice.fromId(kRemoteId)),
            throwsStateError);
        await expectLater(rig.app.replaceViaAccessorySetup(), throwsStateError);
        expect(rig.app.paired?.remoteId, replacementId);
        expect(retired, [kRemoteId]);
      } finally {
        release.complete();
        await replacing;
      }
      rig.app.debugRetireBandApproval = (_) async {};
      await rig.app.replaceWith(BluetoothDevice.fromId(kRemoteId));
      expect(rig.app.paired?.remoteId, kRemoteId,
          reason: 'the next deliberate replacement works once retirement ends');
    }));

    // WHY: an early refusal never left the old band; wiping it destroys live data.
    // CLAIM(pairing-refusal-preserves-state); catches: unconditional rollback reset.
    test('busy refusal preserves the connected old band and its live HR',
        syncCase((rig, timers) async {
      await rig.openAndSettle();
      rig.app.pairedIsMaverick = true;
      rig.app.debugFeedEngineState('', rig.engine.state
        ..serial = kSerial ..generation = 'gen5'
        ..liveHr = 61 ..liveHrAt = 1786233600000);
      final before = await _history();
      rig.engine.events.clear();
      rig.app.busy = true;
      try {
        await expectLater(rig.app.replaceWith(BluetoothDevice.fromId(replacementId)),
            throwsA(isA<Exception>()));
        expect(rig.engine.isConnected, isTrue);
        expect(rig.app.device.serial, kSerial);
        expect(rig.app.device.generation, 'gen5');
        expect(rig.app.liveHrTrace(''), [61]);
        expect(rig.app.pairedIsMaverick, isTrue);
        expect(rig.engine.only('connect'), isEmpty);
        expect(rig.engine.count('disconnect'), 0);
        expect(await _history(), before);
      } finally {
        rig.app.busy = false;
      }
    }));

    for (final throws in [true, false]) {
      // WHY: stale persisted state must never stand in for a write to a new band.
      // CLAIM(alarm-band-ownership); catches: logging a failed epoch remove then deduping it.
      test('replacement arms despite epoch removal failure (throws=$throws)',
          syncCase((rig, timers) async {
        await rig.openAndSettle();
        final tomorrow = DateTime.now().add(const Duration(days: 1));
        await rig.app.setScheduleDay(weekday: tomorrow.weekday - 1,
            hour: 7, minute: 0, enabled: true);
        final epoch = rig.app.alarmEpoch;
        final schedule = await LocalDb.alarmScheduleRows();
        expect(epoch, isNotNull);
        final store = SharedPreferencesStorePlatform.instance;
        SharedPreferencesStorePlatform.instance = _AlarmRemoveFailure(store, throws);
        addTearDown(() => SharedPreferencesStorePlatform.instance = store);
        rig.engine.events.clear();
        await rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
        expect(rig.engine.count('armAlarm'), 1,
            reason: 'old epoch cannot suppress the new physical band’s SET_ALARM');
        expect(rig.app.alarmEpoch, epoch);
        expect(rig.app.alarmConfirmed, isTrue);
        expect(await LocalDb.alarmScheduleRows(), schedule);
        expect((await PairedDevice.load())?.remoteId, replacementId);
      }));
    }

    // WHY: background reconnects use the same physical alarm ownership rule.
    // CLAIM(alarm-band-ownership); catches: a headless read bypassing owner checks.
    test('headless reconnect never adopts another band’s persisted alarm',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await rig.openAndSettle();
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      await rig.app.setScheduleDay(weekday: tomorrow.weekday - 1,
          hour: 7, minute: 0, enabled: true);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('alarm_remote_id', 'retired-band');
      rig.engine.events.clear();
      await rearmHeadlessAlarm(rig.engine, PairedDevice(kRemoteId, kSerial));
      expect(rig.engine.count('armAlarm'), 1);
      expect(prefs.getString('alarm_remote_id'), kRemoteId);
    }));

    // WHY: a foreground replacement can commit another band while a headless
    // sync is still running. SET_ALARM went to the SESSION's band, so the epoch
    // must be recorded under that band, never under the pairing loaded after.
    // catches: reloading the current pairing inside rearmHeadlessAlarm.
    test('headless re-arm records the alarm under the session band, not the current pairing',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await rig.openAndSettle();
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      await rig.app.setScheduleDay(weekday: tomorrow.weekday - 1,
          hour: 7, minute: 0, enabled: true);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('alarm_epoch');
      await prefs.setString('alarm_remote_id', 'retired-band');
      rig.engine.events.clear();
      // The persisted pairing is kRemoteId; the session that armed was another.
      await rearmHeadlessAlarm(rig.engine, PairedDevice(replacementId, null));
      expect(rig.engine.count('armAlarm'), 1);
      expect(prefs.getString('alarm_remote_id'), replacementId,
          reason: 'recorded under the band that received SET_ALARM');
      expect((await PairedDevice.load())?.remoteId, kRemoteId);
    }));

    // WHY: a replacement can leave the old link before its prepare callback.
    // CLAIM(pairing-refusal-preserves-state); catches: rolling back only after prepare.
    test('departure failure before prepare still restores the old pairing',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await rig.openAndSettle();
      final before = await _history();
      rig.engine.events.clear();
      var departed = false;
      rig.engine.disconnectHook = () async {
        if (!departed) {
          departed = true;
          throw StateError('old disconnect failed');
        }
      };
      await expectLater(rig.app.replaceWith(BluetoothDevice.fromId(replacementId)),
          throwsStateError);
      expect(rig.app.paired?.remoteId, kRemoteId);
      expect(rig.engine.isConnected, isTrue);
      expect(rig.engine.only('connect'), ['connect:$kRemoteId:gen4']);
      expect(await _history(), before);
    }));

    // WHY: binding a legacy alarm adds an await before PairedDevice.save starts.
    // CLAIM(pairing-cancellation-epoch); catches: checking cancellation only before that await.
    test('forget while alarm ownership waits cannot recreate the pairing',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await rig.openAndSettle();
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      await rig.app.setScheduleDay(weekday: tomorrow.weekday - 1,
          hour: 7, minute: 0, enabled: true);
      final store = SharedPreferencesStorePlatform.instance;
      final held = _HeldPreferences(store, key: 'alarm_remote_id');
      SharedPreferencesStorePlatform.instance = held;
      addTearDown(() => SharedPreferencesStorePlatform.instance = store);
      final replacing = rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
      final failed = expectLater(replacing, throwsA(isA<Object>()));
      await held.entered.future;
      try {
        await rig.app.unpair();
      } finally {
        held.release.complete();
      }
      await failed;
      expect(rig.app.isPaired, isFalse);
      expect(await PairedDevice.load(), isNull);
    }));

    // WHY: once PairedDevice.save returns the replacement is durable. A failing
    // read-back must not be treated as a failed save, or the old band is
    // reconnected while storage names the new one and a restart disagrees.
    // catches: rolling back to the old band after a successful save.
    test('replacement stays committed when reading the saved band back fails',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await rig.openAndSettle();
      rig.engine.events.clear();
      rig.app.debugLoadPaired = () async => throw StateError('read-back failed');
      await rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
      expect((await PairedDevice.load())?.remoteId, replacementId);
      expect(rig.app.paired?.remoteId, replacementId);
      expect(rig.engine.only('connect'),
          isNot(contains('connect:$kRemoteId:gen4')),
          reason: 'the old band must not be reconnected after the save');
    }));

    // WHY: the primary peripheral must never also be a secondary sensor. A
    // candidate that already has a workout-only row would be saved as primary
    // with that row (and its link) still alive.
    // catches: replacing onto a band that is already a secondary sensor.
    test('replacement refuses a candidate that is already a secondary sensor',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await rig.openAndSettle();
      await LocalDb.upsertDevice(
          id: 'ble_hrs-$replacementId',
          adapterId: 'ble_hrs',
          remoteId: replacementId,
          label: 'Chest strap');
      rig.engine.events.clear();
      await expectLater(
          rig.app.replaceWith(BluetoothDevice.fromId(replacementId)),
          throwsA(isA<Exception>()));
      expect((await PairedDevice.load())?.remoteId, kRemoteId,
          reason: 'the current band stays paired');
      expect(rig.engine.only('connect'), isEmpty,
          reason: 'nothing starts before the refusal');
      expect((await LocalDb.deviceRows()).where((r) => r['remote_id'] == replacementId),
          hasLength(1), reason: 'the sensor row is untouched');
    }));

    // WHY: an upgraded install can hold an armed epoch with no owner tag, which
    // every band reads as its own. After a forget, a new band would be treated
    // as already armed and never receive SET_ALARM.
    // catches: forgetting a band and leaving its armed alarm readable.
    test('forgetting a band drops its armed alarm so the next band is armed afresh',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await rig.openAndSettle();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kAlarmRemoteId);
      await prefs.setInt('alarm_epoch', 1893456000);
      await rig.app.unpair();
      expect(prefs.getInt('alarm_epoch'), isNull);
      expect(rig.app.alarmEpoch, isNull);
      expect(persistedAlarmEpoch(prefs, replacementId), isNull,
          reason: 'a different band is not treated as armed');
    }));

    // WHY: the provisioning await can outlive a forget that started after the
    // first check; _persistPaired would capture the NEW epoch as its own and
    // could recreate the pairing the user just cancelled.
    // catches: a stale picker result entering replacement after unpair().
    test('a forget during picker provisioning stops the replacement',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await rig.openAndSettle();
      const channel = MethodChannel('openstrap/accessory_setup');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'showPicker') return replacementId;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      // The forget STARTS inside the provisioning await and is still running
      // (the old pairing is still visible) when replacement would proceed.
      Future<void>? forgetting;
      rig.app.debugAfterReplacementProvisioned = () async {
        forgetting = rig.app.unpair();
      };
      rig.engine.events.clear();
      await expectLater(
          rig.app.replaceViaAccessorySetup(),
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message', contains('current pairing changed'))));
      await forgetting;
      expect(await PairedDevice.load(), isNull,
          reason: 'the forgotten pairing is not recreated');
      expect(rig.app.isPaired, isFalse);
      expect(rig.engine.only('connect'), isNot(contains('connect:$replacementId:-')));
    }));

    // WHY: the old band's sync burst must be over before the candidate
    // connects, or it can ask the NEW band for history.
    // catches: connecting the candidate while the superseded burst still runs.
    test('replacement waits for the superseded sync burst before connecting',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await rig.openAndSettle();
      rig.engine.events.clear();
      final gate = Completer<void>();
      rig.engine.syncGate = gate;
      final burst = rig.app.syncNow();
      await rig.waitFor(() => rig.engine.events.any((e) => e.startsWith('runSync')));
      final replacing = rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
      await settleMs(60);
      expect(rig.engine.only('connect'), isNot(contains('connect:$replacementId:-')),
          reason: 'the candidate must not connect while the old burst runs');
      rig.engine.syncGate = null;
      gate.complete();
      await burst;
      await replacing;
      expect(rig.engine.only('connect'), contains('connect:$replacementId:-'));
    }));

    // WHY: a replacement awaits the alarm-ownership write inside its confirm
    // step. A reset can finish in that await: it empties the store without
    // bumping the pairing epoch, and the gate is back down by the time the save
    // would run. Only the reset GENERATION shows it happened.
    // catches: saving a replacement into a store a reset just emptied.
    test('a reset that finishes during the alarm ownership write cancels the replacement',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await rig.openAndSettle();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kAlarmRemoteId);
      await prefs.setInt('alarm_epoch', 1893456000); // makes confirm write the owner
      final store = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance = _ResetDuring(store, 'flutter.$kAlarmRemoteId');
      addTearDown(() => SharedPreferencesStorePlatform.instance = store);
      await expectLater(
          rig.app.replaceWith(BluetoothDevice.fromId(replacementId)),
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message', contains('Pairing was cancelled'))));
      expect(ResetGate.active, isFalse);
      expect((await PairedDevice.load())?.remoteId, kRemoteId,
          reason: 'the replacement must not be saved after the reset');
    }));

    // WHY: setAlarm waits for the band's reply. If the band is forgotten while
    // it waits, the arm must not be saved afterwards: with no paired band the
    // epoch would be written ownerless, and any later band reads it as its own.
    // catches: persisting an arm for a band that is no longer paired.
    test('an alarm arm pending while the band is forgotten is not recorded',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await rig.openAndSettle();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('alarm_epoch');
      await prefs.remove(kAlarmRemoteId);
      final gate = Completer<void>();
      rig.engine.armGate = gate;
      final arming = rig.app.setAlarm(DateTime.now().add(const Duration(hours: 8)));
      await rig.waitFor(() => rig.engine.events.any((e) => e.startsWith('armAlarm')));
      await rig.app.unpair();
      rig.engine.armGate = null;
      gate.complete();
      await arming;
      expect(prefs.getInt('alarm_epoch'), isNull,
          reason: 'an ownerless epoch would be read as armed by the next band');
      expect(persistedAlarmEpoch(prefs, replacementId), isNull);
      expect(rig.app.alarmEpoch, isNull);
    }));

    // WHY: waiting out the old burst is bounded, but a timeout is not "the burst
    // stopped": it could resume on the candidate's session and request history
    // from the wrong band. Pairing must stop instead of connecting under it.
    // catches: treating the wait's timeout as permission to connect.
    test('replacement stops when the superseded sync burst outlives the wait',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await rig.openAndSettle();
      rig.engine.events.clear();
      final gate = Completer<void>();
      rig.engine.syncGate = gate;
      final burst = rig.app.syncNow();
      await rig.waitFor(() => rig.engine.events.any((e) => e.startsWith('runSync')));
      final replacing = rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
      final failed = expectLater(replacing, throwsA(isA<Exception>()));
      await settleMs(60);
      final waits = timers.activeOneShot(const Duration(seconds: 15));
      expect(waits, hasLength(1), reason: 'the bounded wait for the old burst');
      waits.single.fire();
      await failed;
      expect(rig.engine.only('connect'), isNot(contains('connect:$replacementId:-')),
          reason: 'the candidate must not connect under a still-running burst');
      expect((await PairedDevice.load())?.remoteId, kRemoteId,
          reason: 'the old pairing is kept');
      rig.engine.syncGate = null;
      gate.complete();
      await burst;
    }));

    // WHY: a lost band's retry must finish before candidate bootstrap starts.
    // catches: rejecting replacement because the old loop is reconnecting,
    // or clearing its flag without waiting for its in-flight connect.
    for (final success in [true, false]) {
      test('replacement retires an in-flight reconnect (success=$success)',
          syncCase((rig, timers) async {
        await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
        await rig.openAndSettle();
        rig.engine.events.clear();
        final oldConnect = rig.holdConnect();
        rig.engine.drop();
        await rig.waitFor(() => rig.engine.count('connect') == 1);
        var completed = false;
        rig.engine.connectScript.addAll([true, success, false, true]);
        final replacement = rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
        final observed = success
            ? replacement.then((_) => completed = true)
            : expectLater(replacement, throwsA(isA<Exception>())).then((_) => completed = true);
        await settleMs(40);
        expect(completed, isFalse, reason: 'old connect still owns the radio');
        expect(rig.engine.only('connect'), ['connect:$kRemoteId:gen4']);
        oldConnect.complete();
        await observed;
        expect(rig.engine.only('connect').take(2), [
          'connect:$kRemoteId:gen4', 'connect:$replacementId:-',
        ]);
        expect((await PairedDevice.load())?.remoteId, success ? replacementId : kRemoteId);
        expect(timers.activePeriodic(kSuperviseEvery), hasLength(1));
        if (!success) {
          // Recovery is supervised even if its first attempt cannot reach the old band.
          timers.activePeriodic(kSuperviseEvery).single.fire();
          await rig.waitFor(() => rig.engine.only('connect').length >= 4);
        }
      }));
    }

    for (final succeeds in [true, false]) {
      // WHY: after a process kill, an unreachable old band leaves the only
      // durable copy of a walk in prefs. Empty finalization must preserve it.
      // CLAIM(orphan-checkpoint-preserved); catches: clearing after banking no runs.
      test('replacement preserves orphan steps (succeeds=$succeeds)',
          syncCase((rig, timers) async {
        const checkpoint = '{"runs":[[1786233600,1786233660,80],'
            '[1786233720,1786233780,120]]}';
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('live_session_checkpoint', checkpoint);
        rig.engine.connectScript.add(false);
        await rig.app.openSession();
        expect(rig.engine.isConnected, isFalse);
        expect(prefs.getString('live_session_checkpoint'), checkpoint);
        final db = await LocalDb.instance;
        expect(await db.query('live_coverage'), isEmpty);

        rig.engine.connectScript.addAll(succeeds ? [true] : [false, false]);
        final replacing = rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
        if (succeeds) {
          await replacing;
        } else {
          await expectLater(replacing, throwsA(isA<Exception>()));
          expect(prefs.getString('live_session_checkpoint'), checkpoint);
          expect(await db.query('live_coverage'), isEmpty);
          await rig.app.openSession();
        }
        // These are the checkpoint's credited counts, recovered verbatim.
        final rows = await db.query('live_coverage',
            columns: ['start_ts', 'end_ts', 'steps'], orderBy: 'start_ts');
        expect(rows, [
          {'start_ts': 1786233600, 'end_ts': 1786233660, 'steps': 80},
          {'start_ts': 1786233720, 'end_ts': 1786233780, 'steps': 120},
        ]);
        expect(prefs.getString('live_session_checkpoint'), isNull);
        // A later session must not recover the same walk twice.
        await rig.app.endSession();
        await rig.app.openSession();
        expect(await db.query('live_coverage',
            columns: ['start_ts', 'end_ts', 'steps'], orderBy: 'start_ts'), rows);
      }));
    }

    // WHY: replacement suppresses the old disconnect callback, including its
    // pedometer finalization. A 20-second tail is still recorded walking data.
    // catches: resetting the pedometer at new-session start without banking it.
    test('replacement banks the old band partial gait minute',
        syncCase((rig, timers) async {
      const startMs = 1786233600000;
      for (var frame = 0; frame < 100; frame++) {
        rig.app.debugFeedLiveAccel([
          for (var i = 0; i < 20; i++)
            1 + 0.45 * math.sin(2 * math.pi * 2 * (frame * 20 + i) / 100),
        ], atMs: startMs + frame * 200, recTs: startMs ~/ 1000);
      }
      await rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
      final rows = await (await LocalDb.instance).query('live_coverage');
      expect(rows, hasLength(1));
      expect(rows.single['start_ts'], startMs ~/ 1000);
      // The last frame arrives at 19.8 s; coverage stores whole epoch seconds.
      expect(rows.single['end_ts'], startMs ~/ 1000 + 19);
      expect(rows.single['steps'], greaterThan(0));
    }));

    // WHY: a calibration read can resume after Delete everything has wiped.
    // catches: checking reset only before the read, or outside the commit gate.
    test('pre-reset live finalization cannot restore deleted step rows',
        syncCase((rig, timers) async {
      const startMs = 1786233600000;
      for (var frame = 0; frame < 100; frame++) {
        rig.app.debugFeedLiveAccel([
          for (var i = 0; i < 20; i++)
            1 + 0.45 * math.sin(2 * math.pi * 2 * (frame * 20 + i) / 100),
        ], atMs: startMs + frame * 200, recTs: startMs ~/ 1000);
      }
      final db = await LocalDb.instance;
      final entered = Completer<void>();
      final release = Completer<void>();
      rig.app.debugReadLiveStepCalibration = () async {
        final rows = await LocalDb.liveStepCalibrationRuns();
        entered.complete();
        await release.future;
        return rows;
      };
      final finalizing = rig.app.debugFinalizeLivePedometer();
      await entered.future;
      ResetGate.enter();
      await LocalDb.wipeAll();
      ResetGate.leave();
      release.complete();
      await finalizing;
      expect(await db.query('live_coverage'), isEmpty);
      // Positive control: a new session still banks real measured steps.
      await LocalDb.addLiveCoverage(1786233600, 1786233660, 80, '2026-08-09');
      expect(await LocalDb.liveStepsForDay('2026-08-09'), 80);
    }));

    // WHY: replacement suppresses disconnect callbacks, but traces are per band.
    // catches: preserving primary samples at the identity reset boundary.
    test('replacement clears only the old primary live HR trace',
        syncCase((rig, timers) async {
      rig.app.debugFeedEngineState('', DeviceState()
        ..connection = 'connected' ..liveHr = 61 ..liveHrAt = 1786233600000);
      rig.app.debugFeedEngineState('ring', DeviceState()
        ..connection = 'connected' ..liveHr = 72 ..liveHrAt = 1786233600000);
      expect(rig.app.liveHrTrace(''), [61]);
      expect(rig.app.liveHrTrace('ring'), [72]);
      await rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
      expect(rig.app.liveHrTrace(''), isEmpty);
      expect(rig.app.liveHrTrace('ring'), [72]);
      rig.app.debugFeedEngineState('', rig.engine.state
        ..liveHr = 84 ..liveHrAt = 1786233601000);
      expect(rig.app.liveHrTrace(''), [84]);
    }));

    // WHY: MG's saved ECG remains available while its radio is absent.
    // catches: resetting pairedIsMaverick on a failed replacement rollback.
    test('failed replacement restores the absent old MG identity',
        syncCase((rig, timers) async {
      rig.app.pairedIsMaverick = true;
      rig.engine.connectScript.addAll([false, false]);
      await expectLater(rig.app.replaceWith(BluetoothDevice.fromId(replacementId)),
          throwsA(isA<Exception>()));
      expect(rig.app.paired?.remoteId, kRemoteId);
      expect(rig.app.pairedIsMaverick, isTrue);
    }));

    for (final success in [true, false]) {
      // WHY: the epoch and confirmation describe a physical band's arm;
      // a new band must receive its own write, and failure keeps the old arm.
      // catches: clearing only RAM, or clearing before replacement commits.
      test('replacement alarm ownership follows commit (success=$success)',
          syncCase((rig, timers) async {
        await rig.openAndSettle();
        final tomorrow = DateTime.now().add(const Duration(days: 1));
        await rig.app.setScheduleDay(weekday: tomorrow.weekday - 1,
            hour: 7, minute: 0, enabled: true);
        final epoch = rig.app.alarmEpoch;
        expect(epoch, isNotNull);
        expect(rig.app.alarmConfirmed, isTrue);
        final schedule = await LocalDb.alarmScheduleRows();
        rig.engine.events.clear();
        rig.engine.connectScript.addAll(success ? [true] : [false, false]);
        if (success) {
          await rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
          expect(rig.engine.count('armAlarm'), greaterThanOrEqualTo(1),
              reason: 'the same next occurrence must be written to the new band');
        } else {
          await expectLater(rig.app.replaceWith(BluetoothDevice.fromId(replacementId)),
              throwsA(isA<Exception>()));
          expect(rig.app.alarmEpoch, epoch);
          expect(rig.app.alarmConfirmed, isTrue);
          expect((await SharedPreferences.getInstance()).getInt('alarm_epoch'), epoch);
        }
        expect(await LocalDb.alarmScheduleRows(), schedule);
      }));
    }

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

    test('a replacement that fails keeps the old band\'s saved name',
        syncCase((rig, timers) async {
      // WHY: the name is what the old band is shown under until a
      // replacement commits; wiping it first left the band nameless.
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await Prefs.ensureLoaded();
      Prefs.setString('band.strap_name', 'Old Strap');
      rig.engine.connectScript.add(StateError('bootstrap refused'));
      await expectLater(rig.app.replaceWith(BluetoothDevice.fromId(replacementId)),
          throwsA(isA<Object>()));
      expect(Prefs.getString('band.strap_name', ''), 'Old Strap');
    }));

    test('a committed replacement clears the old band\'s saved name',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await Prefs.ensureLoaded();
      Prefs.setString('band.strap_name', 'Old Strap');
      await rig.app.replaceWith(BluetoothDevice.fromId(replacementId));
      expect((await PairedDevice.load())?.remoteId, replacementId);
      expect(Prefs.getString('band.strap_name', ''), '');
    }));

    test('replacing a band with itself says so and changes nothing',
        syncCase((rig, timers) async {
      await PairedDevice.save(kRemoteId, kSerial, generation: 'gen4');
      await Prefs.ensureLoaded();
      Prefs.setString('band.strap_name', 'Old Strap');
      await expectLater(rig.app.replaceWith(BluetoothDevice.fromId(kRemoteId)),
          throwsA(isA<SameBandSelectedException>()));
      expect((await PairedDevice.load())?.remoteId, kRemoteId);
      expect(Prefs.getString('band.strap_name', ''), 'Old Strap');
      expect(rig.engine.events.where((e) => e.startsWith('connect:')), isEmpty);
    }));

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
  _HeldPreferences(this.delegate, {this.key = 'paired_serial'});
  final String key;
  final SharedPreferencesStorePlatform delegate;
  final entered = Completer<void>();
  final release = Completer<void>();
  bool held = false;
  Future<bool> write(String key, Future<bool> Function() action) async {
    if (!held && key == 'flutter.${this.key}') {
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

// Emulate disk retaining the epoch after a platform removal failure, including
// another reader refreshing the process cache before replacement resumes.
class _AlarmRemoveFailure extends SharedPreferencesStorePlatform {
  _AlarmRemoveFailure(this.delegate, this.throws);
  final SharedPreferencesStorePlatform delegate;
  final bool throws;
  @override
  Future<Map<String, Object>> getAll() => delegate.getAll();
  @override
  Future<bool> clear() => delegate.clear();
  @override
  Future<bool> remove(String key) async {
    if (key == 'flutter.alarm_epoch') {
      await (await SharedPreferences.getInstance()).reload();
      if (throws) throw StateError('epoch removal failed');
      return false;
    }
    return delegate.remove(key);
  }
  @override
  Future<bool> setValue(String type, String key, Object value) =>
      delegate.setValue(type, key, value);
}

// A store that lets a whole reset (enter + leave) complete inside one write.
class _ResetDuring extends SharedPreferencesStorePlatform {
  _ResetDuring(this.delegate, this.key);
  final SharedPreferencesStorePlatform delegate;
  final String key;
  var _done = false;
  @override
  Future<Map<String, Object>> getAll() => delegate.getAll();
  @override
  Future<bool> clear() => delegate.clear();
  @override
  Future<bool> remove(String key) => delegate.remove(key);
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (!_done && key == this.key) {
      _done = true;
      ResetGate.enter();
      ResetGate.leave();
    }
    return delegate.setValue(type, key, value);
  }
}
