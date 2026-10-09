// AppState's live-frame router: high-rate frames (0x28 / 0x2B / 0x33) are
// RAM-only (AGENTS section 3.14), never advance the stored-data frontier, and
// feed the live pedometer that a gait workout reads. Frames travel the real
// engine immediate-frame path through the rig except where a test calls
// debugOnLiveFrame directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show BandProfile;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_state_live_harness.dart';

const _db = 'app_state_live_frames.db';

Future<Set<String>> _prefKeys() async =>
    (await SharedPreferences.getInstance()).getKeys();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => liveDbSetUp(_db));
  tearDownAll(() => liveDbTearDown(_db));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  void flood(LiveRig rig, {required bool gen5}) {
    for (var i = 0; i < 5; i++) {
      rig.feed(hr28Inner(hr: 60 + i, rr: [800 + i], ts: nowSec() + i));
      if (gen5) {
        rig.feed(r21LiveInner());
      } else {
        rig.feed(imu33Inner());
        rig.feed(r10LiveInner());
      }
    }
  }

  for (final gen5 in [true, false]) {
    final name = gen5 ? 'gen5' : 'gen4';
    test('a flood of live frames writes no row and no preference and leaves '
        'the data frontier alone ($name)', () async {
      final rig = LiveRig(band: gen5 ? BandProfile.gen5 : BandProfile.gen4);
      addTearDown(rig.dispose);
      await LocalDb.instance;
      // The once-only alert-prefs migration writes its blob on the first read,
      // whoever makes it; take that out of the baseline.
      await NotificationPrefs.load();
      await settleMs(300);
      final rows = await dbChanges();
      final prefs = await _prefKeys();
      final cursor = await LocalDb.getCursorInt('rec_ts_hw');
      rig.app.retainLiveHrView();
      await rig.settle();
      flood(rig, gen5: gen5);
      rig.app.releaseLiveHrView();
      await rig.settle();
      await settleMs(100);
      expect(await dbChanges(), rows);
      expect(await _prefKeys(), prefs);
      expect(await LocalDb.getCursorInt('rec_ts_hw'), cursor);
      expect(rig.app.lastRecordAt, isNull,
          reason: 'live frames carry "now"; only stored records move it');
    });
  }

  test('a flood straight into a bare forTesting app writes nothing',
      () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await LocalDb.instance;
    await settleMs(100);
    final rows = await dbChanges();
    for (var i = 0; i < 5; i++) {
      app.debugOnLiveFrame(0x28, hexOf(hr28Inner(rr: [800 + i])), null);
      app.debugOnLiveFrame(0x2B, hexOf(r21LiveInner()), 1790000000);
      app.debugOnLiveFrame(0x33, hexOf(imu33Inner()), 1790000000);
      app.debugOnLiveFrame(0x2B, hexOf(r10LiveInner()), null);
    }
    await settleMs(100);
    expect(await dbChanges(), rows);
    expect(app.lastRecordAt, isNull);
  });

  group('garbage in', () {
    test('a frame that does not decode is dropped without throwing', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(() => app.debugOnLiveFrame(0x28, 'zz', 1), returnsNormally);
      expect(() => app.debugOnLiveFrame(0x2B, '', null), returnsNormally);
      expect(() => app.debugOnLiveFrame(0x2B, '2b', null), returnsNormally);
      expect(() => app.debugOnLiveFrame(0x33, '33', 5), returnsNormally);
    });
  });

  group('notifyListeners', () {
    test('heart-rate frames never tick AppState', () {
      final rig = LiveRig();
      addTearDown(rig.dispose);
      final ticks = TickCounter(rig.app);
      addTearDown(ticks.stop);
      for (var i = 0; i < 5; i++) {
        rig.feed(hr28Inner(hr: 60 + i, rr: [800 + i], ts: nowSec() + i));
      }
      expect(ticks.ticks, 0);
    });

    test('IMU frames tick AppState through the live pedometer, throttled to '
        'one per second of ingest time', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final ticks = TickCounter(app);
      addTearDown(ticks.stop);
      for (var i = 0; i < 5; i++) {
        app.debugOnLiveFrame(0x2B, hexOf(r21LiveInner()), null);
      }
      expect(ticks.ticks, 1, reason: 'five frames in one instant: one tick');
    });

    test('debugFeedLiveAccel: the pedometer tick follows the supplied clock',
        () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final ticks = TickCounter(app);
      addTearDown(ticks.stop);
      final mags = List<double>.filled(10, 1.0);
      const t0 = 1790000000000;
      app.debugFeedLiveAccel(mags, atMs: t0);
      app.debugFeedLiveAccel(mags, atMs: t0 + 500);
      expect(ticks.ticks, 1);
      app.debugFeedLiveAccel(mags, atMs: t0 + 1000);
      expect(ticks.ticks, 2);
    });
  });

  group('couplings that stay with the frame router', () {
    test('a live 0x33 frame feeds the live pedometer: a gait workout goes '
        'from unmeasured to a measured zero', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.startWorkout(type: 'running');
      expect(app.workoutStepsMeasured, isNull);
      app.debugOnLiveFrame(
          0x33, hexOf(imu33Inner(ax: 0, ay: 0, az: 4096)), 1790000000);
      expect(app.workoutStepsMeasured, 0,
          reason: 'accel arrived, no steps in it: measured zero, not null');
      await app.stopWorkout();
      await settleMs(300);
    });

    test('the same frame through the engine path reaches the pedometer',
        () async {
      final rig = LiveRig(band: BandProfile.gen4);
      addTearDown(rig.dispose);
      rig.app.startWorkout(type: 'running');
      expect(rig.app.workoutStepsMeasured, isNull);
      rig.feed(imu33Inner(ax: 0, ay: 0, az: 4096));
      expect(rig.app.workoutStepsMeasured, 0);
      await rig.app.stopWorkout();
      await settleMs(300);
    });

    test('a non-gait workout is never billed pedometer samples', () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.startWorkout(type: 'Strength');
      app.debugOnLiveFrame(0x33, hexOf(imu33Inner()), 1790000000);
      expect(app.workoutStepsMeasured, isNull);
      await app.stopWorkout();
      await settleMs(300);
    });

    test('frames with no workout leave the workout steps absent', () {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.debugOnLiveFrame(0x33, hexOf(imu33Inner()), 1790000000);
      expect(app.workoutStepsMeasured, isNull);
    });
  });
}
