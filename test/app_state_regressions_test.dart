// Regression tests for a batch of AppState state-machine bugs.
//
// AppState.forTesting() builds the object graph WITHOUT running _init() and
// without touching a single platform plugin, so the logic below can be driven
// directly. Each group names the bug it guards.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show AndroidFlutterLocalNotificationsPlugin;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/compute/hr_max.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/activity/live.dart';
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

  // ── 6b. "Sync the band" on a link that is already up ───────────────────────
  group('syncNow (already connected)', () {
    test('asks the band for an offload instead of reusing the link', () async {
      final engine = _ConnectedEngine();
      final app = AppState.forTesting(engine: engine);
      addTearDown(app.dispose);
      app.paired = PairedDevice('r-1', '4C2248092');

      // openSession on a live link reuses it and only joins an offload, so
      // the tap never sent SEND_HISTORICAL and nothing came off the band.
      await app.syncNow();

      expect(engine.foregroundRequests, 1);
      expect(app.busy, isFalse);
    });

    test('goes through the floored foreground pull, not a manual one',
        () async {
      // A manual request is never floored, so quick repeat taps on a band
      // that just drained each got an empty offload, and three of those
      // flip the clock-lost status and back the periodic pull off.
      final engine = _ConnectedEngine();
      final app = AppState.forTesting(engine: engine);
      addTearDown(app.dispose);
      app.paired = PairedDevice('r-1', '4C2248092');

      await app.syncNow();
      await app.syncNow();
      await app.syncNow();

      expect(engine.historyRequests, 0);
      expect(engine.foregroundRequests, 3);
      expect(engine.syncs, 1);
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
      expect(row?['end_ts'], nowSec - 7 * 60 * 60,
          reason: 'no tally snapshot = it never ticked; stamping relaunch '
              'time would bill 7 h of 1 Hz HR to it on re-score');
    });

    test('a stale orphan ends at its last tally snapshot, not at relaunch',
        () async {
      // Run started 18:00, app killed at 18:40, reopened 13.5 h later. The
      // re-score bills whatever 1 Hz HR sits in [start_ts, end_ts], so a
      // relaunch-time end turned the whole night into workout calories.
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final startSec = nowSec - 13 * 60 * 60 - 30 * 60;
      final lastTickSec = startSec + 40 * 60;
      const id = 'stale-with-tally';
      await LocalDb.putSession({
        'id': id,
        'start_ts': startSec,
        'end_ts': null,
        'type': 'run',
        'status': 'live',
        'source': 'manual',
        'created_at': startSec * 1000,
      });
      await LocalDb.saveLiveWorkoutTally({
        'workout_id': id,
        'updated_ts': lastTickSec * 1000,
        'per_minute_hr': '[]',
        'zone_seconds': '[]',
        'seconds_by_bpm': '{}',
      });

      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await app.debugReconcileOrphanedLiveWorkout();

      final row = await LocalDb.session(id);
      expect(row?['status'], 'done');
      expect(row?['end_ts'], lastTickSec);
      expect(row?['end_ts_fabricated'], 1);
    });

    test('a malformed tally snapshot still finalizes the stale orphan',
        () async {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final startSec = nowSec - 5 * 60 * 60;
      const id = 'stale-bad-tally';
      await LocalDb.putSession({
        'id': id,
        'start_ts': startSec,
        'end_ts': null,
        'type': 'run',
        'status': 'live',
        'source': 'manual',
        'created_at': startSec * 1000,
      });
      await LocalDb.saveLiveWorkoutTally({
        'workout_id': id,
        'updated_ts': 'garbage',
        'per_minute_hr': '[]',
        'zone_seconds': '[]',
        'seconds_by_bpm': '{}',
      });

      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await app.debugReconcileOrphanedLiveWorkout();

      final row = await LocalDb.session(id);
      expect(row?['status'], 'done');
      expect(row?['end_ts'], startSec);
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
      // the alarm screen shows the fire instead of silently swapping times
      expect(app.alarmFiredAt, isNotNull);
      // and a relaunch later that day still shows it
      expect(prefs.getInt('alarm_fired_at'),
          app.alarmFiredAt!.millisecondsSinceEpoch ~/ 1000);
    });

    test('the app-side EXECUTED id (58) is a RUN_ALARM buzz, the arm stays',
        () async {
      // Smart wake / test buzz send RUN_ALARM. Treating its 58 as the slot
      // firing cleared the arm and, inside 30 s of the slot, re-armed
      // tomorrow over today's still-pending alarm.
      SharedPreferences.setMockInitialValues({'alarm_epoch': 1785000000});
      await silenceOsPresent();
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.alarmEpoch = 1785000000;

      app.debugHandleAlarmEvent(58);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(app.alarmEpoch, 1785000000);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getInt('alarm_epoch'), 1785000000);
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

    test('a fire while connected arms the schedule\'s next occurrence',
        () async {
      await silenceOsPresent();
      final engine = _ArmRecordingEngine();
      final app = AppState.forTesting(engine: engine);
      addTearDown(app.dispose);
      await app.setScheduleDay(weekday: 2, enabled: true); // offline: no arm
      expect(engine.armed, isEmpty);
      app.device.connection = 'connected';
      app.device.alarmEpoch = 1785000000;

      app.debugHandleAlarmEvent(57);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Pre-fix nothing re-armed until the next reconnect: a link that stayed
      // up all day left the next morning unarmed and Home saying
      // "Set an alarm" while the schedule still had the day on.
      expect(engine.armed, hasLength(1));
      expect(engine.armed.single.isAfter(DateTime.now()), isTrue);
      expect(engine.armed.single.weekday, DateTime.wednesday);
      expect(app.alarmEpoch,
          engine.armed.single.millisecondsSinceEpoch ~/ 1000);
    });

    test('a headless re-arm shows up once the foreground connects', () async {
      await silenceOsPresent();
      final engine = _ArmRecordingEngine();
      final app = AppState.forTesting(engine: engine);
      addTearDown(app.dispose);
      await app.setScheduleDay(weekday: 2, enabled: true); // offline: no arm
      final next = nextAlarmOccurrence(app.alarmSchedule, DateTime.now())!;
      final headless = next.millisecondsSinceEpoch ~/ 1000;
      // Headless armed it under this live process; the session still holds
      // an older optimistic epoch.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('alarm_epoch', headless);
      await prefs.setBool('alarm_epoch_confirmed', true);
      app.device.alarmEpoch = 1785000000;
      app.device.connection = 'connected';

      await app.setScheduleDay(weekday: 2, enabled: true);

      expect(engine.armed, isEmpty, reason: 'already armed, no rewrite');
      expect(app.alarmEpoch, headless);
      expect(app.alarmConfirmed, isTrue);
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

    test('ALARM_SET (event 56) re-decides the 7pm no-alarm check', () async {
      // it was only decided on resume, so a check armed at 17:00 with nothing
      // set went on to fire at 19:00 over an alarm the strap had confirmed.
      SharedPreferences.setMockInitialValues({'alarm_epoch': 1785000000});
      const ch = MethodChannel('dexterous.com/flutter/local_notifications');
      final cancelled = <Object?>[];
      final messenger = TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ch, (call) async {
        if (call.method == 'cancel') cancelled.add((call.arguments as Map)['id']);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(ch, null));
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.device.alarmEpoch = 1785000000;

      app.debugHandleAlarmEvent(56);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(cancelled, contains(NotificationService.idAlarmNightCheck));
    });
  });

  test('a late event 56 after a relaunch still confirms the earlier arm',
      () async {
    // Armed an hour ago, no 56 inside the grace window, app killed. The
    // relaunch used to restamp setAtMs to launch time, so the strap's pending
    // 56 (stamped at the real arm) read as a replay and was dropped.
    final armMs =
        DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
    final epoch = armMs ~/ 1000 + 10 * 3600;
    SharedPreferences.setMockInitialValues({
      'alarm_epoch': epoch,
      'alarm_epoch_confirmed': false,
      'alarm_set_at_ms': armMs,
    });
    final app = AppState.forTesting();
    await app.debugInit();
    // Let start-up's fire-and-forget tails land before dispose.
    addTearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      app.dispose();
    });
    expect(app.alarmConfirmed, isFalse);

    app.debugHandleAlarmEvent(56, tsSec: armMs ~/ 1000);

    expect(app.alarmConfirmed, isTrue);
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

    test('a paused session holds its clock and its tallies', () async {
      await Prefs.ensureLoaded();
      final app = connected(150);
      addTearDown(app.dispose);
      addTearDown(LiveDraft.clear);
      final w = LiveWorkoutState(
        startTime: DateTime.now().subtract(const Duration(minutes: 50)),
        targetKcal: 300,
        workoutId: 'w1',
        type: 'run',
      );
      app.activeWorkout = w;
      final d = LiveDraft.begin(activityByName('running')!);
      // 20 of the 50 minutes were spent paused.
      d.pausedSec = 20 * 60;
      app.debugTickWorkout();
      expect(w.elapsed.inMinutes, 30);
      final billed = w.zoneSeconds.reduce((x, y) => x + y);

      d.setPaused(true);
      app.debugTickWorkout();
      expect(w.elapsed.inMinutes, 30, reason: 'the clock holds while paused');
      expect(w.zoneSeconds.reduce((x, y) => x + y), billed,
          reason: 'no zone-second billed while paused');
    });

    test('finishing a session that came back paused saves its real length',
        () async {
      await Prefs.ensureLoaded();
      const id = 'paused-at-relaunch';
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      addTearDown(LiveDraft.clear);
      // A relaunch rebuilds the session with elapsed 0, and a paused draft
      // means no tick ever moves it.
      final w = LiveWorkoutState(
        startTime: DateTime.now().subtract(const Duration(minutes: 50)),
        targetKcal: 300,
        workoutId: id,
        type: 'run',
      );
      app.activeWorkout = w;
      LiveDraft.begin(activityByName('running')!).pausedAt =
          DateTime.now().subtract(const Duration(minutes: 10));
      app.debugTickWorkout();
      expect(w.elapsed.inMinutes, 40);

      w.elapsed = Duration.zero;
      await app.stopWorkout();
      expect((await LocalDb.session(id))?['duration_min'], 40);
    });

    test('a paused draft left from an older session does not hold a new one',
        () async {
      await Prefs.ensureLoaded();
      final app = connected(150);
      addTearDown(app.dispose);
      addTearDown(LiveDraft.clear);
      LiveDraft.begin(activityByName('running')!).setPaused(true);
      // The gesture path: startWorkout with no setup screen, so no new draft.
      app.startWorkout(type: 'other');
      addTearDown(app.stopWorkout); // no live row left for later reconciles
      expect(LiveDraft.current, isNull);
      app.debugTickWorkout();
      expect(app.activeWorkout!.zoneSeconds.reduce((x, y) => x + y), 1,
          reason: 'the new session ticks');
    });

    test('a stopped workout keeps its sensors for the recovery tail',
        () async {
      // Heart-rate recovery is read off the minutes after the end, so a
      // strap disarmed at the stop never records it.
      await Prefs.ensureLoaded();
      final app = connected(150);
      addTearDown(app.dispose);
      addTearDown(LiveDraft.clear);
      app.startWorkout(type: 'other');
      expect(app.strapTailRunning, isFalse);
      await app.stopWorkout();
      expect(app.strapTailRunning, isTrue,
          reason: 'armed until the tail is recorded');
      app.startWorkout(type: 'other');
      expect(app.strapTailRunning, isFalse,
          reason: 'the next workout carries the sensors on');
      await app.stopWorkout();
    });

    test('a banked tail disarms and asks for the derive that reads it',
        () async {
      await Prefs.ensureLoaded();
      final app = connected(150);
      addTearDown(app.dispose);
      addTearDown(LiveDraft.clear);
      var derives = 0;
      app
        ..strapTailFor = const Duration(milliseconds: 20)
        ..onStrapTailBanked = () => derives++;
      app.startWorkout(type: 'other');
      await app.stopWorkout();
      expect(derives, 0, reason: 'the tail is not recorded yet');
      for (var i = 0; i < 100 && derives == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(app.strapTailRunning, isFalse, reason: 'disarmed at its end');
      expect(derives, 1, reason: 'HRR is read off the tail once it is banked');
    });

    test('a workout deleted inside its tail disarms at once', () async {
      await Prefs.ensureLoaded();
      final app = connected(150);
      addTearDown(app.dispose);
      addTearDown(LiveDraft.clear);
      var derives = 0;
      app.onStrapTailBanked = () => derives++;
      app.startWorkout(type: 'other');
      final id = app.activeWorkout!.workoutId!;
      await app.stopWorkout();
      expect(app.strapTailRunning, isTrue);
      await app.deleteWorkout(id);
      expect(app.strapTailRunning, isFalse, reason: 'nothing to record for');
      expect(derives, 0);
    });

    test('resuming after a long pause does not ask "still working out?"',
        () async {
      await Prefs.ensureLoaded();
      final app = connected(null);
      addTearDown(app.dispose);
      addTearDown(LiveDraft.clear);
      final w = LiveWorkoutState(
        startTime: DateTime.now().subtract(const Duration(minutes: 30)),
        targetKcal: 300,
        workoutId: 'w1',
        type: 'run',
      );
      app.activeWorkout = w;
      final d = LiveDraft.begin(activityByName('running')!)
        ..pausedAt = DateTime.now().subtract(const Duration(minutes: 25));
      app.debugTickWorkout();
      expect(w.idleWatch.lastAskAt, isNotNull,
          reason: 'a pause left running past the threshold is still asked '
              'about: paused and forgotten is a forgotten session');
      d.setPaused(false);
      app.debugTickWorkout();
      expect(w.idleWatch.lastAskAt, isNull,
          reason: 'the pause was the user, not a forgotten session');
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

    test('a zone-1 reading below the calorie gate is not "resting" (#466)', () {
      // RHR 60 / max 190: the calorie gate is 112 bpm, zone 1 starts at 95.
      // A steady 100 bpm session reads ZONE 1 on the live bar, so it must not
      // be asked "nothing above resting effort".
      LiveWorkoutState session(String id) => LiveWorkoutState(
            startTime: DateTime.now().subtract(const Duration(minutes: 30)),
            targetKcal: 300,
            workoutId: id,
            type: 'strength',
            hrMax: 190,
            restingHr: 60,
            zoneSet: ana.HeartRateZones.zonesFromMaxHr(190),
          );
      final app = connected(100);
      addTearDown(app.dispose);
      final w = session('z1');
      app.activeWorkout = w;
      app.debugTickWorkout();
      expect(w.idleWatch.lastAskAt, isNull);

      final rest = connected(70);
      addTearDown(rest.dispose);
      final w2 = session('rest');
      rest.activeWorkout = w2;
      rest.debugTickWorkout();
      expect(w2.idleWatch.lastAskAt, isNotNull,
          reason: 'below zone 1 is still quiet');
    });

    test('a high resting HR still lets the zone-1 edge win (#466)', () {
      // RHR 72 / max 173: calorie gate 112.4, zone 1 starts at 86.5. Halfway
      // to the gate (92.2) sat above zone 1, so 89 bpm showed ZONE 1 and was
      // still asked "nothing above resting effort".
      final app = connected(89);
      addTearDown(app.dispose);
      final w = LiveWorkoutState(
        startTime: DateTime.now().subtract(const Duration(minutes: 30)),
        targetKcal: 300,
        workoutId: 'high-rhr',
        type: 'strength',
        hrMax: 173,
        restingHr: 72,
        zoneSet: ana.HeartRateZones.zonesFromMaxHr(173),
      );
      app.activeWorkout = w;
      app.debugTickWorkout();
      expect(w.idleWatch.lastAskAt, isNull);
    });

    test('a manual zone-1 edge below resting HR does not mute the watch', () {
      // Manual bounds only need zone 1 >= 30 bpm. With zone 1 at 50 and RHR
      // 58, capping the gate at zone 1 made a session left open overnight at
      // 60 bpm read active every tick, so it was never asked about.
      final app = connected(60);
      addTearDown(app.dispose);
      final w = LiveWorkoutState(
        startTime: DateTime.now().subtract(const Duration(minutes: 30)),
        targetKcal: 300,
        workoutId: 'manual-z1',
        type: 'strength',
        hrMax: 190,
        restingHr: 58,
        zoneSet: trainingZones(manualZoneLowerBpm: [50, 100, 130, 150, 170]),
      );
      app.activeWorkout = w;
      app.debugTickWorkout();
      expect(w.idleWatch.lastAskAt, isNotNull,
          reason: 'resting HR is quiet whatever zone 1 says');
    });

    test('a zone-1 edge just above resting HR does not mute the watch', () {
      // Resting HR is the night's lowest 30-min mean, so sleeping HR sits a
      // few bpm above it. Zone 1 at 50 with RHR 49 must not turn 52 bpm of
      // sleep into activity.
      final app = connected(52);
      addTearDown(app.dispose);
      final w = LiveWorkoutState(
        startTime: DateTime.now().subtract(const Duration(minutes: 30)),
        targetKcal: 300,
        workoutId: 'manual-z1-near',
        type: 'strength',
        hrMax: 190,
        restingHr: 49,
        zoneSet: trainingZones(manualZoneLowerBpm: [50, 100, 130, 150, 170]),
      );
      app.activeWorkout = w;
      app.debugTickWorkout();
      expect(w.idleWatch.lastAskAt, isNotNull,
          reason: 'sleeping HR just above RHR is quiet');
    });
  });

  // ── a hard-kill relaunch mid-workout must not reset strain/calories/zone
  // minutes to 0.0 — the tally is snapshotted periodically and restored on
  // reconcile instead of being zeroed. ─────────────────────────────────────
  group('live workout tally survives a hard-kill relaunch', () {
    test('a resumed session restores strain/calories/zone minutes near '
        'where the killed process left them, not zero', () async {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      const id = 'killed-mid-workout';
      // The row a genuinely live session left behind (never finalized —
      // the process died before stopWorkout() could run). Started 5s ago:
      // the reconcile resumes the SINGLE most-recent live row and finalizes
      // any others as stale, and this file's DB is shared across the whole
      // suite, so this must outrank every row an earlier test left live.
      await LocalDb.putSession({
        'id': id,
        'start_ts': nowSec - 5,
        'end_ts': null,
        'type': 'run',
        'status': 'live',
        'source': 'manual',
        'created_at': (nowSec - 5) * 1000,
      });
      // The periodic snapshot the OLD process wrote ~30s before it died:
      // 15 finished minutes at 140 bpm, 5 minutes (300s) already billed at
      // 140 bpm for calories, all of it in zone 3, peak 150.
      await LocalDb.saveLiveWorkoutTally({
        'workout_id': id,
        'updated_ts': DateTime.now().millisecondsSinceEpoch,
        'per_minute_hr': jsonEncode(List<double>.filled(15, 140.0)),
        'zone_seconds': jsonEncode([0.0, 0.0, 0.0, 900.0, 0.0, 0.0]),
        'seconds_by_bpm': jsonEncode({'140': 900.0}),
        'max_hr_seen': 150,
      });

      final app = AppState.forTesting();
      addTearDown(app.dispose);
      // Full calorie anchors, so a genuine restore (not just an abstain) is
      // being asserted.
      app.user = {
        'age': 30,
        'weight_kg': 70.0,
        'height_cm': 175.0,
        'sex': 'male',
        'resting_hr': 55,
      };

      // A settled week of quiet-waking levels. Live strain is priced on the
      // user's own level, which the reconcile's anchor refresh fills in after
      // the restore — awaited here, so the restored series is re-scored on it.
      for (var d = 1; d <= 7; d++) {
        await LocalDb.putMetricSeriesValue('2020-01-0$d', 'quiet_hrr', 0.20);
      }
      await app.debugReconcileOrphanedLiveWorkout();
      await app.debugRefreshNightlyRhr();

      final w = app.activeWorkout;
      expect(w?.workoutId, id);
      expect(w?.maxHrSeen, 150,
          reason: 'the pre-kill peak must survive, not restart at 0');
      expect(w?.zoneMinutes()[2], closeTo(15.0, 1e-9),
          reason: 'zone 3 (index 2 of the Z1..Z5 payload) had 900s banked '
              'before the kill — resuming at 0.0 would be the reported bug');
      expect(w?.strain, isNotNull,
          reason: 'strain must recompute off the restored per-minute series, '
              'not abstain as if no sample had ever arrived');
      expect(w!.strain! > 0, isTrue);
      expect(w.caloriesOrNull, isNotNull,
          reason: 'calories must recompute off the restored bpm histogram');
      expect(w.caloriesOrNull! > 0, isTrue);

      // The DB snapshot is exhausted at reconcile time; a genuinely killed
      // process could still not resume it a second time from the same row.
    });

    test('a fresh workout (no prior snapshot) still starts clean', () async {
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      const id = 'no-snapshot-yet';
      // Must outrank the previous test's still-live row the same way.
      await LocalDb.putSession({
        'id': id,
        'start_ts': nowSec - 2,
        'end_ts': null,
        'type': 'run',
        'status': 'live',
        'source': 'manual',
        'created_at': (nowSec - 2) * 1000,
      });

      final app = AppState.forTesting();
      addTearDown(app.dispose);
      await app.debugReconcileOrphanedLiveWorkout();

      final w = app.activeWorkout;
      expect(w?.workoutId, id);
      expect(w?.maxHrSeen, 0);
      expect(w?.zoneMinutes().every((v) => v == 0), isTrue,
          reason: 'no snapshot ever existed for this id — zero is honest '
              'here, not a bug');
    });

    test('stopWorkout deletes the tally so it cannot leak onto a future '
        'session that reuses the id', () async {
      const id = 'finished-then-reused';
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.startWorkout(workoutId: id, type: 'run');
      await LocalDb.saveLiveWorkoutTally({
        'workout_id': id,
        'updated_ts': DateTime.now().millisecondsSinceEpoch,
        'per_minute_hr': jsonEncode([120.0]),
        'zone_seconds': jsonEncode([0.0, 60.0, 0.0, 0.0, 0.0, 0.0]),
        'seconds_by_bpm': jsonEncode({'120': 60.0}),
        'max_hr_seen': 120,
      });

      await app.stopWorkout();

      expect(await LocalDb.liveWorkoutTally(id), isNull);
    });

    test('deleting the running session ends it, and stop cannot bring it back',
        () async {
      await Prefs.ensureLoaded();
      const id = 'deleted-while-live';
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      addTearDown(LiveDraft.clear);
      app.repo = _DeleteRepo();
      app.startWorkout(workoutId: id, type: 'run');
      LiveDraft.begin(activityByName('running')!).setPaused(true);
      expect(await LocalDb.session(id), isNotNull);

      await app.deleteWorkout(id);

      expect(app.activeWorkout, isNull);
      expect(LiveDraft.current, isNull,
          reason: 'a paused draft left behind would freeze the next session');
      await app.stopWorkout();
      expect(await LocalDb.session(id), isNull);
    });
  });

  // ── the live gauge prices a session on ITS OWN day's quiet level ─────────
  group('live quiet level is read for the session\'s own day', () {
    // Seven prior days at 0.20: every day after 2020-01-07 has a settled
    // level; 2020-01-03 has only two days behind it.
    Future<void> seedLevels() async {
      for (var d = 1; d <= 7; d++) {
        await LocalDb.putMetricSeriesValue('2020-01-0$d', 'quiet_hrr', 0.20);
      }
    }

    test('a new session is filled with a level read fresh for its day',
        () async {
      await seedLevels();
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.startWorkout(workoutId: 'fresh-level', type: 'run');
      final w = app.activeWorkout!;
      expect(w.quietHrr, isNull,
          reason: 'nothing cached — the refresh reads it for this day');
      await app.debugRefreshNightlyRhr();
      expect(w.quietHrr, 0.20);
      await app.stopWorkout();
    });

    test('a level a running session was scored on never moves', () async {
      await seedLevels();
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.startWorkout(workoutId: 'pinned-level', type: 'run');
      final w = app.activeWorkout!..quietHrr = 0.33;
      await app.debugRefreshNightlyRhr();
      expect(w.quietHrr, closeTo(0.33, 1e-12));
      await app.stopWorkout();
    });

    test('a resumed session is priced on its START day, not today', () async {
      await seedLevels();
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      // Started on a day with only two prior levels: its own day abstains,
      // even though today has a settled level cached.
      final early = LiveWorkoutState(
        startTime: DateTime(2020, 1, 3, 23, 50),
        targetKcal: 300,
        workoutId: 'resumed-early',
        type: 'run',
      );
      app.activeWorkout = early;
      await app.debugRefreshNightlyRhr();
      expect(early.quietHrr, isNull);

      // Started on a day with five prior levels: present, but calibrating —
      // not today's settled week.
      final later = LiveWorkoutState(
        startTime: DateTime(2020, 1, 6, 23, 50),
        targetKcal: 300,
        workoutId: 'resumed-later',
        type: 'run',
      );
      app.activeWorkout = later;
      await app.debugRefreshNightlyRhr();
      expect(later.quietHrr, 0.20);
      expect(later.quietSettled, isFalse);
      app.activeWorkout = null;
    });
  });
}

class _ConnectedEngine extends BleEngine {
  _ConnectedEngine() : super(onRecord: (_, _) async {}, onState: (_) {});
  int historyRequests = 0;
  int foregroundRequests = 0;
  int syncs = 0;

  @override
  bool get isConnected => true;

  @override
  Future<void> requestHistorySync() async => historyRequests++;

  // Stands in for the 90 s floor: only the first ask goes out.
  @override
  Future<bool> requestForegroundSync() async => ++foregroundRequests == 1;

  @override
  Future<SyncReport> runSync({
    Duration timeout = const Duration(seconds: 600),
  }) async {
    syncs++;
    return SyncReport(0, 0, true);
  }
}

/// Records every SET_ALARM instead of writing to a band.
class _ArmRecordingEngine extends BleEngine {
  _ArmRecordingEngine() : super(onRecord: (_, _) async {}, onState: (_) {});
  final armed = <DateTime>[];
  @override
  Future<DateTime?> setAlarm(DateTime when,
      {int index = 0, List<int>? haptics}) async {
    armed.add(when);
    return when;
  }
}

class _DeleteRepo extends LocalRepository {
  @override
  Future<void> deleteWorkout(String id) => LocalDb.deleteSession(id);
}
