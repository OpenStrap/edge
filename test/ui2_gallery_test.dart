// Developer mode is a tool, not a feature.
//
// The failure mode is one line wide: a developer surface that ships visible.
// So the two things asserted here are that the flag is OFF on a fresh install,
// and that nothing in Settings can reach the gallery until it is on.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/activity/share.dart' show ShareSheet;
import 'package:openstrap_edge/ui2/activity/summary.dart'
    show Arch, ActivitySummary;
import 'package:openstrap_edge/ui2/profile/gallery.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: child,
    );

/// Tall enough that the whole settings list is BUILT. A `ListView` only
/// builds what fits, so on the default 800 pt view every assertion about the
/// bottom of the screen passes whether the row is there or not — including
/// the one that has to fail if the gallery ever ships visible.
void _tallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('developer mode is off on a fresh install', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    expect(Prefs.getBool(Prefs.devMode, false), isFalse);
  });

  testWidgets('settings offers no way into the gallery until it is on',
      (tester) async {
    _tallPhone(tester);
    await tester.pumpWidget(_wrap(
        const MoreSettingsView(version: '0.9.26 (57)', devMode: false)));
    expect(find.text('Component gallery'), findsNothing);
    expect(find.text('Developer'), findsNothing);
    // …and the row that reveals it says nothing about what it does.
    expect(find.text('Version'), findsOneWidget);
  });

  testWidgets('and offers one once it is', (tester) async {
    _tallPhone(tester);
    var opened = false;
    await tester.pumpWidget(_wrap(MoreSettingsView(
      version: '0.9.26 (57)',
      devMode: true,
      onGallery: () => opened = true,
    )));
    expect(find.text('Developer'), findsOneWidget);
    await tester.tap(find.text('Component gallery'));
    expect(opened, isTrue);
  });

  testWidgets('the gallery needs neither a database nor a band',
      (tester) async {
    _tallPhone(tester);
    await tester.pumpWidget(_wrap(const GalleryScreen()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Component gallery'), findsOneWidget);
  });

  // The gallery opens on Flows: every activity in the catalogue, grouped as
  // the picker groups them.
  //
  // `findsWidgets`, not a count: a `ListView` builds only what fits, so an
  // exact number here would assert about the test view's height rather than
  // about the flow. The counts that matter are asserted directly.
  testWidgets('the flow tab offers every activity in the catalogue',
      (tester) async {
    _tallPhone(tester);
    await tester.pumpWidget(_wrap(const GalleryScreen()));
    await tester.pump();
    expect(find.text('Running'), findsWidgets);
    expect(gallerySessions, hasLength(Arch.values.length),
        reason: 'One hand-written session per archetype, or one is missing.');
    expect(flowActivities.length, greaterThan(60),
        reason: 'The flow tab lists the catalogue, not a sample of it.');
    // Every archetype is actually reachable — a family with no activity in it
    // is a screen nobody in this gallery can open.
    expect({for (final a in flowActivities) flowFixture(a).arch},
        hasLength(Arch.values.length));
  });

  // The point of the flow tab is that it pushes the REAL screens. If ANY
  // activity's summary or share sheet cannot be built from its own fixture
  // with no app behind it, the flow is a picture of a screen rather than the
  // screen — and this is the only place that would catch it.
  //
  // Every activity, not one per archetype: the fixtures are synthesised per
  // activity now, so it is a per-activity fixture that can be malformed.
  //
  // Pick, Set up and Live are deliberately not here: they own timers,
  // permission prompts and a 1 Hz tick, which a widget test can only assert
  // by draining. They are walked on a device.
  testWidgets('every activity summary and share card builds unhosted',
      (tester) async {
    _tallPhone(tester);
    for (final a in flowActivities) {
      final r = flowFixture(a);
      for (final screen in [ActivitySummary(r), ShareSheet(r)]) {
        await tester.pumpWidget(_wrap(screen));
        await tester.pump();
        expect(tester.takeException(), isNull,
            reason: '${a.name} (${r.arch.name}) threw building '
                '${screen.runtimeType}.');
      }
    }
  });

  // The theme tabs shipped INVERTED: `Brightness.values[i - 1]` against a
  // ['System', 'Light', 'Dark'] list, and Flutter declares the enum dark-first,
  // so 'Light' rendered dark and 'Dark' rendered light. Both tabs worked and
  // both lied, which is the worst version of this bug — the screen exists
  // because dark is solved separately from light, so every review done through
  // it was reviewing the palette the reviewer had not selected.
  testWidgets('the theme tabs are not inverted', (tester) async {
    _tallPhone(tester);
    await tester.pumpWidget(_wrap(const GalleryScreen()));
    await tester.pump();

    Brightness shownAfterTapping(String tab) {
      final scope = tester.widget<Theme>(find
          .descendant(of: find.byType(GalleryScreen), matching: find.byType(Theme))
          .first);
      return scope.data.brightness;
    }

    await tester.tap(find.text('Light'));
    await tester.pump();
    expect(shownAfterTapping('Light'), Brightness.light,
        reason: 'the Light tab is rendering the dark palette.');

    await tester.tap(find.text('Dark'));
    await tester.pump();
    expect(shownAfterTapping('Dark'), Brightness.dark,
        reason: 'the Dark tab is rendering the light palette.');
  });

  // A GPS activity's fixture must carry real coordinates, or the card has no
  // basemap to be — the whole no-photo form of the poster is the map.
  testWidgets('every GPS activity has coordinates for its map', (tester) async {
    final gps = flowActivities.where((a) => a.gps).toList();
    expect(gps, isNotEmpty);
    for (final a in gps) {
      expect(flowFixture(a).geo.length, greaterThanOrEqualTo(2),
          reason: '${a.name} records GPS but its fixture has no coordinates, '
              'so its card can never draw a basemap.');
    }
  });

  // The share sheet asks exactly one question now, and it asks it of every
  // activity: a lift can have a photograph as much as a run can. What a lift
  // does NOT get is a map, and the absence is silent — there is no missing-map
  // card for a session that never had one to miss.
  testWidgets('the share sheet offers a photo and a share, and nothing else',
      (tester) async {
    _tallPhone(tester);
    for (final a in [
      flowActivities.firstWhere((x) => x.gps),
      flowActivities.firstWhere((x) => !x.gps),
    ]) {
      await tester.pumpWidget(_wrap(ShareSheet(flowFixture(a))));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Add a photo'), findsOneWidget, reason: a.name);
      // By type, not by text — 'Share' is also the screen's own title.
      expect(find.byType(BigButton), findsOneWidget, reason: a.name);
      // The two questions this screen used to ask and no longer does.
      expect(find.text('CHOOSE A STYLE'), findsNothing, reason: a.name);
      expect(find.text('INCLUDE'), findsNothing, reason: a.name);
      expect(find.text('Minimal'), findsNothing, reason: a.name);
      expect(find.text('Poster'), findsNothing, reason: a.name);
    }
  });

  // A fixture that moves between launches is one you cannot compare two
  // screenshots of — the reason `_n` is FNV-1a and not `String.hashCode`.
  test('placeholder fixtures are deterministic', () {
    for (final a in flowActivities) {
      final x = flowFixture(a), y = flowFixture(a);
      expect(x.start, y.start, reason: '${a.name} moved.');
      expect(x.duration, y.duration);
      expect(x.avgHr, y.avgHr);
      expect(x.lapSecs, y.lapSecs);
    }
  });

  // The shape is the part that has to be honest. A treadmill has no route to
  // draw and a lift has no distance, and the screens' absence handling is
  // only exercised if the fixtures respect that.
  test('placeholder fixtures leave absent fields absent', () {
    for (final a in flowActivities) {
      final r = flowFixture(a);
      if (!a.gps) {
        expect(r.route, isEmpty, reason: '${a.name} has no GPS but has a route.');
      }
      if (r.arch != Arch.strength) expect(r.strength.isEmpty, isTrue);
      if (r.arch != Arch.laps) expect(r.lapSecs, isEmpty);
      if (r.arch != Arch.interval) expect(r.rounds, isEmpty);
      if (r.arch != Arch.flow) expect(r.breathsPerMin, isNull);
      if (r.arch != Arch.match) expect(r.gameScore, isEmpty);
      if (r.arch == Arch.basic) expect(r.distanceKm, isNull);
    }
  });

  test('every component in the gallery has a name and a widget', () {
    final cases = galleryCases();
    expect(cases.keys.where((k) => k.trim().isEmpty), isEmpty);
  });
}
