// Widget bridge — writes a small snapshot of today's metrics into the shared App
// Group so the iOS WidgetKit extension (and Android widget) can render them with
// no network. Called whenever the app loads /today or finishes a sync. The widget
// process reads these keys; it never runs Dart.
//
// The App Group id MUST match the one set in Xcode (Runner + widget targets) and
// in the Swift suite name. See guides/IOS_INSTALLATION.md.

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:flutter/services.dart';

import '../data/local_repository.dart';
import '../models/metric.dart';
import '../models/payloads.dart';
import '../ui2/screens/home_screen.dart' show hm, readinessBand;

class WidgetService {
  static const _platform = MethodChannel('openstrap/ios_config');

  /// Fallback App Group id. iOS builds read the configured value from Info.plist.
  static const String fallbackAppGroupId = String.fromEnvironment(
    'APP_GROUP_IDENTIFIER',
    defaultValue: 'group.com.example.openstrap',
  );
  static String appGroupId = fallbackAppGroupId;

  /// WidgetKit "kind" (Swift) / Android provider class name.
  static const String _iOSName = 'OpenStrapWidget';

  /// WidgetKit "kind" for the lock-screen Band Battery widget (Swift).
  static const String _batteryIOSName = 'OpenStrapBatteryWidget';
  static const String _androidName = 'OpenStrapWidgetProvider';

  /// Android provider class for the Band Battery widget.
  static const String _batteryAndroidName = 'OpenStrapBatteryWidgetProvider';

  /// The other two faces on the same snapshot: last night's sleep, and the
  /// overnight autonomic pair (HRV + resting HR). They read the keys [push]
  /// writes, so they reload with it — a widget left holding yesterday because
  /// nobody told it to re-read is the failure this list exists to stop.
  static const List<(String, String)> _snapshotWidgets = [
    (_iOSName, _androidName),
    ('OpenStrapSleepWidget', 'SleepWidgetProvider'),
    ('OpenStrapOvernightWidget', 'OvernightWidgetProvider'),
  ];

  static Future<void> _reloadSnapshotWidgets() async {
    for (final (ios, android) in _snapshotWidgets) {
      await HomeWidget.updateWidget(iOSName: ios, androidName: android);
    }
  }

  static bool _inited = false;
  static Future<void> init() async {
    if (_inited) return;
    try {
      final configured = await _platform.invokeMethod<String>(
        'appGroupIdentifier',
      );
      if (configured != null && configured.isNotEmpty) {
        appGroupId = configured;
      }
      await HomeWidget.setAppGroupId(appGroupId);
      _inited = true;
    } catch (_) {
      /* platform without widgets — ignore */
    }
  }

  /// Rebuild the snapshot from the derived store and publish it.
  ///
  /// THE entry point — [push] is the writer underneath. Call it on the one
  /// signal that changes what the widget should say: a completed derivation.
  /// It had exactly one caller left (the iOS BGTask); the foreground caller was
  /// `today_screen.dart`'s fetch, which was deleted with the old UI, so on
  /// Android nothing refreshed the home widget, the Watch mirror or the Siri
  /// intents at all — they answered with whatever the last BGTask wake wrote.
  ///
  /// Best-effort; never throws into the caller.
  static Future<void> refresh(LocalRepository? repo) async {
    if (repo == null) return;
    try {
      await push(TodayData.fromJson(await repo.getToday()));
    } catch (_) {/* the widget is a mirror; it must never break its source */}
  }

  /// True when [t] is describing a day that is more than one calendar day
  /// behind [now] — i.e. the app has not derived anything for over 24 h and the
  /// numbers are not "today's" by any reading.
  ///
  /// LAST NIGHT'S sleep shown during today is NOT stale: that is the normal
  /// state of every metric here until the next night lands, which is why this
  /// allows a one-day lag rather than demanding an exact match. Returns false
  /// when the payload carries no status block — an unknown age is not a claim
  /// of staleness.
  @visibleForTesting
  static bool isStale(TodayData t, {DateTime? now}) {
    final s = t.status;
    if (s == null) return false;
    final day = _parseDay(s.overnightDay ?? s.activityDay ?? s.todayDay);
    if (day == null) return false;
    final today = now ?? DateTime.now();
    return DateTime(today.year, today.month, today.day)
            .difference(day)
            .inDays >
        1;
  }

  /// 'yyyy-mm-dd' → local midnight. Null for anything else.
  static DateTime? _parseDay(String? label) {
    if (label == null) return null;
    final p = label.split('-');
    if (p.length != 3) return null;
    final y = int.tryParse(p[0]), m = int.tryParse(p[1]), d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  /// Fingerprint of the last snapshot that fully landed (all keys + reload +
  /// Watch sync). The change gate below — same pattern as [pushBattery]'s
  /// caller — because push() runs after EVERY derive pass, and an unchanged
  /// snapshot was still ~15 binder calls, a native widget re-render broadcast,
  /// and a WCSession transfer. `updated_at` is deliberately excluded: it is
  /// write-time metadata, and any genuinely new data moves at least one value.
  static String? _lastPushFingerprint;

  /// The keys the change gate fingerprints, IN ORDER. Documentation AND the
  /// test hook: `test/battery_audit_policy_test.dart` asserts every key
  /// [push] writes appears here, because a written-but-unfingerprinted key
  /// silently freezes until its value changes by accident. Keep both sides
  /// in lockstep when adding a key.
  @visibleForTesting
  static const List<String> fingerprintKeyOrder = [
    'statusDay',
    'has_data',
    'readiness',
    'readiness_tier',
    'readiness_band',
    'hrv',
    'hrv_baseline',
    'strain',
    'sleep_min',
    'sleep_need_min',
    'rhr',
    'sleep_efficiency',
    'overnight_why',
    'coach_line',
    'ring_recovery_state',
    'ring_recovery_value',
    'ring_recovery_sub',
    'ring_recovery_why',
    'ring_recovery_frac',
    'ring_strain_state',
    'ring_strain_value',
    'ring_strain_sub',
    'ring_strain_why',
    'ring_strain_frac',
    'ring_sleep_state',
    'ring_sleep_value',
    'ring_sleep_sub',
    'ring_sleep_why',
    'ring_sleep_frac',
    // 'updated_at' deliberately absent: write-time metadata. Any genuinely
    // new data moves at least one fingerprinted value.
  ];

  /// Push the latest snapshot and trigger a widget reload. Best-effort; never
  /// throws into the caller. Sentinels: ints use -1 / strings use '' for "no data".
  static Future<void> push(TodayData t) async {
    try {
      await init();
      // WHICH NIGHT IS THIS. `getToday` holds the last night that scored over
      // until today's settles, so every morning before the first sync the
      // overnight block belongs to the night BEFORE last. Home refuses those
      // numbers rather than printing them in the today slot (`overnightMetric`
      // in lib/ui2/screens/home_screen.dart) — a figure in the today slot is
      // read as today's before any caption under it is, and that is even truer
      // on a home screen than in the app. So the same refusal happens here, and
      // the reason travels in the numbers' place.
      final heldWhy = _heldOverWhy(t.status);
      Metric ov(Metric m) => heldWhy == null ? m : Metric(note: heldWhy);

      final readiness = ov(t.readiness);
      // The DAY's strain, not the night's — Home does not refuse it either
      // (home_screen.dart: `strain: metricOf(d('strain'))`).
      final s = t.strain;
      final sleep = ov(t.sleepDuration);
      final need = t.sleepNeed;
      final eff = ov(t.sleepEfficiency);
      final rhr = ov(t.restingHr);
      final hrv = heldWhy == null ? t.hrv : null;

      // has_data is the ONE flag every native reader gates on (the WidgetKit
      // home + lock-screen widgets, the Watch mirror, the Siri intents), and it
      // is the only way this side can say "don't show a number" to any of them.
      // A snapshot the app KNOWS is over a day old must not sit on a lock
      // screen looking current — the widget's own no-data state is the honest
      // answer, and the alternative is a readiness score from last week with
      // nothing on it to say so.
      Future<void> setI(String k, int v) =>
          HomeWidget.saveWidgetData<int>(k, v);

      // Resolve every value first — the change gate below needs the WHOLE
      // snapshot before it decides anything. has_data is the ONE flag every
      // native reader gates on (the WidgetKit home + lock-screen widgets, the
      // Watch mirror, the Siri intents); a snapshot the app KNOWS is over a
      // day old must not sit on a lock screen looking current.
      final hasData = !t.isEmpty && !isStale(t);
      // Headline composite Readiness — the Recovery ring on Home.
      final rv = readiness.isEmpty ? null : readiness.value;
      final readinessInt = rv == null ? -1 : rv.round();
      final band = readinessBand(rv);
      final tier = band.tier;
      final bandLabel = tier < 0 ? '' : band.label;
      final hrvV = hrv == null ? -1 : hrv.rmssd.round();
      final hrvBase = hrv?.baseline == null ? -1 : hrv!.baseline!.round();
      final strainV = s.isEmpty ? -1.0 : s.value!.toDouble();
      final sleepMin = sleep.isEmpty ? -1 : sleep.value!.round();
      final needMin = need.isEmpty ? -1 : need.value!.round();
      final rhrV = rhr.isEmpty ? -1 : rhr.value!.round();
      final effMin = eff.isEmpty ? -1 : eff.value!.round();
      final overnightWhy = heldWhy ?? '';
      final coachLine = _coachLine(t.coach);
      // The day this snapshot describes leads the fingerprint — the SAME
      // field `isStale` reads. Without it, two consecutive days with
      // identical rounded metrics produce the same fingerprint, the push is
      // skipped, `updated_at` never advances, and the native `fresh` check
      // (updatedAt + 26 h) flips to "No recent data" on day 2 despite a
      // clean current-day sync. Including it guarantees a new day always
      // pushes while keeping the within-day skip that is the point of the
      // gate.
      final statusDay = t.status?.overnightDay ??
          t.status?.activityDay ??
          t.status?.todayDay ??
          '';

      // THE THREE HOME RINGS, RESOLVED HERE. Recovery · Strain · Sleep, the
      // same trio and the same four states as `RingTrio` on Home. Resolved in
      // Dart rather than three times in Swift, Kotlin and Watch Swift for the
      // reason `readiness_tier` already exists: a rule copied into four build
      // targets is four rules.
      final rings = [
        rv == null
            ? _gapRing('recovery', readiness, 'Not scored')
            : _Ring('recovery',
                value: '${rv.round()}',
                sub: band.label,
                frac: rv / 100),
        s.isEmpty
            // 0-21 is the scale's own ceiling, not a target invented here.
            ? _gapRing('strain', s, 'No strain', unit: 'days')
            : _Ring('strain',
                value: s.value!.toStringAsFixed(1),
                sub: 'of 21',
                frac: s.value! / 21),
        sleep.isEmpty
            ? _gapRing('sleep', sleep, 'No sleep',
                fallbackWhy: 'No night long enough to score was recorded.')
            : _Ring('sleep',
                value: hm(sleep.value),
                sub: needMin <= 0 ? 'No target yet' : 'of ${hm(need.value)}',
                frac: needMin <= 0 || sleep.isEmpty
                    ? null
                    : sleep.value! / need.value!),
      ];

      // THE CHANGE GATE. push() runs after EVERY derive pass; an unchanged
      // snapshot still costs ~30 binder calls, a native widget re-render
      // broadcast and a WCSession transfer. The fingerprint covers EVERY key
      // written below — a key missing here is a key that silently freezes,
      // which already bit once inside this PR when #261 added ring_* /
      // sleep_efficiency to push() and the fingerprint did not know. When you
      // add a key above, add it HERE too. `updated_at` is deliberately
      // excluded: write-time metadata, and any genuinely new data moves at
      // least one value in the list.
      final fpValues = <Object>[
        statusDay,
        hasData,
        readinessInt,
        tier,
        bandLabel,
        hrvV,
        hrvBase,
        strainV,
        sleepMin,
        needMin,
        rhrV,
        effMin,
        overnightWhy,
        coachLine,
        for (final r in rings) ...[r.state, r.value, r.sub, r.why, r.frac],
      ];
      assert(
        fpValues.length == fingerprintKeyOrder.length,
        'widget fingerprint out of sync with push() — add new keys to '
        'BOTH the writes above and fingerprintKeyOrder',
      );
      final fp = fpValues.join('|');
      if (fp == _lastPushFingerprint) return;

      await HomeWidget.saveWidgetData<bool>('has_data', hasData);
      await setI('readiness', readinessInt);
      await setI('readiness_tier', tier);
      await HomeWidget.saveWidgetData<String>('readiness_band', bandLabel);
      await setI('hrv', hrvV);
      await setI('hrv_baseline', hrvBase);
      await HomeWidget.saveWidgetData<double>('strain', strainV);
      await setI('sleep_min', sleepMin);
      await setI('sleep_need_min', needMin);
      await setI('rhr', rhrV);
      await setI('sleep_efficiency', effMin);
      await HomeWidget.saveWidgetData<String>('overnight_why', overnightWhy);
      await HomeWidget.saveWidgetData<String>('coach_line', coachLine);
      for (final r in rings) {
        await setI('ring_${r.key}_state', r.state);
        await HomeWidget.saveWidgetData<String>('ring_${r.key}_value', r.value);
        await HomeWidget.saveWidgetData<String>('ring_${r.key}_sub', r.sub);
        await HomeWidget.saveWidgetData<String>('ring_${r.key}_why', r.why);
        await HomeWidget.saveWidgetData<double>('ring_${r.key}_frac', r.frac);
      }
      await setI('updated_at', DateTime.now().millisecondsSinceEpoch ~/ 1000);

      await _reloadSnapshotWidgets();
      await _syncWatch();
      // Only after everything landed — a mid-write failure must retry on the
      // next push, not be remembered as done. The Watch leg is best-effort:
      // `_syncWatch` always resolves and WatchBridge uses updateApplicationContext
      // (WCSession re-delivers the latest state on reconnect), so a transient
      // WCSession failure self-heals on the next push — and the day-in-fingerprint
      // above guarantees a push at least once per day.
      _lastPushFingerprint = fp;
    } catch (_) {
      /* widgets unavailable / not configured yet — ignore */
    }
  }

  /// Blank the App Group snapshot — home widget, lock-screen battery widget,
  /// Watch mirror and the Siri intents all read it.
  ///
  /// Part of "Delete everything". These surfaces never run Dart, so nothing
  /// else can correct them: without this the home screen kept showing the
  /// readiness, sleep and HRV of a database that no longer existed, and the
  /// Watch kept mirroring it, indefinitely.
  ///
  /// `has_data: false` is the one flag every native reader gates on, so it
  /// alone is sufficient — the rest is cleared so no stale value survives to be
  /// read by some future reader that forgets to check the flag.
  static Future<void> clear() async {
    try {
      await init();
      // The change gate must not swallow the first push after a wipe.
      _lastPushFingerprint = null;
      await HomeWidget.saveWidgetData<bool>('has_data', false);
      for (final k in const [
        'readiness',
        'readiness_tier',
        'hrv',
        'hrv_baseline',
        'sleep_min',
        'sleep_need_min',
        'sleep_efficiency',
        'rhr',
        'batt_pct',
      ]) {
        await HomeWidget.saveWidgetData<int>(k, -1);
      }
      await HomeWidget.saveWidgetData<double>('strain', -1.0);
      // The three resolved home rings. `state: 2` with no reason and no arc is
      // the honest shape of a wiped database — not a ring reporting zero.
      for (final r in const ['recovery', 'strain', 'sleep']) {
        await HomeWidget.saveWidgetData<int>('ring_${r}_state', 2);
        await HomeWidget.saveWidgetData<double>('ring_${r}_frac', -1.0);
        for (final f in const ['value', 'sub', 'why']) {
          await HomeWidget.saveWidgetData<String>('ring_${r}_$f', '');
        }
      }
      for (final k in const [
        'readiness_band',
        'overnight_why',
        'coach_line',
        'batt_name',
        // A route a Siri intent asked for before the wipe is not a route we
        // still owe anybody.
        'pending_route',
      ]) {
        await HomeWidget.saveWidgetData<String>(k, '');
      }
      // The two App Intent latches. They are set by the widget process and
      // consumed by Dart on the next resume, so "Delete everything" used to
      // leave an armed end_session on disk that killed the NEXT workout.
      for (final k in const [
        'batt_charging',
        'end_session',
        'end_breathing_session',
        'enable_tomorrow_alarm',
      ]) {
        await HomeWidget.saveWidgetData<bool>(k, false);
      }
      await _reloadSnapshotWidgets();
      await HomeWidget.updateWidget(
        iOSName: _batteryIOSName,
        androidName: _batteryAndroidName,
      );
      await _syncWatch();
    } catch (_) {
      /* widgets unavailable / not configured yet — ignore */
    }
  }

  /// Mirror the just-written App Group snapshot to the paired Apple Watch
  /// (iOS only; no-op elsewhere or without a watch). One source of truth: the
  /// native side reads the same App Group keys and pushes them over WCSession.
  static Future<void> _syncWatch() async {
    try {
      await _platform.invokeMethod('syncWatch');
    } catch (_) {
      /* not iOS / no watch / channel absent — ignore */
    }
  }

  /// Push the band's battery snapshot for the lock-screen Band Battery widget.
  /// Battery is a live BLE value (not in /today), so that widget never refreshes
  /// over the network — it renders whatever we last wrote here. Call from the
  /// device-state hook, but only when pct/charging actually changed (the hook
  /// fires ~1 Hz on live HR; reloading the widget every tick is wasteful).
  /// Sentinel: pct -1 = never seen the band. [name] is the strap's advertising
  /// name (the widget falls back to "Strap" when empty/null).
  static Future<void> pushBattery(int? pct, bool? charging, String? name) async {
    try {
      await init();
      await HomeWidget.saveWidgetData<int>('batt_pct', pct ?? -1);
      await HomeWidget.saveWidgetData<bool>('batt_charging', charging ?? false);
      await HomeWidget.saveWidgetData<String>('batt_name', name ?? '');
      await HomeWidget.saveWidgetData<int>(
          'batt_at', DateTime.now().millisecondsSinceEpoch ~/ 1000);
      await HomeWidget.updateWidget(
          iOSName: _batteryIOSName, androidName: _batteryAndroidName);
      await _syncWatch();
    } catch (_) {/* widgets unavailable / not configured yet — ignore */}
  }

  /// Tell the iOS widget + Live Activity which appearance the app is rendering
  /// (Ember on Paper vs Char) so those native surfaces match — including when the
  /// user overrides the OS in-app. Reloads the home widget immediately; the Live
  /// Activity picks it up on its next (frequent) content-state update.
  static Future<void> setThemeDark(bool dark) async {
    try {
      await init();
      await HomeWidget.saveWidgetData<bool>('theme_dark', dark);
      await _reloadSnapshotWidgets();
      // The battery widget shares the Ember/Char surface — retheme it too.
      await HomeWidget.updateWidget(
        iOSName: _batteryIOSName,
        androidName: _batteryAndroidName,
      );
    } catch (_) {
      /* widgets unavailable — ignore */
    }
  }

  /// True once (and clears) if the Live Activity's Finish button was tapped.
  /// The App Intent sets `end_session` in the App Group; we consume it on resume.
  static Future<bool> consumeEndSessionFlag() async {
    try {
      await init();
      final v = await HomeWidget.getWidgetData<bool>(
        'end_session',
        defaultValue: false,
      );
      if (v == true) {
        await HomeWidget.saveWidgetData<bool>('end_session', false);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Non-null once (and clears) if a Siri/Shortcuts App Intent asked to open a
  /// specific in-app screen (e.g. StartBreathingIntent sets `pending_route` =
  /// '/breathing' in the App Group before launching the app). Same
  /// App-Group-flag pattern as [consumeEndSessionFlag]. Feed the result
  /// through the normal tap-route pipeline (AppState._handleTapRoute /
  /// tap_router.dart) — never invent a separate navigation path.
  static Future<String?> consumePendingRoute() async {
    try {
      await init();
      final v = await HomeWidget.getWidgetData<String>(
        'pending_route',
        defaultValue: '',
      );
      if (v != null && v.isNotEmpty) {
        await HomeWidget.saveWidgetData<String>('pending_route', '');
        return v;
      }
    } catch (_) {}
    return null;
  }

  /// True once (and clears) if EnableTomorrowAlarmIntent asked to turn on
  /// tomorrow's weekday slot in the weekly alarm schedule. Same
  /// App-Group-flag pattern as [consumeEndSessionFlag] — the widget process
  /// cannot reach the band itself (no BLE), so it only latches the request;
  /// AppState.checkPendingSiriRoute does the real `setScheduleDay` write on
  /// launch/resume.
  static Future<bool> consumeEnableTomorrowAlarmFlag() async {
    try {
      await init();
      final v = await HomeWidget.getWidgetData<bool>(
        'enable_tomorrow_alarm',
        defaultValue: false,
      );
      if (v == true) {
        await HomeWidget.saveWidgetData<bool>('enable_tomorrow_alarm', false);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// True once (and clears) if the BREATHING Live Activity's stop button was
  /// tapped. A separate flag (`end_breathing_session`) from the workout's
  /// `end_session` — EndBreathingIntent in OpenStrapBreathingLiveActivity.swift
  /// sets it; two independent Live Activities must never share one flag.
  static Future<bool> consumeEndBreathingFlag() async {
    try {
      await init();
      final v = await HomeWidget.getWidgetData<bool>(
        'end_breathing_session',
        defaultValue: false,
      );
      if (v == true) {
        await HomeWidget.saveWidgetData<bool>('end_breathing_session', false);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Why the overnight block on offer is not today's, or null when it is.
  ///
  /// Two absences that are not interchangeable and the same two sentences
  /// `staleOvernightNote` uses on Home — one resolves on its own, the other
  /// wants a sync. Written out here rather than imported because that helper
  /// takes the raw `getToday()` map and this seam is handed the parsed payload.
  static String? _heldOverWhy(TodayStatus? s) {
    if (s == null || !s.showingPriorOvernight) return null;
    return s.overnightBuilding
        ? 'Last night is still being worked out.'
        : 'Nothing from last night has reached the app yet.';
  }

  /// The absent half of a ring: CALIBRATING when the note says the gate is a
  /// baseline still filling — the one absence that is progress and can honestly
  /// draw an arc — otherwise the word and the pipeline's own reason.
  /// Mirrors `_gap` in lib/ui2/screens/home_screen.dart.
  static _Ring _gapRing(String key, Metric m, String word,
      {String unit = 'nights', String fallbackWhy = ''}) {
    final counts = baselineCountsFromNote(m.note);
    if (counts != null) {
      return _Ring(key,
          state: 1,
          value: 'Calibrating',
          sub: '${counts.have} of ${counts.need} $unit',
          frac: (counts.have / counts.need).clamp(0.0, 1.0));
    }
    return _Ring(key,
        state: 2,
        value: word,
        // THE PIPELINE'S REASON FIRST, a sentence written here second, and
        // where there is neither the ring says it does not know rather than
        // guessing a cause.
        why: whyFromNote(m.note, unit: unit) ??
            (fallbackWhy.isNotEmpty
                ? fallbackWhy
                : 'Nothing recorded says why this is missing.'));
  }

  static String _coachLine(CoachData? c) {
    if (c == null) return '';
    if (c.plan.isNotEmpty) return c.plan.first.title;
    final tgt = c.strainTarget;
    if (tgt != null) return 'Aim for strain ${tgt.value.toStringAsFixed(0)}';
    return c.summary;
  }
}

/// One home ring as the native surfaces receive it: already-formatted text, a
/// sweep, and which of the four states it is in. Nothing downstream of this
/// decides what a metric means.
class _Ring {
  final String key;

  /// 0 measured · 1 calibrating (arc is progress, drawn muted) · 2 absent.
  final int state;

  /// The number, or the absence in words. Never a bare dash and never empty:
  /// a widget is the surface most likely to be read out of context, and a blank
  /// circle says nothing at all.
  final String value;

  /// What the number is out of ("of 21", "of 7h 30m", the readiness band), or
  /// the calibration count.
  final String sub;

  /// The pipeline's own reason, absent rings only. '' otherwise.
  final String why;

  /// What to sweep, 0…1 — negative when there is nothing honest to sweep.
  final double frac;

  /// CLAMPED HERE, not at the three call sites. Sleeping longer than your need
  /// is a fraction above 1, and the native readers take this as a sweep — an
  /// arc that laps itself, or a progress bar that draws past its own end,
  /// depending on which of the four targets is reading. The number the ring
  /// shows is the real one ("8h 10m of 7h 30m"); only the arc is bounded.
  _Ring(this.key,
      {this.state = 0,
      required this.value,
      this.sub = '',
      this.why = '',
      double? frac})
      : frac = frac == null ? -1 : frac.clamp(0.0, 1.0);
}
