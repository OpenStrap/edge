// Lifetime and notification footprint of AppState's gesture machinery:
// the settings object is one instance for the whole lifetime and is disposed
// with AppState, AppState attaches no listener of its own to it, and a tap
// does not notify AppState except through the workout it starts or stops.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'app_state_gesture_lifecycle.db';

// ignore: invalid_use_of_protected_member
bool _hasListeners(Listenable n) => (n as ChangeNotifier).hasListeners;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ActionChannel channel;
  late HapticSpy haptics;
  setUpAll(() => gestureDbSetUp(_db));
  tearDownAll(() => gestureDbTearDown(_db));
  setUp(() {
    BleEngine.resetBandClaimForTest();
    channel = ActionChannel();
    haptics = HapticSpy();
  });
  tearDown(() async {
    await settleMs(150);
    channel.dispose();
    haptics.dispose();
    BleEngine.resetBandClaimForTest();
  });

  GestureRig newRig() {
    final rig = GestureRig();
    addTearDown(rig.dispose);
    return rig;
  }

  group('identity and disposal', () {
    test('gestureSettings is one GestureSettings for the whole lifetime, '
        'whatever is mapped or tapped', () async {
      final rig = newRig();
      final GestureSettings settings = rig.app.gestureSettings;
      await rig.map(DeviceAction.torch);
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty);
      expect(identical(rig.app.gestureSettings, settings), isTrue);
      expect(settings.doubleTap, DeviceAction.torch);
    });

    test('a fresh app maps nothing and knows only "none" until bootstrap',
        () {
      final rig = newRig();
      expect(rig.app.gestureSettings.doubleTap, DeviceAction.none);
      expect(rig.app.gestureSettings.supported, {DeviceAction.none});
      expect(rig.app.gestureSettings.hasActiveMapping, isFalse);
    });

    test('AppState attaches no listener of its own to the settings, before or '
        'after taps', () async {
      final rig = newRig();
      expect(_hasListeners(rig.app.gestureSettings), isFalse);
      await rig.map(DeviceAction.torch);
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty);
      expect(_hasListeners(rig.app.gestureSettings), isFalse);
    });

    test('dispose disposes the settings object', () async {
      final rig = newRig();
      final settings = rig.app.gestureSettings;
      await rig.dispose();
      expect(() => settings.addListener(() {}), throwsFlutterError);
    });
  });

  group('notifications', () {
    test('changing the mapping notifies the settings, never AppState',
        () async {
      final rig = newRig();
      final ticks = TickCounter(rig.app);
      addTearDown(ticks.stop);
      var settingsTicks = 0;
      void onSettings() => settingsTicks++;
      rig.app.gestureSettings.addListener(onSettings);
      addTearDown(() => rig.app.gestureSettings.removeListener(onSettings));
      await rig.map(DeviceAction.torch);
      await rig.map(DeviceAction.torch); // unchanged: no tick
      await rig.map(DeviceAction.logWater);
      expect(settingsTicks, 2);
      expect(ticks.ticks, 0);
    });

    test('a native action tap notifies nobody', () async {
      final rig = newRig();
      await rig.map(DeviceAction.torch);
      final ticks = TickCounter(rig.app);
      addTearDown(ticks.stop);
      var settingsTicks = 0;
      void onSettings() => settingsTicks++;
      rig.app.gestureSettings.addListener(onSettings);
      addTearDown(() => rig.app.gestureSettings.removeListener(onSettings));
      rig.doubleTap();
      await until(() => channel.performed.isNotEmpty);
      await settleMs(100);
      expect((ticks.ticks, settingsTicks), (0, 0));
    });

    test('the journal actions notify nobody', () async {
      for (final a in [DeviceAction.logWater, DeviceAction.markMoment]) {
        final rig = GestureRig();
        rig.app.repo = FakeJournalRepo();
        await rig.map(a);
        final ticks = TickCounter(rig.app);
        rig.doubleTap();
        await until(() => haptics.calls.isNotEmpty, what: a.id);
        await settleMs(100);
        expect(ticks.ticks, 0, reason: a.id);
        ticks.stop();
        haptics.calls.clear();
        await rig.dispose();
        BleEngine.resetBandClaimForTest();
      }
    });

    test('the workout toggle notifies only through the workout it starts and '
        'ends', () async {
      final rig = newRig();
      await rig.map(DeviceAction.workoutToggle);
      final ticks = TickCounter(rig.app);
      addTearDown(ticks.stop);
      rig.doubleTap();
      await until(() => rig.app.activeWorkout != null);
      await settleMs(150);
      final afterStart = ticks.ticks;
      expect(afterStart, greaterThan(0));
      rig.advance(const Duration(seconds: 3));
      rig.doubleTap();
      await until(() => rig.app.activeWorkout == null);
      await settleMs(150);
      expect(ticks.ticks, greaterThan(afterStart));
    });
  });
}
