import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/health/phone_pedometer.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_state_sync_harness.dart';

const _db = 'app_state_phone_steps_sync.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await deriveDbSetUp(_db);
    SharedPreferences.setMockInitialValues({
      'phone_steps_healthstore_purged': true,
    });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(phoneStepsChannel, null);
    await deriveDbTearDown(_db);
  });

  void sensor(Future<Object?> Function(MethodCall) read) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(phoneStepsChannel, read);
  }

  test('late phone rows queue a new pass after the earlier band derive, '
      'and publishing it refreshes screen revisions',
      syncCase((rig, timers) async {
    rig.app.phoneStepsEnabled = true;
    var derivedSteps = 0;
    rig.app.debugDeriveRun =
        (profile, {bool heavy = false, onDayDone}) async {
      derivedSteps = await LocalDb.phoneStepsForDay(todayLabel());
      return 1;
    };
    await rig.app.debugAfterDrain();
    expect(derivedSteps, 0);
    final revision = rig.app.insightsRevision.value;
    final gate = Completer<void>();
    var reads = 0;
    sensor((call) async {
      if (call.method == 'authorized') return true;
      if (call.method == 'stepsInInterval') {
        reads++;
        await gate.future;
        return 12;
      }
      return null;
    });
    final sync = rig.app.syncPhoneSteps(days: 1);
    await rig.waitFor(() => reads > 0);
    expect(await rig.jobTypes(), isEmpty);
    gate.complete();
    expect(await sync, 1);
    await rig.jobQueued('derive_light');
    await rig.settleDerive(const Duration(seconds: 8));
    expect(derivedSteps, 0, reason: 'the old pass is not the new result');
    timers.activeOneShot(const Duration(seconds: 8)).single.fire();
    await rig.waitFor(() => rig.app.insightsRevision.value > revision);
    expect(derivedSteps, reads * 12);
    expect(derivedSteps, greaterThan(0));
  }, paired: false));

  test('overlapping routine refreshes share one sensor walk',
      syncCase((rig, timers) async {
    rig.app.phoneStepsEnabled = true;
    final gate = Completer<void>();
    var authorizations = 0;
    var reads = 0;
    sensor((call) async {
      if (call.method == 'authorized') {
        authorizations++;
        return true;
      }
      if (call.method == 'stepsInInterval') {
        reads++;
        await gate.future;
        return 7;
      }
      return null;
    });
    final first = rig.app.syncPhoneSteps(days: 1);
    await rig.waitFor(() => reads > 0);
    final second = rig.app.syncPhoneSteps(days: 1);
    gate.complete();
    expect(await first, 1);
    expect(await second, 1);
    expect(authorizations, 1);
    expect(await LocalDb.phoneStepsForDay(todayLabel()), reads * 7);
    await rig.jobQueued('derive_light');
  }, paired: false));

  test('a larger explicit window is not lost behind a routine refresh',
      syncCase((rig, timers) async {
    rig.app.phoneStepsEnabled = true;
    final gate = Completer<void>();
    var reads = 0;
    var authorizations = 0;
    sensor((call) async {
      if (call.method == 'authorized') {
        authorizations++;
        return true;
      }
      if (call.method == 'stepsInInterval') {
        reads++;
        await gate.future;
        return 3;
      }
      return null;
    });
    final routine = rig.app.syncPhoneSteps(days: 1);
    await rig.waitFor(() => reads > 0);
    final larger = rig.app.syncPhoneSteps(days: 2);
    gate.complete();
    expect(await routine, 1);
    expect(await larger, 2);
    expect(authorizations, 2);
    expect(rig.app.phoneStepsLastSyncedDays, 2);
    // Yesterday was banked for the first time, so a heavy pass is requested:
    // the light one only ever targets today.
    await rig.jobQueued('derive_heavy');
  }, paired: false));

  test('failed reads keep banked counts, queue no derive, and allow retry',
      syncCase((rig, timers) async {
    rig.app.phoneStepsEnabled = true;
    await LocalDb.replacePhoneCoverageForDay(
      todayLabel(),
      [(startTs: 1000, endTs: 4600, steps: 700)],
    );
    var fail = true;
    sensor((call) async {
      if (call.method == 'authorized') return true;
      if (call.method == 'stepsInInterval') {
        if (fail) throw PlatformException(code: 'sensor_unavailable');
        return 5;
      }
      return null;
    });
    expect(await rig.app.syncPhoneSteps(days: 1), 0);
    expect(await LocalDb.phoneStepsForDay(todayLabel()), 700);
    expect(await rig.jobTypes(), isEmpty);
    fail = false;
    expect(await rig.app.syncPhoneSteps(days: 1), 1);
    await rig.jobQueued('derive_light');
  }, paired: false));

  test('phone refresh does not bypass the active capture hold',
      syncCase((rig, timers) async {
    rig.app.phoneStepsEnabled = true;
    rig.app.debugDeriveScheduler.setOffloadActive(true);
    sensor((call) async =>
        call.method == 'authorized' ? true : 6);
    expect(await rig.app.syncPhoneSteps(days: 1), 1);
    await rig.jobQueued('derive_light');
    expect(timers.activeOneShot(const Duration(seconds: 8)), isEmpty);
    expect(rig.passes, isEmpty);
    rig.app.debugDeriveScheduler.setOffloadActive(false);
    await rig.settleDerive(const Duration(seconds: 8));
    timers.activeOneShot(const Duration(seconds: 8)).single.fire();
    await rig.waitFor(() => rig.passes.isNotEmpty);
  }, paired: false));

  test('disabled phone steps do not query the sensor or queue work',
      syncCase((rig, timers) async {
    var calls = 0;
    sensor((call) async {
      calls++;
      return true;
    });
    expect(await rig.app.syncPhoneSteps(), 0);
    expect(calls, 0);
    expect(await rig.jobTypes(), isEmpty);
  }, paired: false));

  test('a hung sensor read is retired after the timeout, the next call reads '
      'fresh, and the late finish cannot overwrite it',
      syncCase((rig, timers) async {
    rig.app.phoneStepsEnabled = true;
    final saved = AppState.phoneStepsReadTimeout;
    // One-shot timers of a second or more are fake here, so the timeout fires
    // exactly when the test says and never races the real clock.
    const giveUp = Duration(seconds: 2);
    AppState.phoneStepsReadTimeout = giveUp;
    addTearDown(() => AppState.phoneStepsReadTimeout = saved);
    final stuck = Completer<void>();
    var reads = 0;
    sensor((call) async {
      if (call.method == 'authorized') return true;
      if (call.method == 'stepsInInterval') {
        final mine = ++reads;
        if (mine == 1) {
          await stuck.future;
          return 900;
        }
        return 5;
      }
      return null;
    });
    final first = rig.app.syncPhoneSteps(days: 1);
    await rig.waitFor(() => reads == 1);
    timers.activeOneShot(giveUp).single.fire();
    expect(await first, 0, reason: 'the hung read is given up on');
    AppState.phoneStepsReadTimeout = const Duration(seconds: 30);
    final fresh = await rig.app.syncPhoneSteps(days: 1);
    expect(fresh, 1, reason: 'the slot was freed, so this one really reads');
    final banked = await LocalDb.phoneStepsForDay(todayLabel());
    expect(banked, greaterThan(0));
    stuck.complete();
    // Let the retired read run to its end; nothing to await on from here.
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await LocalDb.phoneStepsForDay(todayLabel()), banked,
        reason: 'the retired read banks nothing when it finally returns');
  }, paired: false));

  test('a reset while a sensor read is in flight is not written back',
      syncCase((rig, timers) async {
    rig.app.phoneStepsEnabled = true;
    final gate = Completer<void>();
    var reads = 0;
    sensor((call) async {
      if (call.method == 'authorized') return true;
      if (call.method == 'stepsInInterval') {
        reads++;
        await gate.future;
        return 40;
      }
      return null;
    });
    final sync = rig.app.syncPhoneSteps(days: 1);
    await rig.waitFor(() => reads > 0);
    ResetGate.enter();
    try {
      gate.complete();
      await sync;
    } finally {
      ResetGate.leave();
    }
    expect(await LocalDb.phoneStepsForDay(todayLabel()), 0,
        reason: 'the read started before the reset must not repopulate it');
  }, paired: false));

  test('disabling phone steps drops the shared read, so turning it back on '
      'starts a fresh one', syncCase((rig, timers) async {
    rig.app.phoneStepsEnabled = true;
    final gate = Completer<void>();
    var reads = 0;
    sensor((call) async {
      if (call.method == 'authorized') return true;
      if (call.method == 'stepsInInterval') {
        reads++;
        await gate.future;
        return 3;
      }
      return null;
    });
    final old = rig.app.syncPhoneSteps(days: 6);
    await rig.waitFor(() => reads > 0);
    await rig.app.disablePhoneSteps();
    rig.app.phoneStepsEnabled = true;
    final before = reads;
    final fresh = rig.app.syncPhoneSteps(days: 6);
    await rig.waitFor(() => reads > before);
    gate.complete();
    expect(await old, 0, reason: 'the stopped read banks nothing');
    expect(await fresh, greaterThan(0),
        reason: 'the re-enabled read ran its own walk');
  }, paired: false));

  test('days saved before a hung read timed out still queue derivation',
      syncCase((rig, timers) async {
    rig.app.phoneStepsEnabled = true;
    final saved = AppState.phoneStepsReadTimeout;
    const giveUp = Duration(seconds: 2);
    AppState.phoneStepsReadTimeout = giveUp;
    addTearDown(() => AppState.phoneStepsReadTimeout = saved);
    final now = DateTime.now();
    final todayStartMs =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final never = Completer<void>();
    var yesterdayHit = false;
    sensor((call) async {
      if (call.method == 'authorized') return true;
      if (call.method == 'stepsInInterval') {
        final from = (call.arguments as Map)['fromMs'] as int;
        if (from < todayStartMs) {
          yesterdayHit = true;
          await never.future; // yesterday hangs
        }
        return 4;
      }
      return null;
    });
    final read = rig.app.syncPhoneSteps(days: 2);
    await rig.waitFor(() => yesterdayHit);
    timers.activeOneShot(giveUp).single.fire();
    expect(await read, 0, reason: 'the read as a whole gave up');
    expect(await LocalDb.phoneStepsForDay(todayLabel()), greaterThan(0),
        reason: "today's rows were saved before the hang");
    await rig.jobQueued('derive_light');
    never.complete();
  }, paired: false));

  test('a retired read that was still preparing banks nothing', () async {
    final stuck = Completer<void>();
    var asked = 0;
    sensor((call) async {
      if (call.method == 'authorized') {
        asked++;
        await stuck.future;
        return true;
      }
      if (call.method == 'stepsInInterval') return 9;
      return null;
    });
    final ped = PhonePedometer();
    final read = ped.syncRecent(days: 1);
    while (asked == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    ped.abandonInFlight(); // retired while it is still checking permission
    stuck.complete();
    final r = await read;
    expect(r.daysRead, 0);
    expect(await LocalDb.phoneStepsForDay(todayLabel()), 0);
  });

  test('the phone write is refused inside the commit gate once it is stale',
      () async {
    final day = todayLabel();
    final w = [(startTs: 1000, endTs: 2000, steps: 11)];
    expect(await LocalDb.replacePhoneCoverageForDay(day, w, stillValid: () => false),
        isFalse);
    expect(await LocalDb.phoneStepsForDay(day), 0);
    expect(await LocalDb.replacePhoneCoverageForDay(day, w, stillValid: () => true),
        isTrue);
    expect(await LocalDb.phoneStepsForDay(day), 11);
  });

  test('an older read timing out does not retire the read that replaced it',
      syncCase((rig, timers) async {
    rig.app.phoneStepsEnabled = true;
    final saved = AppState.phoneStepsReadTimeout;
    const giveUp = Duration(seconds: 2);
    AppState.phoneStepsReadTimeout = giveUp;
    addTearDown(() => AppState.phoneStepsReadTimeout = saved);
    final stuck = Completer<void>();
    final second = Completer<void>();
    var reads = 0;
    sensor((call) async {
      if (call.method == 'authorized') return true;
      if (call.method == 'stepsInInterval') {
        final mine = ++reads;
        if (mine == 1) {
          await stuck.future;
          return 900;
        }
        await second.future;
        return 6;
      }
      return null;
    });
    final a = rig.app.syncPhoneSteps(days: 1);
    await rig.waitFor(() => reads == 1);
    await rig.app.disablePhoneSteps();
    rig.app.phoneStepsEnabled = true;
    final b = rig.app.syncPhoneSteps(days: 1);
    await rig.waitFor(() => reads == 2);
    // A's timer fires while B owns the slot.
    timers.activeOneShot(giveUp).first.fire();
    expect(await a, 0);
    second.complete();
    expect(await b, 1, reason: 'B was not retired by A\'s timeout');
    expect(await LocalDb.phoneStepsForDay(todayLabel()), greaterThan(0));
    stuck.complete();
  }, paired: false));

  test('a phone read that changes an earlier day queues a heavy derive; one '
      'that only touches today does not', syncCase((rig, timers) async {
    rig.app.phoneStepsEnabled = true;
    sensor((call) async {
      if (call.method == 'authorized') return true;
      if (call.method == 'stepsInInterval') return 5;
      return null;
    });
    expect(await rig.app.syncPhoneSteps(days: 1), 1);
    await rig.jobQueued('derive_light');
    expect(await rig.jobTypes(), isNot(contains('derive_heavy')),
        reason: 'only today moved, the light pass covers it');
    expect(await rig.app.syncPhoneSteps(days: 2), 2);
    await rig.jobQueued('derive_heavy');
  }, paired: false));
}
