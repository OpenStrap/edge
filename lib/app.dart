import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'ai/briefing.dart' show BriefingPeriod;
import 'coach/coach_config.dart';
import 'l10n/app_localizations.dart';
import 'notify/notification_service.dart';
import 'notify/tap_router.dart';
import 'state/app_state.dart';
import 'state/locale_controller.dart';
import 'state/prefs.dart';
import 'telemetry/telemetry_service.dart';
import 'theme/theme_controller.dart';
import 'theme/theme_switcher.dart';
import 'widget/widget_service.dart';
import 'ui2/activity/catalogue.dart';
import 'ui2/activity/live.dart';
import 'ui2/onboarding/pairing.dart';
import 'ui2/onboarding/profile_setup.dart';
import 'ui2/onboarding/splash.dart';
import 'ui2/onboarding/welcome.dart';
import 'ui2/profile/alarm.dart';
import 'ui2/profile/profile.dart';
import 'ui2/screens/ai_briefing.dart';
import 'ui2/screens/calm_breathing.dart';
import 'ui2/screens/what_changed.dart';
import 'ui2/screens/health_screen.dart';
import 'ui2/screens/home_screen.dart';
import 'ui2/screens/journal_compose.dart';
import 'ui2/screens/log_workout.dart';
import 'ui2/screens/nutrition_screen.dart';
import 'ui2/screens/wellness_screen.dart';
import 'ui2/screens/workout_screen.dart';
import 'ui2/ui2.dart';

class OpenStrapApp extends StatefulWidget {
  const OpenStrapApp({super.key});
  @override
  State<OpenStrapApp> createState() => _OpenStrapAppState();
}

class _OpenStrapAppState extends State<OpenStrapApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Hand the BYOK provider config to AppState (briefing generation + the
    // key-aware AI notification schedule live there).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppState>().attachCoachConfig(context.read<CoachConfig>());

      final app = context.read<AppState>();
      if (app.isPaired) app.openSession();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    // Keep the app in sync with the OS when the user is on "System".
    context.read<ThemeController>().updatePlatformBrightness(
        WidgetsBinding.instance.platformDispatcher.platformBrightness);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final app = context.read<AppState>();
    if (state == AppLifecycleState.resumed) {
      // The user may have flipped our notification switch either way in OS
      // Settings while we were backgrounded. Drop the cached authorization
      // decision so the next present/schedule re-reads reality — a denial used
      // to latch for the whole process, silencing every notification and
      // scheduled reminder until a full app restart.
      NotificationService.instance.invalidatePermissionCache();
      // A background relaunch while the phone was locked cannot read the
      // keychain, so the BYOK key can be missing from an otherwise healthy
      // process. Coming to the foreground means the phone is unlocked — take
      // the chance to read it. No-op unless a key is known to exist and is
      // currently unreadable.
      unawaited(context.read<CoachConfig>().refreshKeyOnResume());
      app.maybeFinishFromLiveActivity();
      unawaited(app.maybeStopBreathingFromLiveActivity());
      app.refreshAppStatus(); // re-check OTA + admin banner on every foreground
      app.runCadenceChecks(); // evening wind-down / weekly recap nudges (best-effort)
      // A Siri "start breathing" App Intent may have just foregrounded an
      // already-running process (openAppWhenRun doesn't guarantee a fresh
      // launch) — the constructor-time check alone would miss that case.
      unawaited(app.checkPendingSiriRoute());
      // Backups run on foreground, when due — there is no background scheduler
      // that works on both platforms, and a schedule that claims "daily" while
      // delivering whenever the OS feels like it is worse than one that is
      // honest about when it fires.
      unawaited(app.runBackupIfDue());
      // Re-publish the widget snapshot. `has_data` is decided WHEN THE
      // SNAPSHOT IS WRITTEN (WidgetService.push evaluates isStale there), and
      // the widget process never runs Dart — so a snapshot written while fresh
      // stays `has_data: true` forever, and the staleness rule can only ever
      // fire if something re-evaluates it. Foreground is the one moment we
      // know the app is alive and the numbers may have aged: it is cheap (one
      // repository read) and it is what stops a week-old readiness sitting on
      // a lock screen looking current.
      unawaited(WidgetService.refresh(app.repo));
      if (app.isPaired) app.openSession();
    } else if (state == AppLifecycleState.paused) {
      // Backgrounded: hand the band to the iOS restore path so it can wake-and-drain
      // in the background (no-op on Android, where the foreground service holds it).
      app.pauseForBackground();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    final locale = context.watch<LocaleController>();
    return MaterialApp(
      title: 'OpenStrap',
      debugShowCheckedModeBanner: false,
      // The palette is the design system's, the CHOICE is still the user's.
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: theme.materialThemeMode,
      locale: locale.locale, // null = follow the OS locale
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // Runs even when `locale:` above has a user override — Flutter still
      // calls this callback, just with [locale.locale] as the sole
      // "device" candidate instead of the real device list, so an override
      // resolves through the same language-match path below and comes back
      // unchanged (LocaleController only ever holds a bare language code
      // that's already in supportedLocales). Flutter's own default
      // resolution falls back to supportedLocales.first when nothing
      // matches — which is whichever language sorts first alphabetically
      // among our .arb files (currently German), not English. Match by
      // language only (none of our locales carry a country/script code)
      // and fall back to English explicitly instead of leaving that to
      // alphabetical luck.
      localeListResolutionCallback: (deviceLocales, supported) {
        for (final deviceLocale in deviceLocales ?? const <Locale>[]) {
          for (final s in supported) {
            if (s.languageCode == deviceLocale.languageCode) return s;
          }
        }
        return const Locale('en');
      },
      builder: (context, child) =>
          ThemeSwitchOverlay(key: themeSwitchKey, child: child!),
      navigatorObservers: [TelemetryNavigatorObserver()],
      home: const _Gate(),
    );
  }
}

// ══════════════════ THE ONBOARDING GATE ══════════════════

/// The gate, as a pure function of its inputs. Onboarding order bugs are
/// the ones users hit exactly once and never forgive, so this is testable
/// without a band, a database or a widget tree.
///
/// [AppRoute.pairing] short-circuits before AppState ever looks at the
/// profile, so a skipped pairing falls through to profile setup rather than
/// straight to the shell — we still want the four numbers.
///
/// [onboarded] is the difference between "has never had a band" and "has no
/// band right now". `AppState.route` only knows the second: a user who forgets
/// their strap after months of use goes `isPaired == false` →
/// [AppRoute.pairing], and `pairingSkipped` is false for anyone who actually
/// paired, so they landed in FIRST-RUN onboarding with all their data behind
/// it and "Skip for now" as the only way back. Onboarding happens once.
AppRoute resolveRoute(AppRoute route,
    {required bool pairingSkipped,
    required bool profileSeen,
    bool onboarded = false}) {
  var r = route;
  if (onboarded && (r == AppRoute.pairing || r == AppRoute.profile)) {
    return AppRoute.shell;
  }
  if (r == AppRoute.pairing && pairingSkipped) r = AppRoute.profile;
  if (r == AppRoute.profile && profileSeen) return AppRoute.shell;
  return r;
}

/// One-way latch: this install has reached the app itself at least once.
///
/// Kept here rather than on [OnboardingBypass] because it is not a bypass —
/// nothing was skipped. It is the record that onboarding HAPPENED, which is
/// the only thing that distinguishes a lost band from a first run.
const String _kOnboarded = 'onboard.completed';

bool get _onboarded => Prefs.getBool(_kOnboarded, false);
void _markOnboarded() {
  if (!_onboarded) Prefs.setBool(_kOnboarded, true);
}

/// Telemetry-only: the last AppRoute we logged, so the gate's build (which
/// also re-runs on a plain theme flip) doesn't double-log.
AppRoute? _telemetryLastRoute;

class _Gate extends StatelessWidget {
  const _Gate();

  @override
  Widget build(BuildContext context) {
    // SELECT, not watch: rebuild only when the ROUTE actually changes (rare) —
    // not on every ~1 Hz AppState tick (live HR, log lines). Watching the whole
    // AppState here used to repaint the entire home stack every second, which
    // starved the background BLE connection on long idle stretches.
    final raw = context.select<AppState, AppRoute>((a) => a.route);
    return ValueListenableBuilder<int>(
      valueListenable: OnboardingBypass.revision,
      builder: (context, _, _) {
        final route = resolveRoute(raw,
            pairingSkipped: OnboardingBypass.pairingSkipped,
            profileSeen: OnboardingBypass.profileSeen,
            onboarded: _onboarded);
        if (route != _telemetryLastRoute) {
          _telemetryLastRoute = route;
          TelemetryService.instance.setContext('app_route', route.name);
          TelemetryService.instance.breadcrumb('route: ${route.name}');
        }
        final Widget resolved = switch (route) {
          // Underlay while the boot splash covers the loading phase — and what
          // the user lands on if the splash's safety cap fires before init
          // completes.
          AppRoute.loading => const _Loading(),
          AppRoute.failed => const _InitFailed(),
          AppRoute.welcome => const WelcomeScreen(),
          AppRoute.pairing => PairingScreen(
              onSkip: () => OnboardingBypass.mark(OnboardingBypass.kPairing)),
          AppRoute.profile => ProfileSetupScreen(
              onDone: () => OnboardingBypass.mark(OnboardingBypass.kProfile)),
          AppRoute.shell => const _Shell(),
        };
        // Cold-start splash: covers the whole loading phase and cross-fades out
        // the instant AppState finishes initializing, even mid-play. Shown once
        // per launch; BootSplash latches itself off after.
        return BootSplash(ready: route != AppRoute.loading, child: resolved);
      },
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: Center(child: CircularProgressIndicator(color: p.on(C.green))),
    );
  }
}

/// Start-up threw. The one screen whose job is to not be a spinner.
///
/// It names the failure with the actual message rather than a friendlier guess,
/// says the data is still on the device (it is — nothing here deletes, and an
/// unopenable database rebuilds itself in `LocalDb`), and offers the retry.
class _InitFailed extends StatelessWidget {
  const _InitFailed();
  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final app = c.watch<AppState>();
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('OpenStrap could not start',
                    style: F.t2.copyWith(color: p.ink)),
                const SizedBox(height: 8),
                Text(
                  'Your data is still on this device — nothing was deleted. '
                  'This is a start-up step failing, and it will fail the same '
                  'way each launch until it is fixed.',
                  style: F.body.copyWith(color: p.ink2, height: 1.5),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: p.card2,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(
                    app.initError ?? 'No error was recorded.',
                    style: F.cap.copyWith(color: p.ink2),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: app.retryInit,
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════ THE SHELL ══════════════════

/// A notification's tab index → the domain that now owns that content.
///
/// The indices come from `tap_router.dart`, which still speaks the old
/// five-tab vocabulary (Today · Sleep · Heart · Body · Workouts). Sleep, Heart
/// and Body all folded into Health, so three of the five collapse onto one
/// destination. Payloads from older builds keep working, which is the whole
/// point — a notification is scheduled days before it is tapped.
ShellDomain domainForTab(int tab) => switch (tab) {
      1 || 2 || 3 => ShellDomain.health,
      4 => ShellDomain.workout,
      _ => ShellDomain.home,
    };

/// A deep-link sub-screen route → the domain it belongs to.
///
/// Every `kRoute*` in `tap_router.dart` is here, and unknown routes fall back
/// to Home rather than crashing a cold launch on a payload from an older
/// build.
ShellDomain domainForRoute(String route) => switch (routePath(route)) {
      kRouteAiMorning || kRouteAiEvening => ShellDomain.home,
      kRouteJournalCompose || kRouteBreathing => ShellDomain.wellness,
      // Water is a journal field that lives on Nutrition — that is the tab
      // behind the log screen, and where a "back" from it should land.
      kRouteWater => ShellDomain.nutrition,
      // The medication reminder. Wellness owns the Medication tab and its
      // checklist, which is where a dose is actually recorded.
      kRouteMeds => ShellDomain.wellness,
      // The movement/sedentary nudges. Today (Home) is where the steps/rings
      // they point at live; there is no move screen to push, so
      // screenForRoute returns null for it — same shape as /meds below.
      kRouteMovement => ShellDomain.home,
      // Recovery-ready and step-goal notes. Both are about what already lives
      // on Today, and neither has a screen of its own to push.
      kRouteRecovery => ShellDomain.home,
      kRouteSteps => ShellDomain.home,
      kRouteWorkoutSuggestion => ShellDomain.workout,
      // The forgotten-workout nudge. The Workouts tab is the destination
      // itself — the live session bar with its finish control is pinned to
      // the shell there — so screenForRoute stays null for it.
      kRouteWorkoutIdle => ShellDomain.workout,
      // Emitted by the battery forecast (`app_state.dart`) and the weekly
      // recap (`notification_center.dart`), and declared in `tap_router`
      // alongside every other deep link — see the note below.
      kRouteProfile => ShellDomain.home,
      // The two alarm safety notifications. Reached the same way as the
      // battery/band alerts above — Profile lives on Home.
      kRouteAlarm => ShellDomain.home,
      // No recap screen exists. Health is where a week of sleep, strain and
      // recovery actually lives, so it is the nearest true destination — but
      // the notification promises a REPORT, and until one is built the honest
      // fix is upstream, in what that notification claims.
      kRouteRecap => ShellDomain.health,
      _ => ShellDomain.home,
    };

// `/profile` and `/recap` are declared in `tap_router.dart` alongside every
// other deep link. They used to be private literals here, which is exactly why
// both landed on Home: absent from tap_router's table, they produced no screen
// request, so the shell fell back to the tab index and never consulted
// [domainForRoute] at all.

/// The focused screen a deep link pushes on top of its domain, when one
/// exists. Null means the domain itself is the destination.
///
/// `/workouts/suggestion` used to be in that list, and it was the one route
/// where the fallback was a broken promise: "Tap to log it" landed on the
/// plain Workouts tab, because the screen that could log it was deleted with
/// `lib/ui/workouts/` and nothing read `workout_suggestions`. There is a
/// destination again, and confirming on it writes a real session.
///
/// `/ai/*` used to be in that list too. It now lands on the briefing itself,
/// which also carries the exact snapshot that was sent to produce it.
Widget? screenForRoute(String route) => switch (routePath(route)) {
      kRouteAiMorning =>
        const AiBriefingScreen(period: BriefingPeriod.morning),
      kRouteAiEvening =>
        const AiBriefingScreen(period: BriefingPeriod.evening),
      kRouteJournalCompose => const JournalCompose(),
      kRouteBreathing => const CalmBreathing(),
      // The hydration reminder lands on Nutrition, where the water tile carries
      // its own − / + and is beside the food it belongs with. There used to be
      // a whole screen for this one field; it was reachable ONLY from here,
      // which is how the tile that everybody actually used stayed add-only for
      // so long — the thing that could clear a value was behind a notification.
      kRouteWater => const NutritionScreen(),
      // The detected bout, with the three answers to it: log it, adjust the
      // times first, or say it never happened.
      // The medication reminder pushes NOTHING, and still lands on the
      // checklist: it is a SUB-TAB of Wellness, so pushing anything would put
      // a second copy of a shell tab over the shell. `_consume` asks Wellness
      // for the tab instead (`WellnessScreen.tabRequest`) — the deep link is
      // wired, the answer here stays null.
      kRouteMeds => null,
      // A CONSTRUCTOR ARGUMENT is right here and wrong for `/meds` above: this
      // screen is PUSHED by `_consume`, so every tap builds a fresh one and the
      // id reaches it. Wellness is a shell tab kept alive in the IndexedStack,
      // never rebuilt on a tap, which is why that one needs a request notifier.
      kRouteWorkoutSuggestion =>
        WorkoutSuggestionScreen(focusId: routeId(route)),
      // Battery, band and sources all live behind this one.
      kRouteProfile => const ProfileHome(),
      // The alarm safety notifications land where either can actually be
      // fixed — the schedule itself.
      kRouteAlarm => const AlarmScreen(),
      // The weekly recap used to land on the Health tab and push nothing,
      // because there was no recap screen to push. There is now: the sweep's
      // findings, which the app has been computing every night and delivering
      // only as a notification you could dismiss into nothing.
      kRouteRecap => const WhatChangedScreen(),
      _ => null,
    };

class _Shell extends StatefulWidget {
  const _Shell();
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  /// Restore the last-selected tab so a relaunch lands where the user left off.
  late ShellDomain _domain = ShellDomain
      .values[Prefs.getInt(Prefs.shellTab, 0).clamp(0, ShellDomain.values.length - 1)];

  /// AppShell owns its own selection and takes only an `initial`, so a
  /// programmatic jump re-keys it.
  // ponytail: re-keying rebuilds the tab stack, so a deep link loses the
  // scroll position of whatever tab was open. Deep links are rare and arrive
  // from outside the app; give AppShell an external controller if that ever
  // stops being true.
  int _rev = 0;

  AppState? _app;

  @override
  void initState() {
    super.initState();
    // A tapped notification asks for a tab via AppState.navRequest. Jump there,
    // then clear the request so it isn't replayed on rebuild.
    _app = context.read<AppState>();
    _app!.navRequest.addListener(_consumeSoon);
    _app!.screenRequest.addListener(_consumeSoon);
    // Cold launch from a tapped notification: the route may already be set
    // before this shell mounted (so the listener never fired). Consume it once
    // attached.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Reaching the shell IS the end of onboarding. Latched here rather than
      // at the pairing screen because an install that upgraded into this build
      // never saw one.
      _markOnboarded();
      _consume();
    });
  }

  bool _pending = false;

  /// Both requests come from ONE tap and are written one after the other, so
  /// whichever listener fires second used to win — and which one that is
  /// inverts between a warm tap (screen, then nav) and a cold launch (the
  /// post-frame callback, in whatever order it reads them). A `/breathing`
  /// notification therefore landed on Wellness or on Home depending on
  /// whether the app happened to be running. Read the pair together, once
  /// both have landed.
  void _consumeSoon() {
    if (_pending) return;
    _pending = true;
    scheduleMicrotask(() {
      _pending = false;
      _consume();
    });
  }

  void _consume() {
    final app = _app;
    // Leave the request standing if there is no shell to act on it — the next
    // one consumes it in its post-frame callback rather than finding it eaten.
    if (app == null || !mounted) return;
    final s = app.screenRequest.value;
    final tab = app.navRequest.value;
    app.screenRequest.value = null;
    app.navRequest.value = -1;
    // A screen route carries its own domain; the tab index alongside it is
    // the base the payload was built with, not a second destination.
    if (s != null && s.isNotEmpty) {
      _go(domainForRoute(s));
      // A route whose destination is a SUB-tab, which no pushed screen can
      // express. Asked for AFTER `_go` (which may re-key the shell and build a
      // fresh Wellness) and cleared a frame later, so whichever state ends up
      // on screen has seen it — see `WellnessScreen.tabRequest`.
      if (routePath(s) == kRouteMeds) {
        WellnessScreen.tabRequest.value = WellnessScreen.medsTab;
        WidgetsBinding.instance.addPostFrameCallback(
            (_) => WellnessScreen.tabRequest.value = -1);
      }
      final screen = screenForRoute(s);
      if (screen != null) {
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => screen));
      }
      return;
    }
    if (tab >= 0) _go(domainForTab(tab));
  }

  void _go(ShellDomain d) {
    if (d == _domain) return;
    setState(() {
      _domain = d;
      _rev++;
    });
    Prefs.setInt(Prefs.shellTab, d.index);
  }

  @override
  void dispose() {
    _app?.navRequest.removeListener(_consumeSoon);
    _app?.screenRequest.removeListener(_consumeSoon);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // SELECT, not watch: a bool that flips twice a workout, not the ~1 Hz
    // AppState tick.
    final live = context.select<AppState, bool>((a) => a.activeWorkout != null);
    return AppShell(
      key: ValueKey(_rev),
      initial: _domain,
      banner: live ? const _LiveSessionBar() : null,
      onSelect: (d) {
        _domain = d;
        Prefs.setInt(Prefs.shellTab, d.index);
      },
      builder: (c, d) => switch (d) {
        ShellDomain.home => const HomeScreen(),
        ShellDomain.health => const HealthScreen(),
        ShellDomain.nutrition => const NutritionScreen(),
        ShellDomain.workout => const WorkoutScreen(),
        ShellDomain.wellness => const WellnessScreen(),
      },
    );
  }
}

/// The way back into a session that is running while its screen is not on
/// screen — minimised, or left behind when the app was killed and relaunched.
///
/// Without it, leaving the live screen orphaned the session: `activeWorkout`
/// stayed open, every later workout was refused, and the only control that
/// could end it was the iOS Live Activity's Finish button. Android had
/// nothing at all.
///
/// No clock: the elapsed time would be stale the moment it was painted, and a
/// per-second rebuild of the whole shell to keep one number honest is not a
/// trade worth making. The number is on the screen this taps through to.
class _LiveSessionBar extends StatelessWidget {
  const _LiveSessionBar();

  /// The activity behind the open session.
  ///
  /// The draft FIRST (it carries the private flag and the entered weight), but
  /// `activeWorkout.type` as the fallback — a session started by the gesture
  /// path creates no draft, and neither does one rehydrated from a `sessions`
  /// row after a crash. Keying on the draft alone meant both of those left the
  /// workout open with no way to reach or end it, and `startWorkout` refuses
  /// every later workout while one is open.
  static Activity? _activityFor(AppState app) => activityByName(
      LiveDraft.current?.activityKey ?? app.activeWorkout?.type);

  Future<void> _resume(BuildContext c) async {
    final app = c.read<AppState>();
    final draft = LiveDraft.current;
    final a = _activityFor(app);
    if (a == null) return;
    final nav = Navigator.of(c);
    // The lifter's previous and best. Absent renders as "First time on this
    // lift", which would be a false claim on a resumed session.
    final history = await loadSetHistory();
    await nav.push(MaterialPageRoute<void>(
      builder: (_) => liveFor(a,
          private: draft?.private ?? false,
          weightKg: draft?.weightKg,
          host: activityHost(app, history: history)),
    ));
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final app = c.read<AppState>();
    final a = _activityFor(app);
    // A session the app is holding but this build cannot draw — an older
    // build's type key, say. Never nothing: the bar is the ONLY control that
    // can end an open session, and hiding it left the workout open forever
    // with every later one refused. Offer the one action that is certainly
    // right rather than a button that opens the wrong screen.
    if (a == null) {
      return Container(
        decoration: BoxDecoration(
          color: p.card,
          border: Border(top: BorderSide(color: p.line)),
        ),
        child: Pressable(
          semanticLabel: 'Finish the session that is still running',
          onTap: () => app.stopWorkout(),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
            child: Row(children: [
              Expanded(
                child: Text('Session running — tap to finish',
                    style: F.body.copyWith(color: p.ink)),
              ),
              Icon(LucideIcons.square, size: 18, color: p.ink3),
            ]),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: p.card,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: Pressable(
        semanticLabel: 'Back to your ${a.name.toLowerCase()} session',
        onTap: () => _resume(c),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: S.x4, vertical: S.x3),
          child: Row(children: [
            Container(
              width: 30,
              height: 30,
              decoration:
                  BoxDecoration(color: p.wash(a.color), borderRadius: R.rSm),
              child: Icon(a.icon, size: 16, color: p.on(a.color)),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.name,
                        style: F.body.copyWith(
                            color: p.ink, fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text('Session running',
                        style: F.over.copyWith(color: p.ink3)),
                  ]),
            ),
            Icon(LucideIcons.chevronUp, size: 20, color: p.ink3),
          ]),
        ),
      ),
    );
  }
}
