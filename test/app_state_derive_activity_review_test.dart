// refreshActivityReviews / reanalyzeForNapEdit: the durable activity-review
// rollup AppState retries after a busy or failing derive. Timing runs on a fake
// clock: the hooks are plain futures, so no database or real wait is involved.

import 'dart:async';

import 'package:fake_async/fake_async.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart';

import 'support/app_state_derive_harness.dart';

/// A link that reports connected, so openSession takes the foreground-resume
/// path and never reaches the connect sequence.
class _ConnectedEngine extends BleEngine {
  _ConnectedEngine() : super(onRecord: (_, _) async {}, onState: (_) {});

  @override
  bool get isConnected => true;

  @override
  Future<bool> requestForegroundSync() async => false;
}

/// Seconds between a failed attempt and the retry it schedules: 2, 4, 8, 16,
/// then 30 for the rest of the ten.
const _backoffSeconds = [2, 4, 8, 16, 30, 30, 30, 30, 30, 30];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// The app plus a hook that records each call's fake-clock time and answers
  /// from [answers] (then [fallback]); an answer that is an Exception is thrown.
  ({AppState app, List<Duration> at}) make(
    FakeAsync fa, {
    List<Object> answers = const [],
    bool fallback = false,
    BleEngine? engine,
  }) {
    final app = AppState.forTesting(engine: engine);
    final at = <Duration>[];
    app.debugRefreshActivityReviews = (_) async {
      final i = at.length;
      at.add(fa.elapsed);
      final a = i < answers.length ? answers[i] : fallback;
      if (a is Exception) throw a;
      return a as bool;
    };
    return (app: app, at: at);
  }

  group('first attempt', () {
    test('success bumps the revision before and after and leaves no retry',
        () {
      fakeAsync((fa) {
        final m = make(fa, fallback: true);
        final log = SignalLog(m.app);
        unawaited(m.app.refreshActivityReviews());
        fa.flushMicrotasks();
        expect(m.at, hasLength(1));
        expect(log.events, ['r', 'r']);
        expect(fa.pendingTimers, isEmpty);
        m.app.dispose();
      });
    });

    test('an attempt flagged as a retry skips the opening bump', () {
      fakeAsync((fa) {
        final m = make(fa, fallback: true);
        final log = SignalLog(m.app);
        unawaited(m.app.refreshActivityReviews(retry: true));
        fa.flushMicrotasks();
        expect(log.events, ['r']);
        m.app.dispose();
      });
    });

    test('a nap edit is the same call as a non-retry refresh', () {
      fakeAsync((fa) {
        final m = make(fa, fallback: true);
        final log = SignalLog(m.app);
        unawaited(m.app.reanalyzeForNapEdit());
        fa.flushMicrotasks();
        expect(m.at, hasLength(1));
        expect(log.events, ['r', 'r']);
        m.app.dispose();
      });
    });

    test('a nap edit that cannot roll up yet schedules the same backoff', () {
      fakeAsync((fa) {
        final m = make(fa);
        unawaited(m.app.reanalyzeForNapEdit());
        fa.flushMicrotasks();
        expect(fa.pendingTimers, hasLength(1));
        fa.elapse(const Duration(seconds: 2));
        expect(m.at, hasLength(2));
        m.app.dispose();
      });
    });

    test('the future returns once the hook has answered, not after the retry',
        () {
      fakeAsync((fa) {
        final m = make(fa);
        var done = false;
        unawaited(m.app.refreshActivityReviews().then((_) => done = true));
        fa.flushMicrotasks();
        expect(done, isTrue);
        expect(fa.pendingTimers, hasLength(1));
        m.app.dispose();
      });
    });
  });

  group('backoff', () {
    test('a failing rollup retries at 2, 4, 8, 16 then 30 s, ten times, and '
        'stops', () {
      fakeAsync((fa) {
        final m = make(fa);
        unawaited(m.app.refreshActivityReviews());
        fa.flushMicrotasks();
        var expected = Duration.zero;
        final expectedTimes = [expected];
        for (final s in _backoffSeconds) {
          expected += Duration(seconds: s);
          expectedTimes.add(expected);
        }
        fa.elapse(const Duration(minutes: 30));
        expect(m.at, expectedTimes, reason: '1 attempt + 10 retries');
        expect(fa.pendingTimers, isEmpty, reason: 'budget spent, chain over');
        m.app.dispose();
      });
    });

    test('a retry is not scheduled before its delay elapses', () {
      fakeAsync((fa) {
        final m = make(fa);
        unawaited(m.app.refreshActivityReviews());
        fa.flushMicrotasks();
        fa.elapse(const Duration(milliseconds: 1999));
        expect(m.at, hasLength(1));
        fa.elapse(const Duration(milliseconds: 1));
        expect(m.at, hasLength(2));
        m.app.dispose();
      });
    });

    test('a throwing rollup is swallowed and retried like a false answer', () {
      fakeAsync((fa) {
        final m = make(fa, answers: [StateError('busy'), StateError('busy')],
            fallback: true);
        Object? error;
        unawaited(m.app.refreshActivityReviews().catchError((Object e) {
          error = e;
        }));
        fa.flushMicrotasks();
        expect(error, isNull);
        fa.elapse(const Duration(seconds: 6));
        expect(m.at, hasLength(3));
        expect(fa.pendingTimers, isEmpty, reason: 'third answer succeeded');
        m.app.dispose();
      });
    });

    test('success partway through ends the chain and bumps the revision',
        () {
      fakeAsync((fa) {
        final m = make(fa, answers: [false, false], fallback: true);
        final log = SignalLog(m.app);
        unawaited(m.app.refreshActivityReviews());
        fa.flushMicrotasks();
        fa.elapse(const Duration(minutes: 5));
        expect(m.at, hasLength(3));
        // Opening bump, then the success bump; the failed attempts add none.
        expect(log.events, ['r', 'r']);
        expect(fa.pendingTimers, isEmpty);
        m.app.dispose();
      });
    });

    test('a fresh non-retry call replaces the pending retry and restarts the '
        'budget from the short delay', () {
      fakeAsync((fa) {
        final m = make(fa);
        unawaited(m.app.refreshActivityReviews());
        fa.flushMicrotasks();
        fa.elapse(const Duration(seconds: 2 + 4 + 8)); // attempts 0..3 so far
        expect(m.at, hasLength(4));
        final before = fa.elapsed;
        unawaited(m.app.refreshActivityReviews());
        fa.flushMicrotasks();
        expect(fa.pendingTimers, hasLength(1),
            reason: 'the old timer was cancelled, not stacked');
        fa.elapse(const Duration(seconds: 2));
        expect(m.at.last - before, const Duration(seconds: 2));
        m.app.dispose();
      });
    });

    test('a retry-flagged call does not reset the spent budget', () {
      fakeAsync((fa) {
        final m = make(fa);
        unawaited(m.app.refreshActivityReviews());
        fa.flushMicrotasks();
        fa.elapse(const Duration(minutes: 30));
        expect(m.at, hasLength(11));
        unawaited(m.app.refreshActivityReviews(retry: true));
        fa.flushMicrotasks();
        expect(m.at, hasLength(12));
        expect(fa.pendingTimers, isEmpty);
        m.app.dispose();
      });
    });
  });

  group('while the app is backgrounded', () {
    test('a retry-flagged call does nothing', () {
      fakeAsync((fa) {
        final m = make(fa, fallback: true);
        unawaited(m.app.pauseForBackground());
        fa.flushMicrotasks();
        final log = SignalLog(m.app);
        unawaited(m.app.refreshActivityReviews(retry: true));
        fa.flushMicrotasks();
        expect(m.at, isEmpty);
        expect(log.events, isEmpty);
        m.app.dispose();
      });
    });

    test('a user-driven refresh still runs once but schedules no retry', () {
      fakeAsync((fa) {
        final m = make(fa);
        unawaited(m.app.pauseForBackground());
        fa.flushMicrotasks();
        unawaited(m.app.refreshActivityReviews());
        fa.flushMicrotasks();
        expect(m.at, hasLength(1));
        expect(fa.pendingTimers, isEmpty);
        fa.elapse(const Duration(minutes: 5));
        expect(m.at, hasLength(1));
        m.app.dispose();
      });
    });

    test('a retry already pending when the app backgrounds fires into '
        'nothing and the chain ends', () {
      fakeAsync((fa) {
        final m = make(fa);
        unawaited(m.app.refreshActivityReviews());
        fa.flushMicrotasks();
        expect(fa.pendingTimers, hasLength(1));
        unawaited(m.app.pauseForBackground());
        fa.flushMicrotasks();
        fa.elapse(const Duration(minutes: 5));
        expect(m.at, hasLength(1), reason: 'the retry never reached the hook');
        expect(fa.pendingTimers, isEmpty);
        m.app.dispose();
      });
    });
  });

  group('resume', () {
    // openSession on a live link is the foreground-resume path; the reset sits
    // after the busy early return, so a resume that bounces off a held busy
    // does not grant the budget.
    test('opening the app gives a spent chain a fresh budget and a retry '
        'attempt', () {
      fakeAsync((fa) {
        final m = make(fa, engine: _ConnectedEngine());
        m.app.paired = PairedDevice('band', null);
        unawaited(m.app.refreshActivityReviews());
        fa.flushMicrotasks();
        fa.elapse(const Duration(minutes: 30));
        expect(m.at, hasLength(11));

        unawaited(m.app.pauseForBackground());
        fa.flushMicrotasks();
        unawaited(m.app.openSession());
        fa.flushMicrotasks();
        expect(m.at, hasLength(12), reason: 'resume asks once straight away');
        // Resume's own timers (the backfill pull) share the fake clock, so the
        // chain is judged by its attempts: the budget was reset if a full ten
        // more retries follow the failed attempt resume made.
        fa.elapse(const Duration(minutes: 30));
        expect(m.at, hasLength(22), reason: 'a full ten more retries');
        m.app.dispose();
      });
    });

    test('a resume that finds busy held does not touch the budget', () {
      fakeAsync((fa) {
        final m = make(fa, engine: _ConnectedEngine());
        m.app.paired = PairedDevice('band', null);
        unawaited(m.app.refreshActivityReviews());
        fa.flushMicrotasks();
        fa.elapse(const Duration(minutes: 30));
        expect(m.at, hasLength(11));

        unawaited(m.app.pauseForBackground());
        fa.flushMicrotasks();
        m.app.busy = true;
        unawaited(m.app.openSession());
        fa.flushMicrotasks();
        fa.elapse(const Duration(minutes: 30));
        expect(m.at, hasLength(11));
        m.app.dispose();
      });
    });
  });

  group('dispose', () {
    test('cancels the pending retry', () {
      fakeAsync((fa) {
        final m = make(fa);
        unawaited(m.app.refreshActivityReviews());
        fa.flushMicrotasks();
        expect(fa.pendingTimers, hasLength(1));
        m.app.dispose();
        expect(fa.pendingTimers, isEmpty);
        fa.elapse(const Duration(minutes: 5));
        expect(m.at, hasLength(1));
      });
    });

    test('a call after dispose does nothing', () {
      fakeAsync((fa) {
        final m = make(fa);
        m.app.dispose();
        unawaited(m.app.refreshActivityReviews());
        unawaited(m.app.reanalyzeForNapEdit());
        fa.flushMicrotasks();
        expect(m.at, isEmpty);
        expect(fa.pendingTimers, isEmpty);
      });
    });

    test('a rollup still in flight when the app is disposed schedules no '
        'retry', () {
      fakeAsync((fa) {
        final app = AppState.forTesting();
        final gate = Completer<bool>();
        app.debugRefreshActivityReviews = (_) => gate.future;
        unawaited(app.refreshActivityReviews());
        fa.flushMicrotasks();
        app.dispose();
        gate.complete(false);
        fa.flushMicrotasks();
        expect(fa.pendingTimers, isEmpty);
      });
    });
  });
}
