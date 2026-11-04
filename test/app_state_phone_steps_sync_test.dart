import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/health/phone_pedometer.dart';
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
    await rig.jobQueued('derive_light');
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
}
