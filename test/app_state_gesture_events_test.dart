// What AppState does with a live band event before and around the gesture
// dispatcher: store it, give the alarm state machine its lifecycle events,
// then hand it to the dispatcher. A data reset in flight suppresses the whole
// path, so a tap during a wipe stores nothing and runs nothing.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'app_state_gesture_events.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ActionChannel channel;
  late HapticSpy haptics;
  final originalSink = NotificationCenter.instance.presentSink;
  setUpAll(() => gestureDbSetUp(_db));
  tearDownAll(() => gestureDbTearDown(_db));
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    channel = ActionChannel();
    haptics = HapticSpy();
    // A fired alarm presents a notification; keep the OS out of it.
    NotificationCenter.instance.presentSink =
        (NotificationEvent e, {bool allowPermissionPrompt = true}) async => true;
    await (await LocalDb.instance).delete('events');
  });
  tearDown(() {
    channel.dispose();
    haptics.dispose();
    NotificationCenter.instance.presentSink = originalSink;
    BleEngine.resetBandClaimForTest();
  });

  GestureRig newRig() {
    final rig = GestureRig();
    addTearDown(rig.dispose);
    return rig;
  }

  group('persistence', () {
    test('a double tap is stored as an event of the primary device and '
        'then dispatched', () async {
      final rig = newRig();
      await rig.map(DeviceAction.torch);
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty);
      await untilEvents(1);
      final e = (await storedEvents()).single;
      expect((e.id, e.ts, e.device), (14, rig.nowSec, ''));
      expect(channel.performed, ['torch']);
    });

    test('a double tap is stored even when nothing is mapped, when it is '
        'stale, and when the debounce drops it', () async {
      final rig = newRig();
      rig.doubleTap(); // unmapped
      await rig.map(DeviceAction.torch);
      rig.doubleTapAged(const Duration(minutes: 5)); // stale
      rig.advance(const Duration(seconds: 3));
      rig.doubleTap(); // runs
      rig.doubleTap(); // debounced
      await untilEvents(4);
      expect(channel.performed, ['torch']);
      expect((await storedEvents()).map((e) => e.id), [14, 14, 14, 14]);
    });

    test('other events are stored and never dispatched', () async {
      final rig = newRig();
      await rig.map(DeviceAction.torch);
      rig.event(3);
      rig.event(9);
      await untilEvents(2);
      await settleMs(100);
      expect((await storedEvents()).map((e) => e.id), [3, 9]);
      expect(channel.performed, isEmpty);
    });
  });

  group('alarm lifecycle events share the path', () {
    test('a strap alarm-fired event (57) is stored, clears the armed alarm, '
        'and runs no gesture', () async {
      SharedPreferences.setMockInitialValues({'alarm_epoch': 1785000000});
      final rig = newRig();
      await rig.map(DeviceAction.torch);
      rig.app.device.alarmEpoch = 1785000000;
      rig.event(57);
      await untilEvents(1);
      await settleMs(50);
      expect(rig.app.alarmEpoch, isNull);
      expect(rig.app.alarmFiredAt, isNotNull);
      expect((await storedEvents()).single.id, 57);
      expect(channel.performed, isEmpty);
    });

    test('a double tap leaves the armed alarm alone', () async {
      SharedPreferences.setMockInitialValues({'alarm_epoch': 1785000000});
      final rig = newRig();
      await rig.map(DeviceAction.torch);
      rig.app.device.alarmEpoch = 1785000000;
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty);
      expect(rig.app.alarmEpoch, 1785000000);
      expect(rig.app.alarmFiredAt, isNull);
    });
  });

  group('a data reset in flight', () {
    test('stores nothing, handles no alarm event, and runs no gesture; the '
        'path reopens when the reset ends', () async {
      final rig = newRig();
      await rig.map(DeviceAction.torch);
      rig.app.device.alarmEpoch = 1785000000;
      ResetGate.enter();
      try {
        rig.doubleTap();
        rig.event(57);
        await settleMs(150);
        expect(await storedEvents(), isEmpty);
        expect(channel.performed, isEmpty);
        expect(rig.app.alarmEpoch, 1785000000,
            reason: 'the alarm handler is behind the same gate');
      } finally {
        ResetGate.leave();
      }
      rig.advance(const Duration(seconds: 3));
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty);
      await untilEvents(1);
    });

    test('a tap suppressed by a reset does not spend the debounce', () async {
      final rig = newRig();
      await rig.map(DeviceAction.torch);
      ResetGate.enter();
      try {
        rig.doubleTap();
        await settleMs(50);
      } finally {
        ResetGate.leave();
      }
      rig.doubleTap(); // same instant
      await until(() => channel.performed.isNotEmpty);
      expect(channel.performed, ['torch']);
    });
  });
}

/// Polls until [n] events are stored.
Future<void> untilEvents(int n) async {
  final end = DateTime.now().add(const Duration(seconds: 4));
  while ((await storedEvents()).length < n) {
    if (!DateTime.now().isBefore(end)) {
      throw TestFailure('fewer than $n events stored within 4 s');
    }
    await settleMs(10);
  }
}
