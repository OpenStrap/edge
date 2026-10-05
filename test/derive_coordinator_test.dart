import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/state/derive_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final logs = <String>[];
  var notifies = 0;
  var phoneSteps = 0;
  var recoveryChecks = 0;
  var exports = 0;
  var reclaims = 0;

  setUp(() {
    logs.clear();
    notifies = 0;
    phoneSteps = 0;
    recoveryChecks = 0;
    exports = 0;
    reclaims = 0;
  });

  DeriveCoordinator make({
    bool Function()? background,
    bool Function()? disposed,
    bool healthSync = false,
    Future<int> Function()? runHealthExport,
  }) =>
      DeriveCoordinator(
        // Every test installs a debug hook for the engine calls, so any real
        // engine access is a laziness regression.
        derive: () => throw StateError('derive should stay lazy'),
        profile: () => const Profile(),
        repo: () => null,
        background: background ?? () => false,
        disposed: disposed ?? () => false,
        log: logs.add,
        notify: () => notifies++,
        refreshPhoneStepsToday: () async => phoneSteps++,
        maybeNotifyRecoveryReady: () async => recoveryChecks++,
        runHealthExport: runHealthExport ??
            () async {
              exports++;
              return 2;
            },
        healthSyncEnabled: () => healthSync,
        telemetryConsent: () => false,
        healthShareConsent: () => false,
        maybeReclaimDiskSpace: () async => reclaims++,
      );

  test('constructing the coordinator and its scheduler never touches derive',
      () {
    final coordinator = make();
    addTearDown(coordinator.dispose);
    expect(coordinator.scheduler, isNotNull);
    expect(coordinator.insightsRevision.value, 0);
  });

  test('a light pass notifies, bumps once and skips the heavy-only work',
      () async {
    final coordinator = make();
    addTearDown(coordinator.dispose);
    final calls = <bool>[];
    coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async {
      calls.add(heavy);
      return 0;
    };
    var rescans = 0;
    coordinator.debugRescanRecent = (_) async {
      rescans++;
      return 0;
    };

    await coordinator.afterDrain();
    await Future<void>.delayed(Duration.zero);

    expect(calls, [false]);
    expect(rescans, 0);
    expect(coordinator.insightsRevision.value, 1);
    expect(notifies, 1);
    expect(phoneSteps, 1);
    expect(recoveryChecks, 1);
    expect(reclaims, 0);
    expect(exports, 0);
  });

  test('a heavy pass awaits the rescan, then reclaims disk space', () async {
    final coordinator = make();
    addTearDown(coordinator.dispose);
    coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async => 0;
    final rescan = Completer<int>();
    coordinator.debugRescanRecent = (_) => rescan.future;

    var finished = false;
    final heavy =
        coordinator.afterDrain(heavy: true).then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse, reason: 'the pass must wait for the rescan');
    expect(reclaims, 0);
    final notifiesBeforeRescan = notifies;

    rescan.complete(3);
    await heavy;
    await Future<void>.delayed(Duration.zero);
    expect(finished, isTrue);
    expect(notifies, notifiesBeforeRescan + 1,
        reason: 'a rescan that refreshed days notifies once more');
    expect(reclaims, 1);
  });

  test('a rescan that throws is logged and the pass carries on', () async {
    final coordinator = make(healthSync: true);
    addTearDown(coordinator.dispose);
    coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async => 0;
    coordinator.debugRescanRecent = (_) async => throw StateError('boom');

    await coordinator.afterDrain(heavy: true);
    await Future<void>.delayed(Duration.zero);

    expect(logs.any((l) => l.startsWith('[derive] rescan failed')), isTrue);
    expect(logs.any((l) => l.contains('post-drain failed')), isFalse);
    expect(exports, 1);
    expect(reclaims, 1);
  });

  test('a failing engine run is contained and skips the post-run steps',
      () async {
    final coordinator = make(healthSync: true);
    addTearDown(coordinator.dispose);
    var runs = 0;
    coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async {
      runs++;
      throw StateError('no');
    };

    await coordinator.afterDrain();
    await Future<void>.delayed(Duration.zero);

    expect(runs, 1, reason: 'the hook, not the real engine, ran');
    expect(
        logs.any((l) =>
            l.startsWith('[derive] post-drain failed') && l.contains('no')),
        isTrue);
    expect(coordinator.insightsRevision.value, 0);
    expect(notifies, 0);
    expect(phoneSteps, 0);
    expect(recoveryChecks, 0);
    expect(exports, 0);
  });

  test('per-day progress notifies on the first, every third and the last day',
      () async {
    final coordinator = make();
    addTearDown(coordinator.dispose);
    final notifiedAfter = <int>[];
    coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async {
      for (var i = 1; i <= 7; i++) {
        final before = notifies;
        onDayDone!('d$i', i, 7);
        if (notifies > before) notifiedAfter.add(i);
      }
      return 7;
    };

    await coordinator.afterDrain();

    // Days 1, 3, 6 and 7, then the end-of-pass notification.
    expect(notifiedAfter, [1, 3, 6, 7]);
    expect(notifies, 5);
  });

  test('health export runs only when enabled and logs its day count',
      () async {
    final off = make();
    addTearDown(off.dispose);
    off.debugDeriveRun = (profile, {heavy = false, onDayDone}) async => 0;
    await off.afterDrain();
    await Future<void>.delayed(Duration.zero);
    expect(exports, 0);

    final on = make(healthSync: true);
    addTearDown(on.dispose);
    on.debugDeriveRun = (profile, {heavy = false, onDayDone}) async => 0;
    await on.afterDrain();
    await Future<void>.delayed(Duration.zero);
    expect(exports, 1);
    expect(logs, contains('[health] exported 2 day(s)'));
  });

  test('a throwing health export is logged and never fails the pass',
      () async {
    final coordinator = make(
      healthSync: true,
      runHealthExport: () async => throw StateError('hk'),
    );
    addTearDown(coordinator.dispose);
    coordinator.debugDeriveRun = (profile, {heavy = false, onDayDone}) async => 0;

    await coordinator.afterDrain();
    await Future<void>.delayed(Duration.zero);

    expect(logs.any((l) => l.startsWith('[health] export failed')), isTrue);
    expect(logs.any((l) => l.contains('post-drain failed')), isFalse);
  });

  test('backs off to the cap, skips background retries, and resets on resume',
      () {
    fakeAsync((fa) {
      var background = false;
      final coordinator = make(background: () => background);
      var calls = 0;
      coordinator.debugRefreshActivityReviews = (_) async {
        calls++;
        return false;
      };

      unawaited(coordinator.refreshActivityReviews());
      fa.flushMicrotasks();
      fa.elapse(const Duration(minutes: 30));
      expect(calls, 11, reason: 'the first call plus ten capped retries');
      expect(fa.pendingTimers, isEmpty);

      background = true;
      unawaited(coordinator.refreshActivityReviews(retry: true));
      fa.flushMicrotasks();
      expect(calls, 11);

      background = false;
      coordinator.resetActivityReviewAttempts();
      unawaited(coordinator.refreshActivityReviews(retry: true));
      fa.flushMicrotasks();
      expect(calls, 12);
      expect(fa.pendingTimers, hasLength(1));
      coordinator.dispose();
    });
  });

  test('retries wait 2s, 4s, 8s, 16s and then 30s', () {
    fakeAsync((fa) {
      final coordinator = make();
      var calls = 0;
      coordinator.debugRefreshActivityReviews = (_) async {
        calls++;
        return false;
      };
      unawaited(coordinator.refreshActivityReviews());
      fa.flushMicrotasks();
      var expected = 1;
      for (final seconds in [2, 4, 8, 16, 30, 30]) {
        fa.elapse(Duration(seconds: seconds - 1));
        expect(calls, expected, reason: 'before the ${seconds}s retry');
        fa.elapse(const Duration(seconds: 1));
        expect(calls, ++expected, reason: 'at the ${seconds}s retry');
      }
      coordinator.dispose();
    });
  });

  test('a successful review refresh bumps and stops retrying', () {
    fakeAsync((fa) {
      final coordinator = make();
      coordinator.debugRefreshActivityReviews = (_) async => true;
      unawaited(coordinator.refreshActivityReviews());
      fa.flushMicrotasks();
      // One bump when the refresh starts, one when it lands.
      expect(coordinator.insightsRevision.value, 2);
      expect(fa.pendingTimers, isEmpty);
      coordinator.dispose();
    });
  });

  test('a retry does not bump on entry, and a disposed host does nothing',
      () async {
    var hostDisposed = false;
    final coordinator = make(disposed: () => hostDisposed);
    addTearDown(coordinator.dispose);
    var calls = 0;
    coordinator.debugRefreshActivityReviews = (_) async {
      calls++;
      return true;
    };

    await coordinator.refreshActivityReviews(retry: true);
    expect(calls, 1);
    expect(coordinator.insightsRevision.value, 1);

    hostDisposed = true;
    await coordinator.refreshActivityReviews();
    expect(calls, 1);
    expect(coordinator.insightsRevision.value, 1);
  });

  test('reanalyzeForNapEdit is a fresh, non-retry review refresh', () async {
    final coordinator = make();
    addTearDown(coordinator.dispose);
    var calls = 0;
    coordinator.debugRefreshActivityReviews = (_) async {
      calls++;
      return true;
    };
    await coordinator.reanalyzeForNapEdit();
    expect(calls, 1);
    expect(coordinator.insightsRevision.value, 2);
  });

  test('dispose cancels the retry timer and disposes the revision notifier',
      () {
    fakeAsync((fa) {
      final coordinator = make();
      coordinator.debugRefreshActivityReviews = (_) async => false;
      unawaited(coordinator.refreshActivityReviews());
      fa.flushMicrotasks();
      expect(fa.pendingTimers, hasLength(1));
      final revision = coordinator.insightsRevision;
      coordinator.dispose();
      expect(fa.pendingTimers, isEmpty);
      expect(() => revision.addListener(() {}), throwsA(isA<FlutterError>()));
    });
  });
}
