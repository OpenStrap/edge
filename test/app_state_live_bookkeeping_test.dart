// AppState's live-stream owner bookkeeping: mounted live-HR views, the
// movement-sampling window, background, and what each change asks of the
// engine. The engine reads the owner set through the callback AppState hands
// it; the set must already be current when the engine is nudged, and a change
// that did not happen must not nudge.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart' show LiveStreamOwners;
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_state_live_harness.dart';

const _hr = Cmd.toggleRealtimeHr;
const _imu = Cmd.toggleImuMode;

const _db = 'app_state_live_bookkeeping.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => liveDbSetUp(_db));
  tearDownAll(() => liveDbTearDown(_db));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  LiveWorkoutState workout(String type) =>
      LiveWorkoutState(startTime: DateTime.now(), targetKcal: 0, type: type);

  void expectSame(LiveStreamOwners a, LiveStreamOwners b, String when) {
    expect(a.visibleLiveHrView, b.visibleLiveHrView, reason: when);
    expect(a.activeWorkout, b.activeWorkout, reason: when);
    expect(a.foregroundGaitWorkout, b.foregroundGaitWorkout, reason: when);
    expect(a.breathing, b.breathing, reason: when);
    expect(a.movementSampling, b.movementSampling, reason: when);
    expect(a.passiveStrapSteps, b.passiveStrapSteps, reason: when);
    expect(a.foreground, b.foreground, reason: when);
  }

  group('the owner set the engine reads', () {
    test('the engine callback and debugLiveOwners agree through every owner '
        'change', () async {
      final rig = LiveRig();
      addTearDown(rig.dispose);
      void same(String when) =>
          expectSame(rig.engine.liveOwners!(), rig.app.debugLiveOwners, when);

      same('fresh');
      rig.app.retainLiveHrView();
      same('viewer');
      expect(rig.app.debugLiveOwners.visibleLiveHrView, isTrue);
      rig.app.setMovementSamplingWindow(true);
      same('sampling');
      expect(rig.app.debugLiveOwners.movementSampling, isTrue);
      rig.app.breathingActive = true;
      same('breathing session');
      expect(rig.app.debugLiveOwners.breathing, isTrue);
      rig.app.breathingActive = false;
      rig.app.breathingWindowOpen = true;
      same('breathing window');
      expect(rig.app.debugLiveOwners.breathing, isTrue);
      rig.app.breathingWindowOpen = false;
      rig.app.activeWorkout = workout('running');
      same('gait workout');
      expect(rig.app.debugLiveOwners.foregroundGaitWorkout, isTrue);
      await rig.app.pauseForBackground();
      same('background');
      final o = rig.app.debugLiveOwners;
      expect(o.foreground, isFalse);
      expect(o.visibleLiveHrView, isFalse,
          reason: 'the route survives backgrounding; the stream must not');
      expect(o.foregroundGaitWorkout, isFalse);
      expect(o.activeWorkout, isTrue);
      expect(o.movementSampling, isTrue,
          reason: 'the window flag is its own owner input');
      await rig.settle();
    });

    test('a fresh app with no frames owns nothing but "foreground", and '
        'passive strap steps stay off', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final o = app.debugLiveOwners;
      expect(o.foreground, isTrue);
      expect(o.visibleLiveHrView, isFalse);
      expect(o.activeWorkout, isFalse);
      expect(o.foregroundGaitWorkout, isFalse);
      expect(o.breathing, isFalse);
      expect(o.movementSampling, isFalse);
      expect(o.passiveStrapSteps, isFalse);
    });

    test('the default forTesting engine reads the same callback', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expectSame(app.engine.liveOwners!(), app.debugLiveOwners, 'fresh');
      app.retainLiveHrView();
      app.setMovementSamplingWindow(true);
      expectSame(app.engine.liveOwners!(), app.debugLiveOwners, 'owned');
      expect(app.engine.liveOwners!().visibleLiveHrView, isTrue);
      expect(app.engine.liveOwners!().movementSampling, isTrue);
    });
  });

  group('live-HR views', () {
    test('counted: the last release drops the owner, and surplus releases '
        'cannot go negative', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.retainLiveHrView();
      app.retainLiveHrView();
      app.releaseLiveHrView();
      expect(app.debugLiveOwners.visibleLiveHrView, isTrue);
      app.releaseLiveHrView();
      expect(app.debugLiveOwners.visibleLiveHrView, isFalse);
      app.releaseLiveHrView();
      app.releaseLiveHrView();
      app.retainLiveHrView();
      expect(app.debugLiveOwners.visibleLiveHrView, isTrue,
          reason: 'one retain after surplus releases is one viewer');
      app.releaseLiveHrView();
      expect(app.debugLiveOwners.visibleLiveHrView, isFalse);
    });

    test('retain and release never notifyListeners; each nudges the engine '
        'and HR goes on, then off', () async {
      final rig = LiveRig();
      addTearDown(rig.dispose);
      final ticks = TickCounter(rig.app);
      addTearDown(ticks.stop);
      rig.app.retainLiveHrView();
      await rig.settle();
      expect(rig.ops, [(_hr, 1)]);
      rig.writes.clear();
      rig.app.releaseLiveHrView();
      await rig.settle();
      expect(rig.ops, [(_hr, 0)]);
      expect(ticks.ticks, 0);
    });

    test('a second viewer is not a second arming, and one viewer leaving '
        'keeps HR on', () async {
      final rig = LiveRig();
      addTearDown(rig.dispose);
      rig.app.retainLiveHrView();
      rig.app.retainLiveHrView();
      await rig.settle();
      expect(rig.ops, [(_hr, 1)]);
      rig.app.releaseLiveHrView();
      await rig.settle();
      expect(rig.ops, [(_hr, 1)], reason: 'one viewer still holds HR');
    });

    test('a release with no viewer still nudges the engine, and writes '
        'nothing', () async {
      final rig = LiveRig();
      addTearDown(rig.dispose);
      await rig.settle();
      final before = rig.ownerReads;
      rig.app.releaseLiveHrView();
      await rig.settle();
      expect(rig.ownerReads, greaterThan(before));
      expect(rig.writes, isEmpty);
      expect(rig.app.debugLiveOwners.visibleLiveHrView, isFalse);
    });

    test('a viewer mounted before backgrounding loses HR on background',
        () async {
      final rig = LiveRig();
      addTearDown(rig.dispose);
      rig.app.retainLiveHrView();
      await rig.settle();
      expect(rig.ops, [(_hr, 1)]);
      rig.writes.clear();
      await rig.app.pauseForBackground();
      await rig.settle();
      expect(rig.app.debugLiveOwners.visibleLiveHrView, isFalse);
      expect(rig.ops, [(_hr, 0)]);
    });
  });

  group('movement-sampling window', () {
    test('open asks the engine for IMU only; closing turns it off', () async {
      final rig = LiveRig();
      addTearDown(rig.dispose);
      rig.app.setMovementSamplingWindow(true);
      await rig.settle();
      expect(rig.ops, [(_imu, 1)]);
      rig.writes.clear();
      rig.app.setMovementSamplingWindow(false);
      await rig.settle();
      expect(rig.ops, [(_imu, 0)]);
    });

    test('setting the state it is already in does not nudge the engine and '
        'does not notify', () async {
      final rig = LiveRig();
      addTearDown(rig.dispose);
      await rig.settle();
      final ticks = TickCounter(rig.app);
      addTearDown(ticks.stop);
      final reads = rig.ownerReads;
      rig.app.setMovementSamplingWindow(false);
      await rig.settle();
      expect(rig.ownerReads, reads + 1,
          reason: 'only the settle barrier itself read the owners');
      rig.app.setMovementSamplingWindow(true);
      await rig.settle();
      final afterOpen = rig.ownerReads;
      rig.app.setMovementSamplingWindow(true);
      await rig.settle();
      expect(rig.ownerReads, afterOpen + 1,
          reason: 'a repeated open is not a nudge');
      expect(rig.ops, [(_imu, 1)], reason: 'one arming on the wire');
      expect(ticks.ticks, 0);
    });

    test('the window and a viewer are independent owners: closing the window '
        'keeps HR, releasing the viewer keeps IMU', () async {
      final rig = LiveRig();
      addTearDown(rig.dispose);
      rig.app.retainLiveHrView();
      rig.app.setMovementSamplingWindow(true);
      await rig.settle();
      expect(rig.ops, unorderedEquals([(_hr, 1), (_imu, 1)]));
      rig.writes.clear();
      rig.app.setMovementSamplingWindow(false);
      await rig.settle();
      expect(rig.ops, [(_imu, 0)]);
      rig.writes.clear();
      rig.app.releaseLiveHrView();
      await rig.settle();
      expect(rig.ops, [(_hr, 0)]);
    });
  });

  group('workout, breathing and background as owners', () {
    test('a gait workout owns HR and IMU in the foreground; backgrounding '
        'keeps HR and drops IMU', () async {
      final rig = LiveRig();
      addTearDown(rig.dispose);
      rig.app.startWorkout(type: 'running');
      await rig.settle();
      expect(rig.ops, [(_hr, 1), (_imu, 1)]);
      rig.writes.clear();
      await rig.app.pauseForBackground();
      await rig.settle();
      expect(rig.ops, [(_imu, 0)],
          reason: 'background IMU is not promised until measured');
      expect(rig.app.debugLiveOwners.activeWorkout, isTrue);
      await rig.app.stopWorkout();
    });

    test('a non-gait workout owns HR only', () async {
      final rig = LiveRig();
      addTearDown(rig.dispose);
      rig.app.startWorkout(type: 'Strength');
      await rig.settle();
      expect(rig.ops, [(_hr, 1)]);
      expect(rig.app.debugLiveOwners.foregroundGaitWorkout, isFalse);
      await rig.app.stopWorkout();
    });

    test('a breathing window owns HR and releasing it nudges the engine',
        () async {
      final rig = LiveRig();
      addTearDown(rig.dispose);
      await rig.app.openBreathingWindow();
      await rig.settle();
      expect(rig.app.debugLiveOwners.breathing, isTrue);
      expect(rig.ops, [(_hr, 1)]);
      rig.writes.clear();
      await rig.app.closeBreathingWindow();
      await rig.settle();
      expect(rig.app.debugLiveOwners.breathing, isFalse);
      expect(rig.ops, [(_hr, 0)]);
    });
  });

  group('construction and disposal', () {
    test('building the object graph and exercising every owner method '
        'leaves no timer behind', () {
      fakeAsync((async) {
        final app = AppState.forTesting();
        app.retainLiveHrView();
        app.releaseLiveHrView();
        app.setMovementSamplingWindow(true);
        app.setMovementSamplingWindow(false);
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
        app.dispose();
      });
    });
  });
}
