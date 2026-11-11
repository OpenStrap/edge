// Guide #1 (heart-rate zones): Today ring "Strain" -> DayStrainDetail
// "How these are set" -> ZonesDetail "Set your own zones" (or "Edit your own
// zones" once the user saved their own set).
//
// Claims: every step's target resolves on the REAL screen filled with the demo
// fixtures, in every shipped locale; the real screens produce the expected
// skeleton plans; the frames hold up at 390x780 with the app's fonts and text
// scale 1.3 in en/de/ru. Unexpected exceptions FAIL these tests (no draining).
//
// getters (lib/l10n/app_en.arb): homeRingStrain, dayStrainHowSet,
// activityZonesSetYourOwnLink / activityZonesEditYourOwnLink,
// activityZonesYourZonesSection, dayStrainTimeInZonesSection.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/activity/zones.dart';
import 'package:openstrap_edge/ui2/guides/demo_data.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_heart_rate_zones.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/guide_view.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../support/skeleton_fixture.dart';

const _root = ValueKey('root');

List<GuideStep> _steps() => switch (heartRateZonesGuide.variantFor(BandGeneration.whoop4)) {
      GuideVariantFound(:final variant) => variant.steps,
      GuideNoVariant() => fail('guide #1 must cover WHOOP 4'),
    };

/// Pumps [step]'s screen (or [screen]) filling a [w] x [h] root, in [locale].
Future<Element> _pumpScreen(
  WidgetTester t,
  GuideStep step, {
  Locale locale = const Locale('en'),
  double w = 390,
  double h = 3000,
  Widget? screen,
}) async {
  skTallView(t, w: w, h: h);
  await t.pumpWidget(skHost(
    SizedBox(key: _root, width: w, height: h, child: screen ?? Builder(builder: step.screen)),
    locale: locale,
  ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
  return t.element(find.byKey(_root));
}

Rect _foundRect(TargetResolution r, String what) => switch (r) {
      TargetFound(:final rect) => rect,
      _ => fail('$what did not resolve: $r'),
    };

/// The plan the overlay would paint for [step] on the screen that is pumped.
List<SkeletonShape> _plan(WidgetTester t, GuideStep step, Element root, AppLocalizations l) {
  final keep = [for (final x in [step.target, ...step.alsoKeep]) _foundRect(x.resolve(root, l), 'target')];
  return skeletonPlan(root, keep: keep, chrome: defaultSkeletonChrome(root));
}

/// Every laid-out text line of every visible Text that is inside the root, not
/// inside [legible] rects and not in chrome: each must be covered by a bar.
void _expectEveryOtherLineCovered(
  WidgetTester t,
  List<SkeletonShape> plan,
  List<Rect> legible,
  Element root,
) {
  final bars = plan.where((s) => s.kind == SkeletonKind.bar).map((s) => s.rect).toList();
  final bounds = Offset.zero & (root.renderObject! as RenderBox).size;
  var checked = 0;
  for (final e in find.byType(Text).evaluate()) {
    final f = find.byElementPredicate((x) => x == e);
    for (final line in skLineRects(t, f, find.byKey(_root))) {
      if (!skContains(bounds, line) || legible.any((r) => r.overlaps(line))) continue;
      checked++;
      expect(bars.any((b) => skContains(b, line)), isTrue,
          reason: 'line $line of "${(e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText()}" is not covered');
    }
  }
  expect(checked, greaterThan(3), reason: 'positive control: the screen has several skeletonized lines');
}

void _expectUntouched(List<SkeletonShape> plan, Rect r, String what) {
  for (final s in plan) {
    expect(skOverlaps(s.rect, r), isFalse, reason: '$what $r must stay legible but ${s.kind} ${s.rect} covers it');
  }
}

void _expectWholeUnitProgress(List<SkeletonShape> plan) {
  final units = plan.map((s) => s.section).toSet();
  expect(units, isNotEmpty);
  expect(units.toList()..sort(), [for (var i = 0; i < units.length; i++) i], reason: 'units numbered 0..N-1');
  final half = revealedShapes(plan, 0.5);
  final k = (units.length * 0.5).floor();
  expect(half.map((s) => s.section).toSet(), {for (var i = 0; i < k; i++) i}, reason: 'floor(0.5 * ${units.length}) whole units');
  expect(revealedShapes(plan, 1), plan);
  expect(revealedShapes(plan, 0), isEmpty);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await skLoadAppFonts();
  });

  group('demo fixtures', () {
    test('Home shows all three rings scored', () {
      // why: the Strain ring only exists when strain has a value; an absent
      // ring becomes a gap row and the guide would point at the wrong thing.
      final d = GuideDemo.home;
      expect(d.strain.value, isNotNull);
      expect(d.readiness.value, isNotNull);
      expect(d.sleepMin.value, isNotNull);
      expect(RingTrio.has(d), isTrue);
    });

    test('day strain has a curve and a non-empty zone split (so "Time in zones" is drawn)', () {
      // why: DayStrainDetail._zones draws nothing when zoneMin is null or sums
      // to 0 (day_strain.dart), taking "How these are set" with it.
      final d = GuideDemo.dayStrain;
      expect(d.hasCurve, isTrue);
      expect(d.zoneMin, hasLength(5));
      expect(d.zoneMin!.fold<int>(0, (a, b) => a + b), greaterThan(0));
    });

    test('zones: five ascending rows; computed set vs saved own set differ only by source', () {
      // why: ZonesDetail swaps the link to "Edit your own zones" when
      // source == 'manual' (zones.dart:334) - both states are in the guide.
      final z = GuideDemo.zones, m = GuideDemo.zonesManual;
      expect(z.source, isNot('manual'));
      expect(m.source, 'manual');
      expect(z.zones, hasLength(5));
      for (var i = 0; i < 5; i++) {
        expect(z.zones[i].lo, lessThan(z.zones[i].hi), reason: 'zone ${i + 1}');
        if (i > 0) expect(z.zones[i].lo, greaterThan(z.zones[i - 1].lo));
      }
      expect([for (final r in m.zones) (r.lo, r.hi)], [for (final r in z.zones) (r.lo, r.hi)]);
    });
  });

  group('the guide definition', () {
    test('three steps: tap, scroll-then-tap, tap; one path for either band and an unknown one', () {
      // why: spec: "step 2 is scrollThenTap".
      for (final band in [BandGeneration.whoop4, BandGeneration.whoop5, null]) {
        expect(heartRateZonesGuide.variantFor(band), isA<GuideVariantFound>(), reason: '$band');
      }
      expect(_steps().map((s) => s.action), [GuideAction.tap, GuideAction.scrollThenTap, GuideAction.tap]);
      expect(heartRateZonesGuide.id, 'heart-rate-zones');
      expect(heartRateZonesGuide.devices, {BandGeneration.whoop4, BandGeneration.whoop5});
      expect(heartRateZonesGuide.footers, hasLength(2));
    });

    test('step ids are non-empty, unique and stable across reads (item 2)', () {
      // why: ids key progress and phase-4 route matching; a getter that mints
      // new ids per call, or reuses one, breaks both.
      final a = _steps().map((s) => s.id).toList();
      final b = _steps().map((s) => s.id).toList();
      expect(a, b);
      expect(a.every((i) => i.isNotEmpty), isTrue);
      expect(a.toSet(), hasLength(3));
    });

    test('step 3 also keeps "Your zones" readable; steps 1 and 2 keep only their own unit (item 1)', () {
      // why: mock-up step 3 shows the "Your zones" card legible.
      final s = _steps();
      expect(s[0].alsoKeep, isEmpty);
      expect(s[1].alsoKeep, isEmpty);
      expect(s[2].alsoKeep, hasLength(1));
    });
  });

  group('every step resolves on the real screen, in every shipped locale', () {
    for (final locale in AppLocalizations.supportedLocales) {
      testWidgets('${locale.languageCode}: targets, anchors, both Set/Edit states', (t) async {
        // why: the whole point. Labels are the translated strings the real
        // screens print; the screens are the real widgets handed demo data.
        // Anchors identify the route: step i's anchor is found on screen i and
        // NOT on the other two screens. Step 3 also resolves with a saved own
        // set, where the link reads "Edit your own zones".
        final l = lookupAppLocalizations(locale);
        final steps = _steps();
        final screenTypes = [HomeScreen, DayStrainDetail, ZonesDetail];
        final roots = <Element>[];
        for (var i = 0; i < 3; i++) {
          final root = await _pumpScreen(t, steps[i], locale: locale);
          expect(find.byType(screenTypes[i]), findsOneWidget, reason: 'step ${i + 1} is the REAL ${screenTypes[i]}');
          final rect = _foundRect(steps[i].target.resolve(root, l), 'step ${i + 1} target in ${locale.languageCode}');
          expect(rect.isEmpty, isFalse);
          for (var j = 0; j < 3; j++) {
            expect(steps[j].isActive(root, l), i == j, reason: 'step ${j + 1} active on screen ${i + 1}');
          }
          for (final x in steps[i].alsoKeep) {
            _foundRect(x.resolve(root, l), 'step ${i + 1} alsoKeep');
          }
          if (i == 0) {
            final trio = skLocalRect(t, find.byType(RingTrio), find.byKey(_root));
            expect(skContains(trio, rect), isTrue, reason: 'ring target inside the ring card');
            final label = skLocalRect(t, find.text(l.homeRingStrain).first, find.byKey(_root));
            expect(rect.height, greaterThan(label.height * 2), reason: 'outline wraps ring + label');
          }
          roots.add(root);
        }
        expect(t.takeException(), isNull);

        final manualRoot = await _pumpScreen(t, steps[2],
            locale: locale, screen: ZonesDetail(data: GuideDemo.zonesManual));
        expect(find.text(l.activityZonesEditYourOwnLink), findsOneWidget, reason: 'fixture sanity: saved state');
        _foundRect(steps[2].target.resolve(manualRoot, l), 'step 3 target with a saved own set');
        expect(t.takeException(), isNull);
      });

      test('${locale.languageCode}: strings are translated and quote the in-app labels', () {
        // why: a caption that paraphrases the label cannot be matched against
        // the screen; an untranslated caption is English in a German app.
        // Step 3 may quote either state's label.
        final l = lookupAppLocalizations(locale);
        final en = lookupAppLocalizations(const Locale('en'));
        final steps = _steps();
        final options = [
          [l.homeRingStrain],
          [l.dayStrainHowSet],
          [l.activityZonesSetYourOwnLink, l.activityZonesEditYourOwnLink],
        ];
        for (var i = 0; i < steps.length; i++) {
          final c = steps[i].caption(l);
          expect(c, isNotEmpty);
          expect(options[i].any(c.contains), isTrue, reason: 'step ${i + 1} caption "$c" must quote one of ${options[i]}');
          if (locale.languageCode != 'en') {
            expect(c, isNot(steps[i].caption(en)), reason: 'step ${i + 1} caption untranslated');
          }
        }
        expect(steps[1].caption(l), contains(l.dayStrainTimeInZonesSection));
        final g = heartRateZonesGuide;
        final texts = [g.title(l), for (final f in g.footers) ...[f.title(l), f.body(l)]];
        final enTexts = [g.title(en), for (final f in g.footers) ...[f.title(en), f.body(en)]];
        for (var i = 0; i < texts.length; i++) {
          expect(texts[i], isNotEmpty);
          if (locale.languageCode != 'en') expect(texts[i], isNot(enTexts[i]), reason: 'text #$i untranslated');
        }
      });
    }

    testWidgets('a state change while mounted: Set -> Edit keeps the overlay resolving the same target', (t) async {
      // why: item 6. ZonesDetail cannot change source after mount without a
      // repo, so the label flips inside a minimal host under a live Skeletonize.
      // The target must follow the text and the plan must keep clear of it.
      skTallView(t, w: 390, h: 800);
      var manual = false;
      late StateSetter flip;
      final step = _steps()[2];
      await t.pumpWidget(skHost(
        Skeletonize(
          key: const ValueKey('sk'),
          keep: [step.target],
          child: Scaffold(
            body: StatefulBuilder(builder: (c, set) {
              flip = set;
              final l = AppLocalizations.of(c)!;
              return Column(children: [
                const Surface(child: Text('other card')),
                Pressable(
                  onTap: () {},
                  child: Text(manual ? l.activityZonesEditYourOwnLink : l.activityZonesSetYourOwnLink),
                ),
              ]);
            }),
          ),
        ),
      ));
      await t.pump();
      final state = t.state<SkeletonizeState>(find.byKey(const ValueKey('sk')));
      expect(state.resolutions.single, isA<TargetFound>());
      flip(() => manual = true);
      await t.pump();
      expect(identical(t.state<SkeletonizeState>(find.byKey(const ValueKey('sk'))), state), isTrue);
      expect(state.resolutions.single, isA<TargetFound>());
      final link = t.getRect(find.byType(Pressable));
      for (final s in state.shapes) {
        expect(s.rect.overlaps(link), isFalse);
      }
      expect(state.shapes, isNotEmpty, reason: 'the other card is still covered');
    });
  });

  group('plans on the REAL screens (item 1)', () {
    testWidgets('Home step 1: the ring card stays whole, everything else is skeletonized', (t) async {
      // why: wrong card detection (e.g. only the ring Text kept, or the whole
      // screen kept) would pass every label test but break the picture.
      final l = lookupAppLocalizations(const Locale('en'));
      final step = _steps()[0];
      final root = await _pumpScreen(t, step);
      final plan = _plan(t, step, root, l);
      final trio = skLocalRect(t, find.byType(RingTrio), find.byKey(_root));
      _expectUntouched(plan, trio, 'the ring card');
      final chrome = defaultSkeletonChrome(root);
      expect(plan.where((s) => s.kind == SkeletonKind.surface), isNotEmpty, reason: 'other Home cards are repainted as surfaces');
      _expectEveryOtherLineCovered(t, plan, [trio, ...chrome], root);
      _expectWholeUnitProgress(plan);
      expect(t.takeException(), isNull);
    });

    testWidgets('DayStrainDetail step 2: heading + action + zones chart stay, the rest is covered', (t) async {
      // why: mock-up step 2: "Time in zones" heading and chart stay readable;
      // the trace card and "What this is made of" collapse.
      final l = lookupAppLocalizations(const Locale('en'));
      final step = _steps()[1];
      final root = await _pumpScreen(t, step);
      final plan = _plan(t, step, root, l);
      final section = skLocalRect(
          t, find.ancestor(of: find.text(l.dayStrainHowSet), matching: find.byType(Section)).first, find.byKey(_root));
      _expectUntouched(plan, section, 'the Time in zones Section');
      final chrome = defaultSkeletonChrome(root);
      _expectUntouched(plan, skLocalRect(t, find.text(l.dayStrainTitle).first, find.byKey(_root)), 'the screen title');
      expect(plan.where((s) => s.kind == SkeletonKind.block), isNotEmpty, reason: 'the strain curve is a block');
      final inputs = skLocalRect(
          t, find.ancestor(of: find.text(l.dayStrainInputsSection), matching: find.byType(Section)).first, find.byKey(_root));
      final card2 = P.of(root).card2;
      expect(plan.any((s) => s.kind == SkeletonKind.surface && s.color == card2 && skContains(inputs, s.rect)), isTrue,
          reason: '"What this is made of" is a card2 surface repainted in its own colour');
      _expectEveryOtherLineCovered(t, plan, [section, ...chrome], root);
      _expectWholeUnitProgress(plan);
      expect(t.takeException(), isNull);
    });

    testWidgets('ZonesDetail step 3: the link and the "Your zones" Section stay, the ceiling card is covered', (t) async {
      // why: pinned decision - step 3 keeps "Your zones" (alsoKeep) though the
      // target (the link) is outside that Section.
      final l = lookupAppLocalizations(const Locale('en'));
      final step = _steps()[2];
      final root = await _pumpScreen(t, step);
      final plan = _plan(t, step, root, l);
      final yours = skLocalRect(
          t, find.ancestor(of: find.text(l.activityZonesYourZonesSection), matching: find.byType(Section)).first, find.byKey(_root));
      final link = skLocalRect(t, find.text(l.activityZonesSetYourOwnLink), find.byKey(_root));
      _expectUntouched(plan, yours, 'the "Your zones" Section');
      _expectUntouched(plan, link, 'the link');
      expect(plan, isNotEmpty, reason: 'something (the ceiling card) is still skeletonized');
      _expectEveryOtherLineCovered(t, plan, [yours, link, ...defaultSkeletonChrome(root)], root);
      _expectWholeUnitProgress(plan);
      expect(t.takeException(), isNull);
    });
  });

  group('step 1 renders Home inside the tab-bar chrome (item 11)', () {
    testWidgets('AppShell + Home; the tab bar is chrome: legible and outside every skeleton shape', (t) async {
      // why: the mock-up's step 1 has the bottom tabs. The screen must be the
      // real AppShell around the real Home, and the overlay must not cover it.
      final l = lookupAppLocalizations(const Locale('en'));
      final step = _steps()[0];
      final root = await _pumpScreen(t, step, w: 390, h: 780);
      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(HomeScreen), findsOneWidget);
      final tabs = [for (final n in ['Today', 'Sleep', 'Activity', 'Health']) skLocalRect(t, find.text(n).last, find.byKey(_root))];
      final plan = _plan(t, step, root, l);
      for (final r in tabs) {
        _expectUntouched(plan, r, 'tab label');
      }
      final chrome = defaultSkeletonChrome(root);
      expect(chrome.any((c) => tabs.every((r) => skContains(c, r))), isTrue);
      expect(t.takeException(), isNull);
    });
  });

  group('real frames: 390x780, app fonts, text scale 1.3 (item 8)', () {
    for (final locale in const [Locale('en'), Locale('de'), Locale('ru')]) {
      testWidgets('${locale.languageCode}: each step fits its frame; outline and pill stay inside it', (t) async {
        // why: long locales and large text push labels around; the outline or
        // pill must never leave the phone frame, and nothing may throw.
        t.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        skTallView(t, w: 800, h: 3000);
        final l = lookupAppLocalizations(locale);
        final steps = _steps();
        final labels = [l.homeRingStrain, l.dayStrainHowSet, l.activityZonesSetYourOwnLink];
        for (var i = 0; i < steps.length; i++) {
          await t.pumpWidget(skHost(
            Scaffold(body: SingleChildScrollView(child: Center(child: GuideStepView(number: i + 1, step: steps[i])))),
            locale: locale,
          ));
          await t.pumpAndSettle();
          expect(t.takeException(), isNull, reason: 'step ${i + 1} ${locale.languageCode}');
          final frame = t.getRect(find.byKey(GuideStepView.frameKey));
          expect(frame.width, closeTo(280, 0.6));
          final target = t.getRect(find.text(labels[i]).first);
          expect(skContains(frame, target), isTrue, reason: 'target $target in frame $frame');
          final outline = t.getRect(find.byKey(GuideStepView.outlineKey));
          final pill = t.getRect(find.byKey(GuideStepView.tapPillKey));
          expect(skContains(frame, outline), isTrue, reason: 'outline $outline inside frame $frame');
          expect(skContains(frame, pill), isTrue, reason: 'pill $pill inside frame $frame');
          expect(skContains(outline, target), isTrue);
          expect(pill.overlaps(target), isFalse, reason: 'pill must not sit on the target');
          expect(find.byKey(GuideStepView.scrollMarkerKey), i == 1 ? findsOneWidget : findsNothing);
          if (i == 1) {
            expect(skContains(frame, t.getRect(find.byKey(GuideStepView.scrollMarkerKey))), isTrue);
          }
          expect(find.byKey(GuideStepView.failureKey), findsNothing);
        }
      });
    }
  });
}
