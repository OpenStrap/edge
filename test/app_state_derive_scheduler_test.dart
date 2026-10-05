// AppState's derive scheduler wiring: a heavy job is held until its baseline
// rescan ends, the `deriving` / `derivePending` reads, the recovery-ready
// check after light and heavy passes, and disposal.
//
// These go through the real scheduler and database (its job queue is durable),
// so the settle windows (2 s heavy) are real time.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_derive_harness.dart';

const _db = 'openstrap_app_state_derive_scheduler.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(deriveDbReset);

  AppState make() {
    final a = AppState.forTesting();
    addTearDown(() async {
      a.dispose();
      // Let the unawaited post-pass work finish before the next test resets
      // the database under it.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    return a;
  }

  group('scheduler job', () {
    test('a heavy job stays running while the baseline rescan is blocked, '
        'and a light request waits behind it', () async {
      final app = make();
      final calls = <bool>[];
      app.debugDeriveRun = deriveHook(calls: calls);
      final rescan = Completer<int>();
      var rescanEntered = false;
      app.debugRescanRecent = (_) {
        rescanEntered = true;
        return rescan.future;
      };
      expect(app.deriving, isFalse);
      expect(app.derivePending, isFalse);

      app.debugDeriveScheduler.requestHeavy();
      await until(() => app.derivePending, what: 'heavy job queued');
      await until(() => rescanEntered, what: 'heavy pass reached its rescan');
      expect(app.deriving, isTrue);
      expect(calls, [true]);

      app.debugDeriveScheduler.markStoredData();
      await until(() => app.debugDeriveScheduler.pendingLight,
          what: 'light job queued behind the heavy one');
      // The light job cannot start: the heavy job still holds the scheduler.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(calls, [true]);
      expect(app.deriving, isTrue);

      rescan.complete(0);
      await until(() => !app.deriving, what: 'heavy job released');
      expect(calls, [true]);
      expect(app.derivePending, isTrue,
          reason: 'the light job is still queued, now free to run');
      final jobs = await LocalDb.computeJobs(state: 'queued', limit: 10);
      expect(jobs.map((j) => j['type']), ['derive_light']);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('the scheduler\'s run callback reads as deriving and ticks listeners '
        'on the transitions', () async {
      final app = make();
      final gate = Completer<void>();
      app.debugDeriveRun = deriveHook(gate: gate);
      app.debugRescanRecent = (_) async => 0;
      final log = SignalLog(app);
      app.debugDeriveScheduler.requestHeavy();
      await until(() => app.deriving, what: 'job running');
      expect(log.ticks, greaterThan(0));
      gate.complete();
      await until(() => !app.deriving, what: 'job finished');
      expect(app.derivePending, isFalse);
      expect(app.insightsRevision.value, 1);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('recovery-ready after a pass', () {
    late RecoverySink sink;
    setUp(() {
      sink = RecoverySink();
      addTearDown(sink.restore);
    });

    test('a light pass announces today\'s computed recovery', () async {
      await putTodayReadiness();
      final app = make();
      app.debugDeriveRun = deriveHook();
      await app.debugAfterDrain();
      await until(() => sink.shown.isNotEmpty, what: 'recovery-ready emitted');
      expect(sink.shown, [sink.todayKey]);
    });

    test('a heavy pass announces it too', () async {
      await putTodayReadiness();
      final app = make();
      app.debugDeriveRun = deriveHook();
      app.debugRescanRecent = (_) async => 0;
      await app.debugAfterDrain(heavy: true);
      await until(() => sink.shown.isNotEmpty, what: 'recovery-ready emitted');
      expect(sink.shown, [sink.todayKey]);
    });

    test('it is considered after the pass has published, not before',
        () async {
      await putTodayReadiness();
      final app = make();
      final gate = Completer<void>();
      app.debugDeriveRun = deriveHook(gate: gate);
      final pass = app.debugAfterDrain();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sink.shown, isEmpty, reason: 'the pass has not finished');
      gate.complete();
      await pass;
      await until(() => sink.shown.isNotEmpty, what: 'recovery-ready emitted');
    });

    test('a failed pass does not announce', () async {
      await putTodayReadiness();
      final app = make();
      app.debugDeriveRun = deriveHook(throws: StateError('boom'));
      await app.debugAfterDrain();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(sink.shown, isEmpty);
    });

    test('no computed readiness: nothing is announced', () async {
      final app = make();
      app.debugDeriveRun = deriveHook();
      await app.debugAfterDrain();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(sink.shown, isEmpty);
    });

    test('a night that has not settled is held back until a later pass',
        () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      await putTodayReadiness(
          payloadJson: '{"sleep":{"window":{"value":{"offset_ms":$nowMs}}}}');
      final app = make();
      app.debugDeriveRun = deriveHook();
      await app.debugAfterDrain();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(sink.shown, isEmpty);
    });

    test('a night with no sleep window (the string "—") still announces',
        () async {
      await putTodayReadiness(
          payloadJson: '{"sleep":{"window":{"value":"—"}}}');
      final app = make();
      app.debugDeriveRun = deriveHook();
      await app.debugAfterDrain();
      await until(() => sink.shown.isNotEmpty, what: 'recovery-ready emitted');
    });

    test('once announced for the day, later passes do not repeat it',
        () async {
      await putTodayReadiness();
      final app = make();
      app.debugDeriveRun = deriveHook();
      app.debugRescanRecent = (_) async => 0;
      await app.debugAfterDrain();
      await until(() => sink.shown.isNotEmpty, what: 'first announcement');
      await app.debugAfterDrain(heavy: true);
      await app.debugAfterDrain();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(sink.shown, hasLength(1));
    });
  });

  group('dispose', () {
    test('cancels the scheduler\'s settle timer', () async {
      final spy = TimerSpy();
      await spy.run(() async {
        final app = AppState.forTesting();
        app.debugDeriveRun = deriveHook();
        app.debugRescanRecent = (_) async => 0;
        app.debugDeriveScheduler.requestHeavy();
        await until(() => app.derivePending, what: 'job queued');
        await until(() => spy.live.isNotEmpty, what: 'settle timer armed');
        app.dispose();
        expect(spy.live, isEmpty);
      });
    });

    test('a request made after dispose never runs a pass', () async {
      final app = AppState.forTesting();
      var runs = 0;
      app.debugDeriveRun = (profile, {bool heavy = false, onDayDone}) async {
        runs++;
        return 0;
      };
      final spy = TimerSpy();
      app.dispose();
      await spy.run(() async {
        app.debugDeriveScheduler.requestHeavy();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(spy.live, isEmpty);
      });
      expect(runs, 0);
      expect(app.deriving, isFalse);
    });
  });
}
