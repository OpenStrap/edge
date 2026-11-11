// GuideStepView / GuideView: the demo frame around a skeletonized real screen.
// Hand-built screens of real ui2 cards; the real guide #1 is covered in
// guide_heart_rate_zones_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/guide.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/guides/guide_view.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../support/skeleton_fixture.dart';

const _fk = GuideStepView.frameKey;

/// A screen: title (chrome), one ordinary card, [gap] of space, then a Section
/// whose ACTION is the target. A big gap pushes the target below the frame.
Widget _screen(double gap) => Builder(builder: (c) {
      final l = AppLocalizations.of(c)!;
      return Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const ScreenTitle('Screen title', key: ValueKey('screenTitle')),
            const Surface(child: Text('other card text')),
            SizedBox(height: gap),
            Section(l.dayStrainTimeInZonesSection, const Surface(child: Text('chart')),
                action: l.dayStrainHowSet, onAction: () {}),
          ],
        ),
      );
    });

GuideStep _step(double gap, GuideAction a,
        {GuideTarget? target, int n = 0, List<GuideTarget> alsoKeep = const []}) =>
    GuideStep(
      id: 'step-$n',
      screen: (_) => _screen(gap),
      target: target ?? GuideTarget.label((l) => l.dayStrainHowSet),
      anchor: GuideTarget.label((l) => l.dayStrainTimeInZonesSection),
      alsoKeep: alsoKeep,
      action: a,
      caption: (l) => 'Step caption $n: ${l.dayStrainTimeInZonesSection}',
    );

Future<void> _pump(WidgetTester t, GuideStep step, {int number = 2, Locale locale = const Locale('en')}) async {
  skTallView(t);
  await t.pumpWidget(skHost(
    Scaffold(body: SingleChildScrollView(child: Center(child: GuideStepView(number: number, step: step)))),
    locale: locale,
  ));
  await t.pumpAndSettle();
}

Rect _inSkeleton(WidgetTester t, Rect global) {
  final rb = t.renderObject<RenderBox>(find.byType(Skeletonize));
  return Rect.fromPoints(rb.globalToLocal(global.topLeft), rb.globalToLocal(global.bottomRight));
}

void main() {
  const howSet = 'How these are set'; // app_en.arb dayStrainHowSet

  group('GuideStepView', () {
    testWidgets('numbered caption sits above the frame', (t) async {
      // why: the mock-up reads "(2) Scroll down to ... and tap ..." above its
      // phone. Fails if the badge number is wrong, the text is not the step's
      // caption, or the caption is not above the frame.
      await _pump(t, _step(0, GuideAction.tap, n: 2));
      final caption = find.byKey(GuideStepView.captionKey);
      expect(find.descendant(of: caption, matching: find.text('Step caption 2: Time in zones')), findsOneWidget);
      expect(find.descendant(of: find.byKey(GuideStepView.numberKey), matching: find.text('2')), findsOneWidget);
      expect(t.getRect(caption).bottom, lessThanOrEqualTo(t.getRect(find.byKey(_fk)).top + 0.5));
    });

    testWidgets('outline wraps the target; the tap pill sits beside it, not on it', (t) async {
      // why: "yellow outline + tap pill on the target". The pill on top of the
      // label would hide what it points at.
      await _pump(t, _step(0, GuideAction.tap));
      final target = t.getRect(find.text(howSet));
      final outline = t.getRect(find.byKey(GuideStepView.outlineKey));
      final pill = t.getRect(find.byKey(GuideStepView.tapPillKey));
      expect(skContains(outline, target), isTrue, reason: 'outline $outline must contain target $target');
      expect(pill.overlaps(target), isFalse);
      expect(pill.overlaps(outline.inflate(pill.height)), isTrue, reason: 'pill must be next to the outline');
      expect(find.byKey(GuideStepView.scrollMarkerKey), findsNothing, reason: 'no scroll needed here');
    });

    testWidgets('a scrollThenTap step scrolls the target into the frame and shows the scroll marker',
        (t) async {
      // why: step 2 of guide #1. The target starts ~3000 px (4 viewports) below the 780 px
      // phone; without the programmatic scroll it is outside the frame.
      await _pump(t, _step(3000, GuideAction.scrollThenTap));
      expect(skContains(t.getRect(find.byKey(_fk)), t.getRect(find.text(howSet))), isTrue,
          reason: 'target must end up inside the frame');
      expect(find.byKey(GuideStepView.scrollMarkerKey), findsOneWidget);
      expect(find.byKey(GuideStepView.outlineKey), findsOneWidget);
    });

    testWidgets('the screen inside is skeletonized except the target\'s section; chrome stays', (t) async {
      // why: the point of the feature. 'other card text' must be covered by a
      // bar; the target's own section and the screen title must not be touched.
      await _pump(t, _step(0, GuideAction.tap));
      final state = t.state<SkeletonizeState>(find.byType(Skeletonize));
      final other = _inSkeleton(t, t.getRect(find.text('other card text')));
      final bars = state.paintedShapes.where((s) => s.kind == SkeletonKind.bar);
      expect(bars.any((b) => b.rect.overlaps(other)), isTrue, reason: 'ordinary card text must be covered');

      for (final id in [howSet, 'chart', 'Screen title']) {
        final r = _inSkeleton(t, t.getRect(find.text(id)));
        expect(state.paintedShapes.where((s) => s.rect.overlaps(r)), isEmpty, reason: '"$id" must stay legible');
      }
    });

    testWidgets('an unresolvable target shows a failure INSTEAD of a guide, without throwing', (t) async {
      // why: "unresolved target = typed failure (no silent empty guide)" at the
      // view level: the reader must see that this step is broken.
      await _pump(t, _step(0, GuideAction.tap, target: GuideTarget.label((_) => 'No such label')));
      expect(t.takeException(), isNull);
      expect(find.byKey(GuideStepView.failureKey), findsOneWidget);
      expect(find.byKey(GuideStepView.outlineKey), findsNothing);
      expect(find.byKey(GuideStepView.tapPillKey), findsNothing);
    });

    testWidgets('the tap pill and scroll marker speak the app language', (t) async {
      // why: the markers are strings (new l10n), not hard-coded English.
      String pill(WidgetTester t) => t
          .widget<Text>(find.descendant(of: find.byKey(GuideStepView.tapPillKey), matching: find.byType(Text)).first)
          .data!;
      String marker(WidgetTester t) => t
          .widget<Text>(find.descendant(of: find.byKey(GuideStepView.scrollMarkerKey), matching: find.byType(Text)).first)
          .data!;
      await _pump(t, _step(3000, GuideAction.scrollThenTap));
      final (enPill, enMarker) = (pill(t), marker(t));
      await _pump(t, _step(3000, GuideAction.scrollThenTap), locale: const Locale('de'));
      expect(enPill, isNotEmpty);
      expect(enMarker, isNotEmpty);
      expect(pill(t), isNot(enPill));
      expect(marker(t), isNot(enMarker));
    });
  });

  group('GuideStepView semantics (item 7)', () {
    testWidgets('the caption is announced before anything in the frame; the target once; covered text never',
        (t) async {
      // why: a screen-reader user hears "what to do" first, then the screen. The
      // outline and pills are decoration: they must not repeat the target's
      // label or add context-free "tap" / "scroll" announcements.
      final h = t.ensureSemantics();
      await _pump(t, _step(0, GuideAction.tap, n: 2));
      final labels = skTraversalLabels(t);
      final caption = labels.indexWhere((l) => l.contains('Step caption 2'));
      expect(caption, isNonNegative, reason: 'caption must be announced; got $labels');
      for (final inFrame in [howSet, 'chart']) {
        final i = labels.indexWhere((l) => l.contains(inFrame));
        expect(i, greaterThan(caption), reason: '"$inFrame" must come after the caption; got $labels');
      }
      expect(labels.where((l) => l.contains(howSet)), hasLength(1), reason: 'target label announced exactly once');
      expect(labels.any((l) => l.contains('other card text')), isFalse, reason: 'covered text must not be announced');
      expect(labels.any((l) => l.contains('Screen title')), isTrue, reason: 'chrome stays announced');

      final pill = t.widget<Text>(find.descendant(of: find.byKey(GuideStepView.tapPillKey), matching: find.byType(Text)).first).data!;
      expect(labels.any((l) => l == pill), isFalse, reason: 'the tap pill is decoration, not an announcement');
      // dispose before the test ends: the harness checks handles BEFORE tearDowns run
      h.dispose();
    });

    testWidgets('the scroll marker is not announced', (t) async {
      // why: "scroll" with no context is noise; the caption already says it.
      final h = t.ensureSemantics();
      await _pump(t, _step(3000, GuideAction.scrollThenTap));
      final marker = t.widget<Text>(find.descendant(of: find.byKey(GuideStepView.scrollMarkerKey), matching: find.byType(Text)).first).data!;
      expect(skTraversalLabels(t).any((l) => l == marker), isFalse);
      // dispose before the test ends: the harness checks handles BEFORE tearDowns run
      h.dispose();
    });

    testWidgets('alsoKeep leaves its unit readable (text and semantics)', (t) async {
      // why: step 3 of guide #1 keeps "Your zones" besides the link.
      final h = t.ensureSemantics();
      await _pump(t, _step(0, GuideAction.tap, alsoKeep: [GuideTarget.label((_) => 'other card text')]));
      final state = t.state<SkeletonizeState>(find.byType(Skeletonize));
      final other = _inSkeleton(t, t.getRect(find.text('other card text')));
      expect(state.paintedShapes.where((s) => s.rect.overlaps(other)), isEmpty);
      expect(skTraversalLabels(t).any((l) => l.contains('other card text')), isTrue);
      // dispose before the test ends: the harness checks handles BEFORE tearDowns run
      h.dispose();
    });
  });

  group('GuideView', () {
    GuideStep s(String label) => GuideStep(
          id: 'id-$label',
          anchor: GuideTarget.label((_) => label),
          screen: (_) => Scaffold(body: Center(child: Pressable(onTap: () {}, child: Text(label)))),
          target: GuideTarget.label((_) => label),
          action: GuideAction.tap,
          caption: (_) => 'Caption for $label',
        );
    final footers = [
      GuideFooter(title: (_) => 'Another way in', body: (_) => 'Open the Activity tab.'),
      GuideFooter(title: (_) => "Don't see it?", body: (_) => 'Wear the band for a while.'),
    ];

    Future<void> pumpGuide(WidgetTester t, Guide g, BandGeneration? band) async {
      skTallView(t, w: 1200, h: 4000);
      await t.pumpWidget(skHost(Scaffold(body: GuideView(guide: g, band: band))));
      await t.pumpAndSettle();
    }

    testWidgets('shows the title, the steps in order with numbers 1..n, then the footer cards', (t) async {
      // why: spec 2.3: "the steps in order plus footer cards". Order is
      // pinned by tree order AND by numbers, so a reversed list fails.
      final steps = [s('Alpha'), s('Beta'), s('Gamma')];
      final g = Guide(
        id: 'g',
        title: (_) => 'Where to find Alpha',
        variants: [GuideVariant(steps: steps)],
        footers: footers,
      );
      await pumpGuide(t, g, BandGeneration.whoop4);

      expect(find.text('Where to find Alpha'), findsOneWidget);
      final views = t.widgetList<GuideStepView>(find.byType(GuideStepView)).toList();
      expect(views.map((v) => v.number), [1, 2, 3]);
      for (var i = 0; i < 3; i++) {
        expect(views[i].step, same(steps[i]));
      }
      for (final f in ['Another way in', "Don't see it?", 'Open the Activity tab.', 'Wear the band for a while.']) {
        expect(find.text(f), findsOneWidget, reason: f);
      }
      // footers come after the last step
      expect(t.getRect(find.text('Another way in')).top, greaterThan(t.getRect(find.byType(GuideStepView).last).bottom - 1));
    });

    testWidgets('the band picks the variant: WHOOP 5 gets its own, longer path', (t) async {
      // why: separate WHOOP 4 / 5 variants where the path differs (owner).
      final g = Guide(id: 'g', title: (_) => 'T', variants: [
        GuideVariant(devices: {BandGeneration.whoop4}, steps: [s('Alpha')]),
        GuideVariant(devices: {BandGeneration.whoop5}, steps: [s('Alpha'), s('Beta')]),
      ]);
      await pumpGuide(t, g, BandGeneration.whoop5);
      expect(find.byType(GuideStepView), findsNWidgets(2));
      await pumpGuide(t, g, BandGeneration.whoop4);
      expect(find.byType(GuideStepView), findsOneWidget);
    });

    testWidgets('a guide with no variant for the band says so instead of rendering steps', (t) async {
      // why: "a guide with no variant for the user's band says so".
      final g = Guide(id: 'g', title: (_) => 'T', variants: [
        GuideVariant(devices: {BandGeneration.whoop4}, steps: [s('Alpha')]),
      ]);
      await pumpGuide(t, g, BandGeneration.whoop5);
      expect(t.takeException(), isNull);
      expect(find.byKey(GuideView.noVariantKey), findsOneWidget);
      expect(find.byType(GuideStepView), findsNothing);
    });
  });
}
