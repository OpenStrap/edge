import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../compute/derivation_engine.dart';
import '../compute/derive_scheduler.dart';
import '../compute/profile.dart';
import '../data/local_repository.dart';
import '../telemetry/health_uploader.dart';
import '../telemetry/telemetry_service.dart';
import '../widget/widget_service.dart';

/// One derive pass's engine call (`DerivationEngine.run`'s shape).
typedef DeriveRunHook = Future<int> Function(
  Profile profile, {
  bool heavy,
  void Function(String day, int index, int total)? onDayDone,
});

class DeriveCoordinator {
  DeriveCoordinator({
    required DerivationEngine Function() derive,
    required Profile Function() profile,
    required LocalRepository? Function() repo,
    required bool Function() background,
    required bool Function() disposed,
    required void Function(String line) log,
    required void Function() notify,
    required Future<void> Function() refreshPhoneStepsToday,
    required Future<void> Function() maybeNotifyRecoveryReady,
    required Future<int> Function() runHealthExport,
    required bool Function() healthSyncEnabled,
    required bool Function() telemetryConsent,
    required bool Function() healthShareConsent,
    required Future<void> Function() maybeReclaimDiskSpace,
  })  : _derive = derive,
        _profile = profile,
        _repo = repo,
        _background = background,
        _hostDisposed = disposed,
        _log = log,
        _notify = notify,
        _refreshPhoneStepsToday = refreshPhoneStepsToday,
        _maybeNotifyRecoveryReady = maybeNotifyRecoveryReady,
        _runHealthExport = runHealthExport,
        _healthSyncEnabled = healthSyncEnabled,
        _telemetryConsent = telemetryConsent,
        _healthShareConsent = healthShareConsent,
        _maybeReclaimDiskSpace = maybeReclaimDiskSpace;

  final DerivationEngine Function() _derive;
  final Profile Function() _profile;
  final LocalRepository? Function() _repo;
  final bool Function() _background;
  final bool Function() _hostDisposed;
  final void Function(String line) _log;
  final void Function() _notify;
  final Future<void> Function() _refreshPhoneStepsToday;
  final Future<void> Function() _maybeNotifyRecoveryReady;
  final Future<int> Function() _runHealthExport;
  final bool Function() _healthSyncEnabled;
  final bool Function() _telemetryConsent;
  final bool Function() _healthShareConsent;
  final Future<void> Function() _maybeReclaimDiskSpace;

  bool _closed = false;
  bool get _disposed => _closed || _hostDisposed();

  late final DeriveScheduler scheduler = DeriveScheduler(
    run: ({required DeriveJobKind kind}) =>
        afterDrain(heavy: kind == DeriveJobKind.heavy),
    log: _log,
    onChanged: _notify,
  );

  /// Bumped whenever stored insights change so listeners can re-query without a
  /// full ChangeNotifier repaint.
  final ValueNotifier<int> insightsRevision = ValueNotifier<int>(0);

  /// Stand-ins for the derive engine's per-pass work, so a test can hold or
  /// fail a pass without a substrate. Null (the default) runs the real engine.
  /// Tests only.
  DeriveRunHook? debugDeriveRun;
  Future<int> Function(Profile profile)? debugRescanRecent;
  Future<bool> Function(Profile profile)? debugRefreshActivityReviews;

  /// Compute trigger: kick the DerivationEngine after data is persisted.
  /// [heavy]=false is the bounded light pass (TODAY when raw has reached today,
  /// else the latest pending day); [heavy]=true is the foreground finalize
  /// sweep. Best-effort + non-blocking — never throws into the BLE path.
  /// Refreshes the UI when results land so screens re-read the fresh derived rows.
  Future<void> afterDrain({bool heavy = false}) async {
    final mode = heavy ? 'heavy' : 'light';
    try {
      // Context for whatever crash/ANR report comes next — the derivation
      // engine's heavy per-day compute is isolate-offloaded, but the
      // assembly/UI-refresh wiring around it still runs on the main isolate,
      // so this is real signal if a freeze/ANR correlates with a derive pass.
      TelemetryService.instance.setContext('derive_mode', mode);
      TelemetryService.instance.setContext('derive_active', true);
      TelemetryService.instance.breadcrumb('derive: $mode start');
      // Refresh the UI after EACH day so Today/trends fill in as the sweep runs,
      // not only at the end (a multi-day backfill can be many days of work).
      await TelemetryService.instance.traced('derive_$mode', () {
        final DeriveRunHook run = debugDeriveRun ?? _derive().run;
        return run(
          _profile(),
          heavy: heavy,
          onDayDone: (day, index, total) async {
            if (index == total || index == 1 || index % 3 == 0) {
              _notify();
            }
          },
        );
      });
      TelemetryService.instance.breadcrumb('derive: $mode done');
      // A drain can bank band coverage and a day can have rolled over since the
      // last read — both change which source owns today's steps.
      unawaited(_refreshPhoneStepsToday());
      // The drain that triggered this pass may have landed the 1 Hz window of a
      // workout the app slept through, whose strain/calories were scored from
      // whatever few minutes the foreground tally saw (issue #206). Re-score
      // recent sessions against the substrate now that it is here, so the
      // workout LIST is corrected too and not just a detail screen someone
      // happens to open. Monotone and idempotent — see reconcileSessionScore.
      try {
        final fixed = await _repo()?.rescoreRecentSessions() ?? 0;
        if (fixed > 0) {
          _log('[derive] rescored $fixed session(s) from substrate');
        }
      } catch (e) {
        _log('[derive] session rescore failed: $e');
      }
      bumpInsights();
      _notify(); // screens re-fetch from the derived store
      // Same signal, for the surfaces that can't listen: home/lock-screen
      // widget, Watch mirror, Siri intents (WidgetService.refresh).
      unawaited(WidgetService.refresh(_repo()));
      // "Recovery ready" push, on light passes too: it waits for the settled
      // night (#448), and once a heavy has run before the edge passed the
      // wake, only light drains are left to see it settle.
      unawaited(_maybeNotifyRecoveryReady());
      if (heavy) {
        // Baseline-dirty rescan: new data may have shifted the rolling baseline,
        // so refresh baseline-dependent scalars (readiness/illness/stress) on
        // recent FINALIZED days. Cheap when the baseline is unchanged (a single
        // signature read). Best-effort — never throws into the BLE path.
        // Awaited: it holds the engine's run latch, so a light job drained
        // while it ran would no-op and be marked done. Keeping this job
        // running holds the next one in the queue until the rescan is over.
        try {
          final n = await (debugRescanRecent?.call(_profile()) ??
              _derive().rescanRecent(_profile()));
          if (n > 0) {
            _notify(); // screens re-read the refreshed scalars
          }
        } catch (e) {
          _log('[derive] rescan failed: $e');
        }
      }
      // Continuous health export: push freshly-derived days (incl. TODAY) to Apple
      // Health / Health Connect AS SOON as they're computed — runs on BOTH the
      // light (every drain) and heavy passes, not only on finalize. Idempotent
      // (delete-then-write), best-effort, never throws into the BLE/derive path.
      if (_healthSyncEnabled()) {
        unawaited(() async {
          try {
            final n = await _runHealthExport();
            if (n > 0) _log('[health] exported $n day(s)');
          } catch (e) {
            _log('[health] export failed: $e');
          }
        }());
      }
      // Companion (opt-in): flush any queued telemetry now that we're doing network
      // work anyway, and — on a heavy (finalize) pass — consider the once/day full
      // .db upload (itself gated on Wi-Fi + charging + >24h). Both best-effort.
      if (_telemetryConsent()) unawaited(TelemetryService.instance.flush());
      if (heavy && _healthShareConsent()) {
        unawaited(HealthUploader.instance.maybeUpload(consented: true));
      }
      if (heavy) unawaited(_maybeReclaimDiskSpace());
    } catch (e, st) {
      _log('[derive] post-drain failed: $e');
      // Was silently swallowed before — this is a real pipeline failure
      // (derive/health-export/etc.) that Firebase never saw. Non-fatal, not
      // fatal: the app keeps running, but this is worth knowing about.
      TelemetryService.instance.recordNonFatal(e, st, reason: 'post_drain_failed');
    } finally {
      TelemetryService.instance.setContext('derive_active', false);
    }
  }

  /// Say that the DURABLE data changed, so every screen reading it re-reads.
  ///
  /// Public because the writers are not all in here: the log-workout sheet
  /// writes a session, and an import writes days, sessions and journal rows.
  /// `notifyListeners` is NOT that signal — it also ticks at ~1 Hz with live
  /// HR, so screens listen to this instead and re-read only when something
  /// actually landed.
  void bumpInsights() {
    insightsRevision.value = insightsRevision.value + 1;
  }

  Timer? _activityReviewRetry;
  int _activityReviewAttempts = 0;
  Future<void> refreshActivityReviews({bool retry = false}) async {
    // Backgrounded retries would run the cross-day rollup the derive
    // scheduler defers; the resume hook picks the durable jobs back up.
    if (_disposed || (retry && _background())) return;
    _activityReviewRetry?.cancel();
    if (!retry) {
      _activityReviewAttempts = 0;
      bumpInsights();
    }
    try {
      if (await (debugRefreshActivityReviews?.call(_profile()) ??
          _derive().refreshActivityReviews(_profile()))) {
        _activityReviewAttempts = 0;
        bumpInsights();
        return;
      }
    } catch (e) {
      _log('[activity-review] refresh deferred: $e');
    }
    // A long derive holds the engine; back off 2s → 30s instead of polling,
    // and stop after a few minutes so a rollup that keeps failing is left to
    // the next resume or review change rather than looping all day.
    if (!_disposed && !_background() && _activityReviewAttempts < 10) {
      final delay = Duration(
          seconds: math.min(30, 2 << math.min(_activityReviewAttempts, 4)));
      _activityReviewAttempts++;
      _activityReviewRetry = Timer(delay, () => unawaited(refreshActivityReviews(retry: true)));
    }
  }

  /// Re-derive after a nap edit. Same machinery as a sleep-override change —
  /// nap minutes feed sleep need and sleep debt, so an edit is a recompute
  /// rather than a redraw, and the engine force-includes nap-edit days even
  /// when they are finalized.
  Future<void> reanalyzeForNapEdit() => refreshActivityReviews();

  void resetActivityReviewAttempts() {
    _activityReviewAttempts = 0;
  }

  void cancelActivityReviewRetry() {
    _activityReviewRetry?.cancel();
  }

  void disposeScheduler() {
    scheduler.dispose();
  }

  void disposeInsightsRevision() {
    insightsRevision.dispose();
  }

  void dispose() {
    _closed = true;
    cancelActivityReviewRetry();
    disposeScheduler();
    disposeInsightsRevision();
  }
}
