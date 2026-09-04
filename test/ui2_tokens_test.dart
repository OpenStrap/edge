// The token guard for lib/ui2.
//
// A design system is only a system while every screen spends the same
// vocabulary. The one it replaces did not have this test, and the audit found
// the result: 223 call sites on a caption colour that fails AA, raw hex
// scattered through screens, a dozen one-off font sizes, and thirteen infinite
// animation loops with nothing gating them.
//
// None of that is caught by review at the fortieth screen. It is caught here,
// on the first one.
//
// Built on test/support/dart_source.dart so a token named inside a comment or
// a string literal is not a violation — the naive per-line regex this
// replaced flagged its own documentation.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// Where the vocabulary is *defined*. This one file is allowed to write raw
/// colours and sizes; it is the only place they may appear.
const _tokenFile = 'lib/ui2/theme.dart';

/// Where `Pressable` is defined — the one place a raw gesture is legal.
const _gestureFile = 'lib/ui2/grammar.dart';

final _rules = <_Rule>[
  _Rule(
    'raw fontSize:',
    RegExp(r'\bfontSize\s*:'),
    'Type comes from F (F.body, F.cap, F.n34 …). Seven steps, no eighth.',
    allow: {_tokenFile},
  ),
  _Rule(
    'raw Color(0x…)',
    // Fully transparent is not a colour, it is the absence of one, and every
    // theme agrees on it.
    RegExp(r'Color\(0x(?!00000000\))'),
    'Colour comes from C / P. If a new pigment is genuinely needed it is '
        'declared in theme.dart and swept by ui2_contrast_test.',
    allow: {_tokenFile},
  ),
  _Rule(
    'Colors.white / Colors.black',
    RegExp(r'\bColors\.(white|black)\b'),
    'Hard white is a hole in a dark card. Use p.card / p.ink / p.inkOnFill.',
  ),
  _Rule(
    'numeric BorderRadius.circular',
    RegExp(r'BorderRadius\.circular\(\s*\d'),
    'Radii come from R (R.rSm … R.rPill).',
    allow: {_tokenFile},
  ),
  _Rule(
    'infinite .repeat()',
    RegExp(r'\.repeat\s*\('),
    'A loop that never ends cannot be stopped by the reduced-motion gate. '
        'Drive ambient motion from a caller-owned phase value instead — see '
        'BreathRing.t.',
  ),
  _Rule(
    'ungated Duration(',
    // `motion(context, …)` is the gate. Motion.fast/base/slow are the token
    // constants it is fed.
    RegExp(r'Duration\((?!\s*\))'),
    'Durations come from Motion.fast/base/slow and pass through '
        'motion(context, …) so reduced motion collapses them to zero.',
    // home_screen's `_tapGrace` is a `Timer` bridging a tap to the first
    // sync signal, not an animation — reduced motion has no opinion on how
    // long a network round trip gets before the button gives up on it, and
    // `Timer` has no non-`Duration` constructor to dodge this the way
    // beats.dart's wall-clock math does.
    allow: {_tokenFile, 'lib/ui2/screens/home_screen.dart'},
  ),
  _Rule(
    'raw gesture detector',
    // `Listener` is on this list because it was NOT, and the hypnogram scrub
    // walked straight through the gap: a precise continuous drag, no discrete
    // alternative, no semantics, over a silent painter. Raw pointer events are
    // a gesture whatever the widget is called.
    RegExp(r'\b(GestureDetector|InkWell|RawGestureDetector|Listener)\b'),
    'Pressable is the only gesture primitive and Scrubber the only drag — they '
        'are what apply the 44 pt minimum and the slider semantics, so a call '
        'site that bypasses them is a call site that opts out of them.',
    allow: {_gestureFile},
  ),
];

class _Rule {
  final String name;
  final RegExp pattern;
  final String why;
  final Set<String> allow;
  _Rule(this.name, this.pattern, this.why, {this.allow = const {}});
}

void main() {
  final root = Directory('lib/ui2');

  test('lib/ui2 exists and is where the design system lives', () {
    expect(root.existsSync(), isTrue, reason: 'run this from the package root');
    expect(
      root.listSync().whereType<File>().where((f) => f.path.endsWith('.dart')),
      isNotEmpty,
    );
  });

  final files =
      root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final rule in _rules) {
    test('no ${rule.name} outside the token boundary', () {
      final hits = <String>[];
      for (final f in files) {
        final rel = f.path.replaceFirst(RegExp(r'^\./'), '');
        if (rule.allow.contains(rel)) continue;
        final lines = codeLines(f.readAsStringSync());
        for (var i = 0; i < lines.length; i++) {
          if (rule.pattern.hasMatch(lines[i])) {
            hits.add('$rel:${i + 1}  ${lines[i].trim()}');
          }
        }
      }
      expect(hits, isEmpty, reason: '${rule.why}\n\n${hits.join('\n')}');
    });
  }

  test('every ui2 file is reachable from the barrel', () {
    final barrel = File('lib/ui2/ui2.dart').readAsStringSync();
    // The VOCABULARY is what the barrel publishes — the files directly in
    // lib/ui2. Screens live in subdirectories (onboarding/, profile/,
    // screens/) and are imported by the router by path: exporting them from
    // the barrel every screen imports would be a cycle, and a screen nobody
    // can reach is caught by the router failing to compile, not by a grep.
    // The token rules above still sweep every file, subdirectories included.
    for (final f in root.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.dart') || name == 'ui2.dart') continue;
      expect(
        barrel,
        contains("export '$name';"),
        reason:
            '$name is not exported from lib/ui2/ui2.dart — a component '
            'nobody can import is a component nobody will use.',
      );
    }
  });

  test('every component is in the gallery', () {
    final gallery = File('lib/ui2/profile/gallery.dart').readAsStringSync();
    final missing = <String>[];
    for (final f
        in root
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      for (final line in codeLines(f.readAsStringSync())) {
        // Public only. A private class is one file's own scaffolding, not a
        // piece of the vocabulary anybody else can spend.
        final m = RegExp(
          r'^class ([A-Z]\w*) extends St(ateless|ateful)Widget',
        ).firstMatch(line);
        final name = m?.group(1);
        if (name == null || _notComponents.contains(name)) continue;
        if (!gallery.contains(name)) missing.add(name);
      }
    }
    expect(
      missing,
      isEmpty,
      reason:
          'The gallery claims to hold every component in lib/ui2, and '
          'these are not in it:\n  ${missing.join('\n  ')}\n\n'
          'Add a case to gallery.dart, or add the name to _notComponents in '
          'this file with the reason it is a screen and not a component. '
          'A gallery that is only MOSTLY complete is one nobody trusts, and '
          'the sweeps it feeds (overflow at 3.1x, the 44 pt tap floor) only '
          'cover what is in it.',
    );
  });
}

/// Whole screens and routes — the things a gallery cannot put in a scroll
/// because they are `Scaffold`s, own a lifecycle, or read the database. Every
/// name here is deliberate: a new widget that is neither in the gallery nor on
/// this list fails the test above, so the choice has to be made rather than
/// drifted into.
const _notComponents = {
  // shell and routing
  'AppShell', 'Domain', 'GalleryScreen',
  // onboarding routes
  'BootSplash', 'WelcomeScreen', 'WelcomeView', 'PairingScreen', 'PairingView',
  'ProfileSetupScreen', 'ProfileSetupView',
  // profile routes
  'ProfileHome', 'ProfileHomeView', 'MoreSettings', 'MoreSettingsView',
  'NotificationSettings', 'NotificationSettingsView', 'EditProfile',
  'EditProfileView', 'DataScreen', 'AlarmScreen', 'AlarmScreenView',
  'MyDevices', 'MyDevicesView', 'DeviceDetail', 'DeviceDetailView', 'RePair',
  // The strap-buzz relay picker: a Scaffold route over a live
  // NotificationRelay, whose list is whatever the OS notification stream has
  // handed us this session. `BandNotificationsView` is the pure half and is
  // what `band_notifications_test.dart` pumps.
  'BandNotifications', 'BandNotificationsView',
  // Both are Scaffold routes that read the database and ask the OS for a
  // permission on tap — a gallery case would either mock all of that or
  // trigger a real health-store prompt from a screenshot sweep.
  'PhoneImport', 'AutomationSettings',
  // The second-sensor pairing route. A Scaffold that owns a BLE scan, reads
  // the `device` table and asks CoreBluetooth whether AccessorySetupKit has
  // provisioned anything — a gallery case would be a photograph of a fixture,
  // and a screenshot sweep would start a real radio scan. `PairSensorView` is
  // the pure half and is what `pair_sensor_test.dart` pumps, at a real phone
  // width, in each of its states.
  'PairSensorScreen', 'PairSensorView',
  // The unified device picker — first pair, re-pair, and add-a-sensor now
  // all reach this one screen. Same reason as PairSensorScreen above (owns a
  // live BLE scan across every notify-class registry entry at once, reads
  // the `device` table, checks the iOS ASK gate on init) plus its own:
  // `PairingScreen` is one of its sub-routes, and a gallery case pushing
  // into that would try the SAME live-radio work a second time.
  // `DevicePickerView` is the pure half; `device_picker_test.dart` pumps it
  // in each of its states instead.
  'DevicePickerScreen', 'DevicePickerView',
  // The per-signal priority editor. A Scaffold route that reads AppState and
  // `signal_priority` on load (M6) — the gallery has no Provider<AppState>
  // above it, so a case would crash the sweep at its own postFrameCallback
  // rather than render a fixture. No pure half exists yet to pump instead
  // (there is nothing today to hand it — every install has one device); add
  // one and a gallery case together if that changes.
  'SignalPriorityScreen',
  // The double-tap picker. A Scaffold route whose whole content is decided by
  // what the OS answered to a method channel, so a gallery case would be a
  // photograph of a fixture rather than of the screen. Rendered instead by
  // band_gestures_test.dart, at a real phone width, in both the has-native and
  // the native-unreachable state.
  'BandGestures', 'BandGesturesView',
  // FULL-BLEED, so it is a screen element rather than a component: it takes
  // the whole window width back off its parent's padding via OverflowBox. The
  // gallery lays every case out in a ~179 logical-px cell, which is narrower
  // than the card's own copy needs — a golden of it there photographs the
  // fixture squeezing it, not the card. Covered instead by
  // `start_session_card_test.dart`, which renders it at a real phone width and
  // asserts the copy is not truncated and nothing overflows.
  'StartCard',
  // tabs and drill-downs
  'HomeScreen', 'HealthScreen', 'WorkoutScreen', 'NutritionScreen',
  'WellnessScreen', 'CycleTab', 'MetricDetail', 'ReadinessDetail',
  'SleepDetail', 'CircadianDetail', 'DayStrainDetail', 'DayStepsDetail',
  'ZonesDetail',
  // Reads the day bundle AND the raw beat store to draw one night's Poincaré
  // cloud — a gallery case would have to mock 27 000 beat intervals.
  'Beats',
  'Investigate',
  'JournalCompose', 'JournalFindings',
  'LogFoodSheet', 'CalmBreathing',
  // Where the hydration notification lands: a Scaffold route that reads and
  // writes the day's journal metrics. The one control on it — FieldStepper —
  // IS in the gallery.
  // The coach chat and its BYOK setup: Scaffold routes that own an engine, a
  // 120 s network call and the keychain. `CoachFigure` — the part a gallery can
  // actually hold — IS in it.
  'CoachScreen', 'CoachSetup', 'AiBriefingScreen',
  // The two day-scoped Scaffold routes: each resolves a day, then reads the
  // bundle plus three or four stores to fill it. Their BODIES are what a
  // gallery can hold and both are in it as cases — `timeline_day`,
  // `what_changed` and their empty and calibrating states — along with the one
  // row component each is built out of.
  'DayTimelineScreen', 'WhatChangedScreen',
  // Two more day/history Scaffold routes. `NapsScreen` resolves a day, reads
  // the bundle AND `sleep_nap`, and every control on it writes an edit and
  // forces a re-derive; `FindingsLog` is a Scaffold over a recomputed history.
  // The ROWS both are built out of — `nap_row`, `nap_row_none`,
  // `nap_unjudged`, `finding_row`, `finding_row_plain` — are in the gallery.
  'NapsScreen', 'FindingsLog',
  // a live session — a stateful screen with a clock, per archetype
  'LiveShell', 'LiveTick', 'LiveMeasured', 'LiveStrength', 'LiveSwim',
  'LiveFlow', 'LiveMatch', 'LiveInterval',
  // the activity flow: pick → set up → do → summarise → share
  'ActivityPicker', 'ActivitySetup', 'ActivitySummary', 'ShareSheet',
  // The two write routes for a session the band did not capture as it
  // happened. Both are Scaffolds that read `sessions` / `workout_suggestions`
  // and write through the repo; the second also asks the OS for a date and a
  // time picker on tap. Covered by `log_workout_test.dart`, which pumps each
  // at a real phone width against injected rows.
  'WorkoutSuggestionScreen', 'LogWorkout',
};
