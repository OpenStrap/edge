// The live-stream owner set AppState hands the engine (discussion #287): which
// feature states own the realtime-HR and IMU streams, and that the owner set
// is already updated at the moment the engine is nudged.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const name = 'app_state_live_owners_test.db';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = name;
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });

  LiveWorkoutState workout(String type) => LiveWorkoutState(
        startTime: DateTime.now(),
        targetKcal: 0,
        type: type,
      );

  test('a fresh foreground AppState owns nothing but "foreground"', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final o = app.debugLiveOwners;
    expect(o.foreground, isTrue);
    expect(o.visibleLiveHrView, isFalse);
    expect(o.activeWorkout, isFalse);
    expect(o.foregroundGaitWorkout, isFalse);
    expect(o.breathing, isFalse);
    expect(o.movementSampling, isFalse);
    expect(o.passiveStrapSteps, isFalse, reason: 'off by default (#287)');
  });

  test('a gait workout owns IMU in the foreground; a non-gait one does not', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.activeWorkout = workout('running');
    expect(app.debugLiveOwners.activeWorkout, isTrue);
    expect(app.debugLiveOwners.foregroundGaitWorkout, isTrue);
    app.activeWorkout = workout('Strength');
    expect(app.debugLiveOwners.activeWorkout, isTrue);
    expect(app.debugLiveOwners.foregroundGaitWorkout, isFalse);
    app.activeWorkout = workout('Trail Running'.toLowerCase().replaceAll(' ', '_'));
    expect(app.debugLiveOwners.foregroundGaitWorkout, isTrue);
  });

  test('backgrounding keeps the workout\'s HR ownership and drops its IMU', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.activeWorkout = workout('walking');
    await app.pauseForBackground();
    final o = app.debugLiveOwners;
    expect(o.foreground, isFalse);
    expect(o.activeWorkout, isTrue);
    expect(o.foregroundGaitWorkout, isFalse,
        reason: 'background IMU is not promised until measured');
  });

  test('a breathing window or session owns HR; neither, nothing', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.breathingWindowOpen = true;
    expect(app.debugLiveOwners.breathing, isTrue);
    app.breathingActive = true;
    app.breathingWindowOpen = false;
    expect(app.debugLiveOwners.breathing, isTrue);
    app.breathingActive = false;
    expect(app.debugLiveOwners.breathing, isFalse);
  });

  test('live-HR views are counted: the last one to leave releases HR', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.retainLiveHrView();
    app.retainLiveHrView();
    app.releaseLiveHrView();
    expect(app.debugLiveOwners.visibleLiveHrView, isTrue);
    app.releaseLiveHrView();
    expect(app.debugLiveOwners.visibleLiveHrView, isFalse);
    app.releaseLiveHrView(); // an extra release cannot go negative
    app.retainLiveHrView();
    expect(app.debugLiveOwners.visibleLiveHrView, isTrue);
  });

  test('a mounted live-HR view does not own HR while backgrounded', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.retainLiveHrView();
    await app.pauseForBackground();
    expect(app.debugLiveOwners.visibleLiveHrView, isFalse,
        reason: 'the route survives backgrounding; the stream must not');
  });

  test('starting a workout offline still clears the sticky radio fallback', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.engine.state.standardHrFallback = true;
    app.startWorkout(type: 'running');
    await app.engine.reconcileLiveStreams();
    expect(app.engine.state.standardHrFallback, isFalse);
    await app.stopWorkout();
  });

  test('a movement-sampling window is an owner only while open', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.setMovementSamplingWindow(true);
    expect(app.debugLiveOwners.movementSampling, isTrue);
    app.setMovementSamplingWindow(false);
    expect(app.debugLiveOwners.movementSampling, isFalse);
  });

  test('stopWorkout ends the workout\'s ownership', () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.activeWorkout = workout('running');
    await app.stopWorkout();
    expect(app.debugLiveOwners.activeWorkout, isFalse);
  });

  test('startWorkout: the engine sees the workout on the very first pass', () async {
    // The engine reads owners synchronously when nudged, so the nudge has to
    // come AFTER `activeWorkout` is assigned — otherwise the first pass sees
    // no workout, and nothing arms until a keep-alive tick.
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final opcodes = <int>[];
    app.engine.debugInstallFakeLink(
      band: BandProfile.gen5,
      listening: true,
      onWrite: (Uint8List frame) async {
        final op = parseFrame(frame, profile: BandProfile.gen5)!.inner[2];
        // Only the live toggles: a READY link also carries stopWorkout's
        // resync burst, which is not what this test is about.
        if (op == Cmd.toggleRealtimeHr || op == Cmd.toggleImuMode) opcodes.add(op);
        return true;
      },
    );
    app.startWorkout(type: 'running');
    await app.engine.reconcileLiveStreams(); // the barrier for the nudged pass
    expect(opcodes, [Cmd.toggleRealtimeHr, Cmd.toggleImuMode]);
    await app.stopWorkout();
    await app.engine.reconcileLiveStreams();
    expect(opcodes.sublist(2), [Cmd.toggleImuMode, Cmd.toggleRealtimeHr]);
  });
}
