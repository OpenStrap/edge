// The band double tap mapped to "workout toggle": with no workout live it
// starts a type 'other' one, otherwise it ends the active one. The repository
// seam is asked first (start) and after the local stop (end) and its failures
// are swallowed; a medium haptic closes a clean toggle. Driven by a real strap
// event through the engine, like the other gesture tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/device_action.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'app_state_gesture_workout_toggle.db';

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
    // A workout's live row and the rig's device rows are fire-and-forget.
    await settleMs(200);
    channel.dispose();
    haptics.dispose();
    BleEngine.resetBandClaimForTest();
  });

  Future<GestureRig> newRig({FakeJournalRepo? repo}) async {
    final rig = GestureRig();
    addTearDown(rig.dispose);
    if (repo != null) rig.app.repo = repo;
    await rig.map(DeviceAction.workoutToggle);
    return rig;
  }

  Future<void> tap(GestureRig rig, bool Function() done) async {
    rig.advance(const Duration(seconds: 3));
    rig.doubleTap();
    await until(done);
    await settleMs(150);
  }

  Future<void> sessionLanded(String id) async {
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(end)) {
      if (await LocalDb.session(id) != null) return;
      await settleMs(10);
    }
  }

  test('with no repo: a tap starts a type-other workout with a generated id, '
      'the next tap ends and saves it', () async {
    final rig = await newRig();
    await tap(rig, () => rig.app.activeWorkout != null);
    final w = rig.app.activeWorkout!;
    expect(w.type, 'other');
    expect(w.workoutId, 'w${w.startTime.millisecondsSinceEpoch}');
    expect(haptics.calls, ['HapticFeedbackType.mediumImpact']);
    expect(rig.app.debugLiveOwners.activeWorkout, isTrue);
    await tap(rig, () => rig.app.activeWorkout == null);
    expect((await LocalDb.session(w.workoutId!))!['status'], 'done');
    expect(haptics.calls, hasLength(2));
    expect(channel.performed, isEmpty);
  });

  test('with a repo: the repo is asked to start and its workout id is used; '
      'the end is reported back to it after the local stop', () async {
    final repo = FakeJournalRepo();
    final rig = await newRig(repo: repo);
    await tap(rig, () => rig.app.activeWorkout != null);
    expect(rig.app.activeWorkout!.workoutId, 'srv-1');
    expect(repo.calls, ['start:other']);
    await tap(rig, () => rig.app.activeWorkout == null);
    expect(repo.calls, ['start:other', 'end:srv-1']);
    expect((await LocalDb.session('srv-1'))!['status'], 'done');
  });

  test('a repo that fails to start still starts the workout locally; one '
      'that fails to end is swallowed and the workout still ended', () async {
    final repo = FakeJournalRepo()
      ..startWorkoutThrows = StateError('no seam')
      ..endWorkoutThrows = StateError('no seam');
    final rig = await newRig(repo: repo);
    await tap(rig, () => rig.app.activeWorkout != null);
    final w = rig.app.activeWorkout!;
    expect(w.workoutId, 'w${w.startTime.millisecondsSinceEpoch}');
    await tap(rig, () => rig.app.activeWorkout == null);
    expect(repo.calls, ['start:other', 'end:${w.workoutId}']);
    expect(rig.app.logLines.where((l) => l.contains('workout toggle failed')),
        isEmpty);
    expect(haptics.calls, hasLength(2));
  });

  test('the toggle ends a workout started from the screen too, whatever its '
      'type', () async {
    final rig = await newRig();
    rig.app.startWorkout(workoutId: 'tg-screen', type: 'running');
    await sessionLanded('tg-screen');
    await tap(rig, () => rig.app.activeWorkout == null);
    final row = (await LocalDb.session('tg-screen'))!;
    expect(row['type'], 'running');
    expect(row['status'], 'done');
  });

  test('a repo without a workout id in its answer starts locally under a '
      'generated id', () async {
    final repo = FakeJournalRepo()..startWorkoutAnswer = {};
    final rig = await newRig(repo: repo);
    await tap(rig, () => rig.app.activeWorkout != null);
    final w = rig.app.activeWorkout!;
    expect(w.workoutId, 'w${w.startTime.millisecondsSinceEpoch}');
    await rig.app.stopWorkout();
  });

  test('a tap that ends a workout whose save fails logs the failure, plays '
      'no haptic, and leaves the workout live', () async {
    final rig = await newRig();
    rig.app.startWorkout(workoutId: 'tg-fail', type: 'strength');
    await sessionLanded('tg-fail');
    final db = await LocalDb.instance;
    await db.execute('ALTER TABLE sessions RENAME TO sessions_hidden');
    try {
      rig.advance(const Duration(seconds: 3));
      rig.doubleTap();
      await until(() => rig.app.logLines
          .any((l) => l.startsWith('[gesture] workout toggle failed')));
      await settleMs(100);
      expect(haptics.calls, isEmpty);
      expect(rig.app.activeWorkout, isNotNull);
    } finally {
      await db.execute('ALTER TABLE sessions_hidden RENAME TO sessions');
    }
    await rig.app.stopWorkout();
    expect((await LocalDb.session('tg-fail'))!['status'], 'done');
  });
}
