// Guide #1 (heart-rate zones): Today ring "Strain" -> DayStrainDetail
// "How these are set" -> ZonesDetail "Set your own zones".
//
// The claim that matters: every step's target resolves on the REAL screen,
// filled with the demo fixtures, in EVERY shipped locale. A relabelled button
// or a missing translation breaks the guide silently otherwise.
//
// Layout overflow under the test font (Ahem is wider than the real fonts, so
// th/ru/hi text overflows) is a test-font artefact, not the claim: exceptions
// are drained, resolution is asserted.
//
// getters (lib/l10n/app_en.arb): homeRingStrain, dayStrainHowSet,
// activityZonesSetYourOwnLink; plus dayStrainTimeInZonesSection for step 2.

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

import '../support/skeleton_fixture.dart';

const _root = ValueKey('root');

List<GuideStep> _steps() => switch (heartRateZonesGuide.variantFor(BandGeneration.whoop4)) {
      GuideVariantFound(:final variant) => variant.steps,
      GuideNoVariant() => fail('guide #1 must cover WHOOP 4'),
    };

void _drain(WidgetTester t) {
  while (t.takeException() != null) {}
}

void main() {
  group('demo fixtures', () {
    test('Home shows all three rings scored, today', () {
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
      // to 0 (lib/ui2/activity/day_strain.dart), taking "How these are set" with it.
      final d = GuideDemo.dayStrain;
      expect(d.hasCurve, isTrue);
      expect(d.zoneMin, hasLength(5));
      expect(d.zoneMin!.fold<int>(0, (a, b) => a + b), greaterThan(0));
    });

    test('zones: five ascending rows, computed set (so the link reads "Set your own zones")', () {
      // why: ZonesDetail swaps the link to "Edit your own zones" when
      // source == 'manual' (zones.dart), which no longer matches step 3's label.
      final z = GuideDemo.zones;
      expect(z.source, isNot('manual'));
      expect(z.zones, hasLength(5));
      for (var i = 0; i < 5; i++) {
        expect(z.zones[i].lo, lessThan(z.zones[i].hi), reason: 'zone ${i + 1}');
        if (i > 0) expect(z.zones[i].lo, greaterThan(z.zones[i - 1].lo));
      }
    });
  });

  group('the guide definition', () {
    test('three steps: tap, scroll-then-tap, tap; same path for either band and an unknown one', () {
      // why: spec: "step 2 is scrollThenTap". The mock-up: tap the ring, scroll
      // to Time in zones and tap the link, tap Set your own zones.
      for (final band in [BandGeneration.whoop4, BandGeneration.whoop5, null]) {
        final r = heartRateZonesGuide.variantFor(band);
        expect(r, isA<GuideVariantFound>(), reason: '$band');
      }
      final steps = _steps();
      expect(steps.map((s) => s.action), [GuideAction.tap, GuideAction.scrollThenTap, GuideAction.tap]);
      expect(heartRateZonesGuide.id, 'heart-rate-zones');
      expect(heartRateZonesGuide.devices, {BandGeneration.whoop4, BandGeneration.whoop5});
    });

    test('two footer cards: "Another way in" and "Don\'t see Time in zones?"', () {
      // why: the mock-up's footers; the second explains the card only appears
      // once the band has recorded heart rate.
      expect(heartRateZonesGuide.footers, hasLength(2));
    });
  });

  group('every step resolves on the real screen, in every shipped locale', () {
    for (final locale in AppLocalizations.supportedLocales) {
      testWidgets('${locale.languageCode}: Home -> DayStrainDetail -> ZonesDetail', (t) async {
        // why: the whole point. The label is the translated string the real
        // screen prints; screens are the real widgets handed the demo data.
        skTallView(t, w: 800, h: 3000);
        final l = lookupAppLocalizations(locale);
        final steps = _steps();
        final screenTypes = [HomeScreen, DayStrainDetail, ZonesDetail];
        final scoped = [RingTrio, null, null];

        for (var i = 0; i < steps.length; i++) {
          await t.pumpWidget(skHost(
            SizedBox.expand(key: _root, child: Builder(builder: steps[i].screen)),
            locale: locale,
          ));
          await t.pump();
          await t.pump(const Duration(milliseconds: 100));
          _drain(t);

          expect(find.byType(screenTypes[i]), findsOneWidget, reason: 'step ${i + 1} is the REAL ${screenTypes[i]}');
          final r = steps[i].target.resolve(t.element(find.byKey(_root)), l);
          expect(r, isA<TargetFound>(), reason: 'step ${i + 1} in ${locale.languageCode}: $r');
          final rect = (r as TargetFound).rect;
          expect(rect.isEmpty, isFalse);
          expect(skContains(Offset.zero & const Size(800, 3000), rect), isTrue);
          if (scoped[i] != null) {
            // The Strain ring is inside the ring trio, and the outline wraps the
            // ring plus its label (taller than the label alone).
            final trio = skLocalRect(t, find.byType(RingTrio), find.byKey(_root));
            expect(skContains(trio, rect), isTrue, reason: 'ring target must be inside the ring card');
            final label = skLocalRect(t, find.text(l.homeRingStrain), find.byKey(_root));
            expect(rect.height, greaterThan(label.height * 2));
          }
        }
      });

      test('${locale.languageCode}: strings are translated and quote the in-app labels', () {
        // why: a caption that paraphrases the label ("tap the zones link")
        // cannot be matched against the screen; and an untranslated caption
        // is English in a German app. Labels checked verbatim per step.
        final l = lookupAppLocalizations(locale);
        final en = lookupAppLocalizations(const Locale('en'));
        final steps = _steps();
        final labels = [l.homeRingStrain, l.dayStrainHowSet, l.activityZonesSetYourOwnLink];
        for (var i = 0; i < steps.length; i++) {
          final c = steps[i].caption(l);
          expect(c, isNotEmpty);
          expect(c, contains(labels[i]), reason: 'step ${i + 1} caption must quote "${labels[i]}"');
          if (locale.languageCode != 'en') {
            expect(c, isNot(steps[i].caption(en)), reason: 'step ${i + 1} caption untranslated in ${locale.languageCode}');
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
  });

  group('rendered in the demo frame (en)', () {
    testWidgets('each step ends with its target inside the frame; only step 2 shows the scroll marker', (t) async {
      // why: the real DayStrainDetail is taller than the 780 px phone, so the
      // link is below the fold until the step scrolls; steps 1 and 3 need none.
      skTallView(t);
      final l = lookupAppLocalizations(const Locale('en'));
      final steps = _steps();
      final labels = [l.homeRingStrain, l.dayStrainHowSet, l.activityZonesSetYourOwnLink];
      for (var i = 0; i < steps.length; i++) {
        await t.pumpWidget(skHost(Scaffold(
          body: SingleChildScrollView(child: Center(child: GuideStepView(number: i + 1, step: steps[i]))),
        )));
        await t.pumpAndSettle();
        _drain(t);
        final frame = t.getRect(find.byKey(GuideStepView.frameKey));
        expect(skContains(frame, t.getRect(find.text(labels[i]))), isTrue, reason: 'step ${i + 1} target in frame');
        expect(find.byKey(GuideStepView.outlineKey), findsOneWidget);
        expect(find.byKey(GuideStepView.tapPillKey), findsOneWidget);
        expect(find.byKey(GuideStepView.scrollMarkerKey), i == 1 ? findsOneWidget : findsNothing, reason: 'step ${i + 1}');
        expect(find.byKey(GuideStepView.failureKey), findsNothing);
      }
    });
  });
}
