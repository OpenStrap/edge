// Regression tests for a batch of AppState state-machine bugs.
//
// AppState.forTesting() builds the object graph WITHOUT running _init() and
// without touching a single platform plugin, so the logic below can be driven
// directly. Each group names the bug it guards.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_app_state_regressions_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ── 1. the serial heal must never RE-PAIR a band the user just unpaired ─────
  group('healedPairing (stale engine-state callback after unpair)', () {
    test('an unpaired app is NEVER re-paired from a stale engine state', () {
      // BleEngine._teardownSession leaves state.serial/state.address set, so a
      // late onState (e.g. the reconnect loop's finally → clearReconnecting →
      // _setPhase(idle) → onState) arrives with a perfectly clean serial long
      // after unpair() ran. The old guard (`cleanSn != paired?.serial`) was
      // TRUE for paired == null and rebuilt a PairedDevice from state.address,
      // silently re-pairing the removed band and bouncing the app back to the
      // Shell.
      expect(healedPairing(null, '4C2248092'), isNull);
      expect(healedPairing(null, "Abdul's WHOOP"), isNull);
    });

    test('an EXISTING pairing still gets its junk serial healed', () {
      final healed = healedPairing(PairedDevice('r-1', '?*?*'), '4C2248092');
      expect(healed, isNotNull);
      expect(healed!.remoteId, 'r-1');
      expect(healed.serial, '4C2248092');
    });

    test('a pairing with no serial yet gets one', () {
      expect(healedPairing(PairedDevice('r-1', null), '4C2248092')?.serial,
          '4C2248092');
    });

    test('no change when the serial already matches, or the report is junk',
        () {
      expect(healedPairing(PairedDevice('r-1', '4C2248092'), '4C2248092'),
          isNull);
      expect(healedPairing(PairedDevice('r-1', '4C2248092'), '?*?*'), isNull);
      expect(healedPairing(PairedDevice('r-1', '4C2248092'), null), isNull);
      expect(healedPairing(PairedDevice('r-1', '4C2248092'), '   '), isNull);
    });

    test('the remoteId is never invented — it always comes from the pairing',
        () {
      // Even with a clean serial, an empty remoteId means there is nothing
      // legitimate to write back.
      expect(healedPairing(PairedDevice('', null), '4C2248092'), isNull);
    });
  });

  // ── 5. (removed) the step-calibration live-consumer latch ─────────────────
  // The guided calibration walk was deleted in v56 along with the 1 Hz step
  // estimator that was its only consumer, so there is no longer an arming path
  // that can latch `_hasLiveConsumer`. The spot-check and workout consumers
  // keep their own latch coverage.

  // ── 6. `busy` must not latch true forever ──────────────────────────────────
  group('openSession (busy latch)', () {
    test('unpairing while the session is opening does not wedge busy',
        () async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.paired = PairedDevice('r-1', '4C2248092');
      // Simulate the user tapping Unpair inside openSession's own resume
      // window: the first thing openSession does after flipping busy is
      // notify, and unpair() nulls `paired`.
      app.addListener(() => app.paired = null);

      // Pre-fix this THREW (`paired!` sat outside the try) and left busy true,
      // so every later openSession()/syncNow() no-opped — "Sync now" was dead
      // until the process restarted.
      await app.openSession();

      expect(app.busy, isFalse);
      expect(app.paired, isNull);
      // And the state machine is genuinely usable again.
      await app.syncNow();
      expect(app.busy, isFalse);
    });
  });

  // ── 7. the orphan-workout reconcile must not clobber a live workout ────────
  group('_reconcileOrphanedLiveWorkout (startWorkout race)', () {
    test('a workout started inside the DB round-trip is not overwritten',
        () async {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await LocalDb.putSession({
        'id': 'stale-from-a-killed-run',
        'start_ts': nowSec - 600,
        'end_ts': null,
        'type': 'other',
        'status': 'live',
        'source': 'manual',
        'created_at': (nowSec - 600) * 1000,
      });

      final app = AppState.forTesting();
      addTearDown(app.dispose);

      // Kicked unawaited from _init(), one line before `initialized = true`
      // makes the shell interactive — so the user can start a workout inside
      // the round-trip.
      final reconcile = app.debugReconcileOrphanedLiveWorkout();
      app.activeWorkout = LiveWorkoutState(
        startTime: DateTime.now(),
        targetKcal: 300,
        workoutId: 'user-just-started-this',
        type: 'run',
      );
      await reconcile;

      expect(app.activeWorkout?.workoutId, 'user-just-started-this',
          reason: 'the stale row must never replace a genuinely live workout '
              '(the old timer became unreachable and double-counted at 2 Hz)');
    });

    test('with nothing live, a recent orphan is still resumed', () async {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await LocalDb.putSession({
        'id': 'resumable',
        'start_ts': nowSec - 300,
        'end_ts': null,
        'type': 'run',
        'status': 'live',
        'source': 'manual',
        'created_at': (nowSec - 300) * 1000,
      });

      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await app.debugReconcileOrphanedLiveWorkout();
      expect(app.activeWorkout?.workoutId, 'resumable');
    });

    test('a resumed session keeps its ceiling, so the idle gate exists',
        () async {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await LocalDb.putSession({
        'id': 'resumable-gated',
        'start_ts': nowSec - 300,
        'end_ts': null,
        'type': 'run',
        'status': 'live',
        'source': 'manual',
        'created_at': (nowSec - 300) * 1000,
      });

      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.user = {'age': 30};
      await app.debugReconcileOrphanedLiveWorkout();

      expect(app.activeWorkout?.hrMax, closeTo(208.0 - 0.7 * 30, 1e-9),
          reason: 'without the ceiling the idle gate is null and '
              'WorkoutIdleWatch counts any positive reading as active — a '
              'forgotten session sitting at resting HR would never be asked '
              'about after an app restart, the exact case the watch is for');
    });

    test('a stale (past-ceiling) orphan is finalized locally but NEVER '
        'exported to Health', () async {
      // Its real end time is unknown — the reconcile stamps end_ts to
      // reconcile-time as an honest "we closed this out", not a fact. Writing
      // that fabricated span to Apple Health / Health Connect as a real
      // workout would be a lie in the user's own health records.
      const channel = MethodChannel('flutter_health');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return call.method == 'hasPermissions' ? false : true;
          });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      SharedPreferences.setMockInitialValues({kHealthSyncPref: true});

      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      const staleId = 'stale-past-ceiling';
      await LocalDb.putSession({
        'id': staleId,
        'start_ts': nowSec - 7 * 60 * 60, // 7h old, past the 6h ceiling
        'end_ts': null,
        'type': 'run',
        'status': 'live',
        'source': 'manual',
        'created_at': (nowSec - 7 * 60 * 60) * 1000,
      });

      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await app.debugReconcileOrphanedLiveWorkout();
      // exportWorkoutId is fired unawaited from the reconcile; give it a
      // chance to run before asserting nothing came through.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(calls, isEmpty,
          reason: 'a stale orphan has a fabricated end_ts and must never '
              'reach the platform health store');
      final row = await LocalDb.session(staleId);
      expect(row?['status'], 'done');
      expect(row?['end_ts'], isNotNull);
      expect(row?['end_ts_fabricated'], 1,
          reason: 'without this flag the row looks like any other finished '
              'workout and _writeOneWorkout would export it on the very next '
              'periodic exportAll pass, minutes later');
    });
  });

  // ── 9. a fired alarm must be cleared from state AND prefs ──────────────────
  group('alarm lifecycle (fired / strap-cleared)', () {
    final originalSink = NotificationCenter.instance.presentSink;
    tearDown(() => NotificationCenter.instance.presentSink = originalSink);

    Future<void> silenceOsPresent() async {
      NotificationCenter.instance.presentSink =
          (NotificationEvent e, {bool allowPermissionPrompt = true}) async =>
              true;
    }

    test('EXECUTED (event 57) clears the armed alarm and its persisted epoch',
        () async {
      SharedPreferences.setMockInitialValues({'alarm_epoch': 1785000000});
      await silenceOsPresent();
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.alarmEpoch = 1785000000;
      expect(app.alarmEpoch, 1785000000);

      app.debugHandleAlarmEvent(57);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Pre-fix this only logged + notified: alarmEpoch kept returning the past
      // epoch across relaunches (_init reloads `alarm_epoch`) and Profile's
      // "Smart alarm" row advertised a spent one-shot as the CURRENT alarm.
      expect(app.alarmEpoch, isNull);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getInt('alarm_epoch'), isNull);
      // `alarmFiredAt` had no reader in lib (alarm.dart derives its own arm
      // state from alarmConfirmed/alarmPending), so the getter is gone and
      // with it the only thing this line could assert on.
    });

    test('the app-side EXECUTED id (58) clears it too', () async {
      SharedPreferences.setMockInitialValues({'alarm_epoch': 1785000000});
      await silenceOsPresent();
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.alarmEpoch = 1785000000;

      app.debugHandleAlarmEvent(58);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(app.alarmEpoch, isNull);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getInt('alarm_epoch'), isNull);
    });

    test('the strap-driven clear (event 59) also drops the persisted epoch',
        () async {
      SharedPreferences.setMockInitialValues({'alarm_epoch': 1785000000});
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.alarmEpoch = 1785000000;

      app.debugHandleAlarmEvent(59);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(app.alarmEpoch, isNull);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getInt('alarm_epoch'), isNull,
          reason: 'state was nulled but the epoch used to stay on disk and '
              'came back on the next launch');
    });

    test('ALARM_SET (event 56) leaves the armed alarm alone', () async {
      SharedPreferences.setMockInitialValues({'alarm_epoch': 1785000000});
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.alarmEpoch = 1785000000;

      app.debugHandleAlarmEvent(56);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(app.alarmEpoch, 1785000000);
      expect(app.alarmConfirmed, isTrue);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getInt('alarm_epoch'), 1785000000);
    });
  });

  // ── 10. dispose must release EVERYTHING AppState owns ──────────────────────
  group('dispose', () {
    testWidgets('cancels every owned timer', (t) async {
      final app = AppState.forTesting();
      // _spotTimer, _breathingRecomputeTimer and _workoutTimer used to survive
      // dispose; each callback ends in notifyListeners() on a disposed
      // ChangeNotifier. An outstanding Timer fails this test outright.
      app.debugArmOwnedTimers();
      app.dispose();
    });

    testWidgets('disposes every owned notifier/observer', (t) async {
      final app = AppState.forTesting();
      app.dispose();
      void addTo(void Function(VoidCallback) add) =>
          expect(() => add(() {}), throwsA(isA<FlutterError>()));
      addTo(app.navRequest.addListener);
      addTo(app.screenRequest.addListener);
      addTo(app.insightsRevision.addListener);
      addTo(app.gestureSettings.addListener);
      // NotificationRelay holds a WidgetsBindingObserver, a 15-min heal
      // Timer.periodic and a StreamSubscription — its observer accumulated on
      // the binding across every hot restart.
      addTo(app.notificationRelay.addListener);
    });
  });

  // ── live HR must be a reading of NOW, not the last one the engine saw ───────
  group('AppState.liveHr freshness', () {
    int now() => DateTime.now().millisecondsSinceEpoch;

    AppState connected(int? hr, {int ageMs = 0}) {
      final app = AppState.forTesting();
      app.device.connection = 'connected';
      app.device.liveHr = hr;
      app.device.liveHrAt = hr == null ? null : now() - ageMs;
      return app;
    }

    test('a fresh reading from a connected band is the reading', () {
      final app = connected(142);
      addTearDown(app.dispose);
      expect(app.liveHr, 142);
    });

    test('a reading older than the window is absent, not stale', () {
      // Nothing clears DeviceState.liveHr on an unintentional drop —
      // _teardownSession never calls disableLiveStreams — so the raw field
      // reads like a measurement forever. 30 s is well past liveHrMaxAge (10 s).
      final app = connected(142, ageMs: 30 * 1000);
      addTearDown(app.dispose);
      expect(app.liveHr, isNull);
    });

    test('a disconnected band has no live HR however fresh the value looks',
        () {
      final app = connected(142);
      addTearDown(app.dispose);
      app.device.connection = 'disconnected';
      expect(app.liveHr, isNull);
    });

    test('the tick bills a fresh reading and skips an absent one', () {
      final app = connected(150);
      addTearDown(app.dispose);
      final w = LiveWorkoutState(
        startTime: DateTime.now().subtract(const Duration(minutes: 5)),
        targetKcal: 300,
        workoutId: 'w1',
        type: 'run',
      );
      app.activeWorkout = w;

      app.debugTickWorkout();
      expect(w.currentHr, 150);
      final billed = w.zoneSeconds.reduce((x, y) => x + y);
      final peak = w.maxHrSeen; // rolling-median, so not 150 off one sample
      expect(billed, 1, reason: 'one tick, one second in a zone');

      // The band drops mid-workout: the engine keeps its last value, the tick
      // must not keep billing it. Pre-fix this read `device.liveHr ?? 0` and
      // charged the stale 150 into zone-seconds, calories and strain for the
      // rest of the session, then persisted it on stop.
      app.device.liveHrAt = now() - 60 * 1000;
      app.debugTickWorkout();
      expect(w.currentHr, isNull, reason: 'absent is not zero');
      expect(w.zoneSeconds.reduce((x, y) => x + y), billed,
          reason: 'no zone-second for a second with no measurement');
      expect(w.maxHrSeen, peak, reason: 'the peak is untouched by an absence');
    });

    test('the tick consults the idle watch — a quiet session asks', () {
      // The wiring, not the policy (workout_idle_test.dart owns the policy):
      // a session 30 minutes old with no live HR must have produced an ask by
      // the end of one tick, and a session with real HR must not have.
      final app = connected(null);
      addTearDown(app.dispose);
      final w = LiveWorkoutState(
        startTime: DateTime.now().subtract(const Duration(minutes: 30)),
        targetKcal: 300,
        workoutId: 'w1',
        type: 'run',
      );
      app.activeWorkout = w;
      app.debugTickWorkout();
      expect(w.idleWatch.lastAskAt, isNotNull,
          reason: '30 quiet minutes into an open session, the watch asks');

      final active = connected(150);
      addTearDown(active.dispose);
      final w2 = LiveWorkoutState(
        startTime: DateTime.now().subtract(const Duration(minutes: 30)),
        targetKcal: 300,
        workoutId: 'w2',
        type: 'run',
      );
      active.activeWorkout = w2;
      active.debugTickWorkout();
      expect(w2.idleWatch.lastAskAt, isNull,
          reason: 'a real reading (no gate → any reading) is activity');
    });
  });
}
