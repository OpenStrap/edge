// GuideTarget: how a guide finds "the thing to tap" on the real, laid-out
// screen. Resolution is by TRANSLATED label (so it follows the user's
// language) or by Key, and a miss is a typed failure - never an empty result
// that would render a guide pointing at nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/guides/guide_target.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../support/skeleton_fixture.dart';

const _root = ValueKey('root');

// Literals from lib/l10n/app_en.arb and app_de.arb (dayStrainHowSet).
const _enHowSet = 'How these are set';
const _deHowSet = 'Wie die Zonen festgelegt werden';

/// A Section whose action is the translated label, as DayStrainDetail builds it.
Widget _sectionWithAction(AppLocalizations l) => Section(
      l.dayStrainTimeInZonesSection,
      const Surface(child: Text('chart')),
      action: l.dayStrainHowSet,
      onAction: () {},
    );

Future<(Element, AppLocalizations)> _pumpIn(
  WidgetTester t,
  Locale locale,
  Widget Function(AppLocalizations) body,
) async {
  skTallView(t);
  late AppLocalizations l;
  await t.pumpWidget(skHost(
    Builder(builder: (c) {
      l = AppLocalizations.of(c)!;
      return Scaffold(
        body: Padding(
          padding: const EdgeInsets.fromLTRB(16, 40, 0, 0),
          child: Align(alignment: Alignment.topLeft, child: SizedBox(key: _root, width: 360, child: body(l))),
        ),
      );
    }),
    locale: locale,
  ));
  return (t.element(find.byKey(_root)), l);
}

void main() {
  group('by translated label', () {
    for (final (locale, literal) in [
      (const Locale('en'), _enHowSet),
      (const Locale('de'), _deHowSet),
    ]) {
      testWidgets('resolves in ${locale.languageCode}, to the tappable around the text', (t) async {
        // why: the SAME guide target must work in every language. The literal
        // is read from the arb, so a getter pointing at another string fails.
        // The rect grows to the enclosing Pressable (Section's action) so the
        // outline wraps the whole tap area, not just its caption.
        final (root, l) = await _pumpIn(t, locale, _sectionWithAction);
        expect(l.dayStrainHowSet, literal, reason: 'fixture sanity');

        final r = GuideTarget.label((l) => l.dayStrainHowSet).resolve(root, l);
        expect(r, isA<TargetFound>());
        final rect = (r as TargetFound).rect;

        final pressable = skLocalRect(t, find.ancestor(of: find.text(literal), matching: find.byType(Pressable)).first,
            find.byKey(_root));
        final text = skLocalRect(t, find.text(literal), find.byKey(_root));
        expect(rect.left, closeTo(pressable.left, 0.5));
        expect(rect.top, closeTo(pressable.top, 0.5));
        expect(rect.width, closeTo(pressable.width, 0.5));
        expect(rect.height, closeTo(pressable.height, 0.5));
        expect(skContains(rect, text), isTrue);
        expect(rect.width, greaterThan(text.width), reason: 'grew past the bare text (Pressable padding)');
      });
    }

    testWidgets('a label in the WRONG language does not match (de UI, English text on screen)', (t) async {
      // why: matching is against the CURRENT locale's string. A stale English
      // string on a German screen must fail loudly, not resolve.
      final (root, l) = await _pumpIn(t, const Locale('de'), (_) => const Text(_enHowSet));
      final r = GuideTarget.label((l) => l.dayStrainHowSet).resolve(root, l);
      expect(r, isA<TargetAbsent>());
    });

    testWidgets('matches Text.rich plain text, trimmed, and an explicit Semantics label', (t) async {
      // why: real screens build labels as rich text; icon-only controls
      // carry only a Semantics label.
      final (root, l) = await _pumpIn(
        t,
        const Locale('en'),
        (_) => Column(children: [
          const Text.rich(TextSpan(children: [TextSpan(text: 'Rich '), TextSpan(text: 'label')])),
          const Text('  padded  '),
          Semantics(label: 'Close sheet', child: const SizedBox(width: 40, height: 40)),
        ]),
      );
      expect(GuideTarget.label((_) => 'Rich label').resolve(root, l), isA<TargetFound>());
      expect(GuideTarget.label((_) => 'padded').resolve(root, l), isA<TargetFound>());
      final sem = GuideTarget.label((_) => 'Close sheet').resolve(root, l);
      expect(sem, isA<TargetFound>());
      expect((sem as TargetFound).rect.size, const Size(40, 40));
    });

    testWidgets('matching ignores letter case: Home prints its ring labels upper-cased', (t) async {
      // why: home_screen.dart:1215 prints `r.label.toUpperCase()`, so the Text on
      // the Today tab reads "STRAIN" while the arb string (and the guide's
      // target) is "Strain". An exact-case match could never find the ring.
      // Still exact otherwise: a different word does not match.
      final (root, l) = await _pumpIn(
        t,
        const Locale('en'),
        (_) => Column(children: [
          Pressable(onTap: () {}, child: const Text('STRAIN')),
          const Text('Strains'),
        ]),
      );
      expect(GuideTarget.label((_) => 'Strain').resolve(root, l), isA<TargetFound>());
      expect(GuideTarget.label((_) => 'Strai').resolve(root, l), isA<TargetAbsent>());
    });

    testWidgets('a target with no Pressable ancestor resolves to its own text rect', (t) async {
      // why: "grow to the Pressable" must not grow to the whole screen when
      // there is none (Section titles are plain text).
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => const Column(children: [Text('Plain')]));
      final r = GuideTarget.label((_) => 'Plain').resolve(root, l) as TargetFound;
      expect(r.rect, skLocalRect(t, find.text('Plain'), find.byKey(_root)));
    });

    testWidgets('rects are in the ROOT element coordinates, not the screen\'s', (t) async {
      // why: the overlay draws in the root's space; the root sits at (16, 40).
      final (root, l) = await _pumpIn(
          t, const Locale('en'), (_) => const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Plain')]));
      final r = GuideTarget.label((_) => 'Plain').resolve(root, l) as TargetFound;
      expect(r.rect.topLeft, isNot(t.getTopLeft(find.text('Plain'))));
      expect(r.rect.left, closeTo(0, 0.5));
    });
  });

  group('by Key', () {
    testWidgets('resolves to the keyed widget exactly, without growing to a Pressable', (t) async {
      // why: a Key target means "this exact widget"; growing would outline
      // more than the guide named.
      const k = ValueKey('target');
      final (root, l) = await _pumpIn(
        t,
        const Locale('en'),
        (_) => Column(children: [
          Pressable(onTap: () {}, child: const Padding(padding: EdgeInsets.all(20), child: SizedBox(key: k, width: 50, height: 30))),
        ]),
      );
      final r = GuideTarget.key(k).resolve(root, l) as TargetFound;
      expect(r.rect.size, const Size(50, 30));
      expect(r.rect, skLocalRect(t, find.byKey(k), find.byKey(_root)));
    });
  });

  group('outcomes are typed and loud (found / notBuilt / absent / ambiguous)', () {
    testWidgets('a missing label in a fully built, non-scrolling tree is TargetAbsent naming what was sought',
        (t) async {
      // why: "unresolved target = typed failure (no silent empty guide)".
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => const Text('something else'));
      final r = GuideTarget.label((_) => 'Nowhere to be seen').resolve(root, l);
      switch (r) {
        case TargetAbsent(:final detail):
          expect(detail, contains('Nowhere to be seen'));
        case TargetFound() || TargetNotBuilt() || TargetAmbiguous():
          fail('expected absent, got $r');
      }
    });

    testWidgets('a missing label under a lazy list with room left is TargetNotBuilt, not Absent', (t) async {
      // why: the item may simply not be built yet. Saying "absent" would stop a
      // guide that scrolling could have completed.
      final (root, l) = await _pumpIn(
        t,
        const Locale('en'),
        (_) => SizedBox(
          height: 200,
          child: ListView.builder(
            cacheExtent: 0,
            itemCount: 100,
            itemBuilder: (_, i) => SizedBox(height: 50, child: Text('row $i')),
          ),
        ),
      );
      final r = GuideTarget.label((_) => 'row 90').resolve(root, l);
      expect(r, isA<TargetNotBuilt>());
    });

    testWidgets('a missing key is TargetAbsent', (t) async {
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => const Text('x'));
      expect(GuideTarget.key(const ValueKey('absent')).resolve(root, l), isA<TargetAbsent>());
    });

    testWidgets('a match that is Offstage is absent', (t) async {
      // why: an offstage widget has no place on screen; resolving it would
      // outline empty space.
      final (root, l) = await _pumpIn(t, const Locale('en'),
          (_) => const Column(children: [Offstage(child: Text('Hidden label'))]));
      expect(GuideTarget.label((_) => 'Hidden label').resolve(root, l), isA<TargetAbsent>());
    });

    testWidgets('two DISTINCT controls with the label are TargetAmbiguous with the count', (t) async {
      // why: a guide that silently points at the first of two "Strain" controls
      // is a wrong guide.
      final (root, l) = await _pumpIn(
        t,
        const Locale('en'),
        (_) => Column(children: [
          Pressable(onTap: () {}, child: const Text('Strain')),
          Pressable(onTap: () {}, child: const Text('Strain')),
        ]),
      );
      final r = GuideTarget.label((_) => 'Strain').resolve(root, l);
      expect(r, isA<TargetAmbiguous>());
      expect((r as TargetAmbiguous).count, 2);
    });

    testWidgets('one control seen twice (Text + Semantics label) counts once and is found', (t) async {
      // why: ui2 controls often carry both the visible Text and a Semantics
      // label with the same words; that is ONE control, not two matches.
      final (root, l) = await _pumpIn(
        t,
        const Locale('en'),
        (_) => Pressable(
          onTap: () {},
          child: Semantics(label: 'Strain', child: const Text('Strain')),
        ),
      );
      expect(GuideTarget.label((_) => 'Strain').resolve(root, l), isA<TargetFound>());
    });

    testWidgets('a control whose Text appears twice inside the SAME Pressable counts once', (t) async {
      // why: "same nearest Pressable" is the dedupe rule (title + subtitle echo).
      final (root, l) = await _pumpIn(
        t,
        const Locale('en'),
        (_) => Pressable(onTap: () {}, child: const Column(children: [Text('Open'), Text('Open')])),
      );
      expect(GuideTarget.label((_) => 'Open').resolve(root, l), isA<TargetFound>());
    });

    testWidgets('a semantics-only control (no Text) is found by its label', (t) async {
      // why: icon buttons have no text; the guide must still be able to point
      // at them.
      final (root, l) = await _pumpIn(
        t,
        const Locale('en'),
        // Align: a bare child of the 360 px root would be forced to its width.
        (_) => Align(
            alignment: Alignment.topLeft,
            child: Semantics(button: true, label: 'Close sheet', child: const SizedBox(width: 40, height: 40))),
      );
      final r = GuideTarget.label((_) => 'Close sheet').resolve(root, l);
      expect(r, isA<TargetFound>());
      expect((r as TargetFound).rect.size, const Size(40, 40));
    });

    testWidgets('a found target never has an empty rect', (t) async {
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => const Text('Plain'));
      final r = GuideTarget.label((_) => 'Plain').resolve(root, l) as TargetFound;
      expect(r.rect.isEmpty, isFalse);
    });

    testWidgets('the sealed result is exhaustively switchable', (t) async {
      // why: compile-time guard that callers must handle all four outcomes.
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => const Text('Plain'));
      final r = GuideTarget.label((_) => 'Plain').resolve(root, l);
      final name = switch (r) {
        TargetFound() => 'found',
        TargetNotBuilt() => 'notBuilt',
        TargetAbsent() => 'absent',
        TargetAmbiguous() => 'ambiguous',
      };
      expect(name, 'found');
    });
  });

  group('within: scoping a label to an ancestor', () {
    testWidgets('the same label in two sections resolves inside the scoped one only', (t) async {
      // why: DayStrainDetail prints "Time in zones" as a Section title AND as
      // the chart title. Scoping by a Key lets a guide name the one it means.
      const a = ValueKey('secA'), b = ValueKey('secB');
      final (root, l) = await _pumpIn(
        t,
        const Locale('en'),
        (_) => const Column(children: [
          SizedBox(key: a, child: Text('Time in zones')),
          SizedBox(key: b, child: Text('Time in zones')),
        ]),
      );
      expect(GuideTarget.label((_) => 'Time in zones').resolve(root, l), isA<TargetAmbiguous>());
      final scoped = GuideTarget.label((_) => 'Time in zones', within: GuideTarget.key(b)).resolve(root, l);
      expect(scoped, isA<TargetFound>());
      final rect = (scoped as TargetFound).rect;
      expect(rect, skLocalRect(t, find.descendant(of: find.byKey(b), matching: find.text('Time in zones')), find.byKey(_root)));
    });

    testWidgets('a scope that is absent makes the target absent (never falls back to an unscoped match)',
        (t) async {
      // why: falling back would point at the wrong duplicate.
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => const Text('Time in zones'));
      final r = GuideTarget.label((_) => 'Time in zones', within: GuideTarget.key(const ValueKey('nope'))).resolve(root, l);
      expect(r, isA<TargetAbsent>());
    });
  });

  group('anyLabel: state-dependent text (item 6)', () {
    testWidgets('matches whichever alternative is on screen, in the current locale', (t) async {
      // why: ZonesDetail prints "Set your own zones" or, once saved, "Edit your
      // own zones" (zones.dart:334). One guide target must follow both.
      for (final locale in [const Locale('en'), const Locale('de')]) {
        for (final saved in [false, true]) {
          late AppLocalizations l0;
          final (root, l) = await _pumpIn(t, locale, (l) {
            l0 = l;
            return Pressable(onTap: () {}, child: Text(saved ? l.activityZonesEditYourOwnLink : l.activityZonesSetYourOwnLink));
          });
          final target = GuideTarget.anyLabel([(l) => l.activityZonesSetYourOwnLink, (l) => l.activityZonesEditYourOwnLink]);
          expect(target.resolve(root, l), isA<TargetFound>(), reason: '${locale.languageCode} saved=$saved');
          expect(l0.activityZonesSetYourOwnLink, isNot(l0.activityZonesEditYourOwnLink), reason: 'fixture sanity');
        }
      }
    });

    testWidgets('with none of the alternatives on screen it is absent, and the detail lists them', (t) async {
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => const Text('unrelated'));
      final r = GuideTarget.anyLabel([(_) => 'Alpha', (_) => 'Beta']).resolve(root, l);
      expect(r, isA<TargetAbsent>());
      expect((r as TargetAbsent).detail, allOf(contains('Alpha'), contains('Beta')));
    });
  });

  group('revealTarget: bounded scroll discovery (item 4)', () {
    Widget list({int count = 100, double cache = 0, ScrollController? c, Widget Function(int)? row}) => SizedBox(
          height: 200,
          child: ListView.builder(
            controller: c,
            cacheExtent: cache,
            itemCount: count,
            itemBuilder: (_, i) => SizedBox(height: 50, child: row?.call(i) ?? Text('row $i', style: const TextStyle(fontSize: 10))),
          ),
        );

    testWidgets('finds a target 5 viewports away with cacheExtent 0, and leaves it visible',
        (t) async {
      // why: the resolver alone cannot see an unbuilt lazy child; the 200 px
      // viewport shows rows 0-3, row 20 is 1000 px (5 viewports) down.
      final c = ScrollController();
      addTearDown(c.dispose);
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => list(c: c));
      final target = GuideTarget.label((_) => 'row 20');
      expect(target.resolve(root, l), isA<TargetNotBuilt>(), reason: 'precondition: not built yet');

      final r = await revealTarget(root, target, l);
      await t.pump();
      expect(r, isA<TargetFound>());
      final rect = (r as TargetFound).rect;
      final viewport = skLocalRect(t, find.byType(ListView), find.byKey(_root));
      expect(skContains(viewport, rect), isTrue, reason: 'target $rect must end inside the viewport $viewport');
      expect(c.offset, greaterThan(0));
    });

    testWidgets('nested scrolling: a target deep inside an inner list inside an outer list', (t) async {
      // why: guide screens nest lists (a card holding a list). Discovery must
      // advance the outer list to the card, then the inner one.
      final (root, l) = await _pumpIn(
        t,
        const Locale('en'),
        (_) => SizedBox(
          height: 300,
          child: ListView(cacheExtent: 0, children: [
            const SizedBox(height: 1500),
            SizedBox(
              height: 200,
              child: ListView.builder(
                cacheExtent: 0,
                itemCount: 60,
                itemBuilder: (_, i) => SizedBox(height: 50, child: Text('inner $i')),
              ),
            ),
            const SizedBox(height: 600),
          ]),
        ),
      );
      final r = await revealTarget(root, GuideTarget.label((_) => 'inner 40'), l);
      await t.pump();
      expect(r, isA<TargetFound>());
    });

    testWidgets('starts near the bottom: a target ABOVE the built range is found (G3)', (t) async {
      // why: revealTarget used to search forward only, so a screen restored to
      // a scrolled-down position never found a target above it. 100 rows of 50
      // px in a 200 px viewport, parked at the bottom (rows 96-99 built): row 60
      // sits (4800 - 3000) / 200 = 9 viewports up, inside the budget of 20.
      // Fails if only the forward direction is searched.
      final c = ScrollController();
      addTearDown(c.dispose);
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => list(c: c));
      c.jumpTo(c.position.maxScrollExtent);
      await t.pump();
      final target = GuideTarget.label((_) => 'row 60');
      expect(target.resolve(root, l), isA<TargetNotBuilt>(), reason: 'precondition: above the built range');
      final r = await revealTarget(root, target, l);
      await t.pump();
      expect(r, isA<TargetFound>());
      final viewport = skLocalRect(t, find.byType(ListView), find.byKey(_root));
      expect(skContains(viewport, (r as TargetFound).rect), isTrue);
    });

    testWidgets('budget spent in the middle of a long list: NotBuilt, original offset restored (G3)', (t) async {
      // why: parked at 2500 (row 50) with the target absent, BOTH ends are
      // 11+ viewports away and the budget is 3: the search must say "gave up"
      // (not "absent") and put the screen back where the user left it, not at
      // the end it was probing last.
      final c = ScrollController();
      addTearDown(c.dispose);
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => list(c: c));
      c.jumpTo(2500);
      await t.pump();
      final r = await revealTarget(root, GuideTarget.label((_) => 'no such row'), l, maxViewports: 3);
      await t.pump();
      expect(r, isA<TargetNotBuilt>());
      expect(c.offset, 2500);
    });

    testWidgets('the end reached without a match: TargetAbsent, scroll position restored', (t) async {
      // why: "exhausted search fails" - Absent only when EVERY searchable range
      // is exhausted (G3: both directions from offset 100, so the top 100 px
      // are searched too) - and must not leave the screen scrolled to either
      // end as a side effect.
      final c = ScrollController();
      addTearDown(c.dispose);
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => list(count: 30, c: c));
      c.jumpTo(100);
      await t.pump();
      final r = await revealTarget(root, GuideTarget.label((_) => 'no such row'), l);
      await t.pump();
      expect(r, isA<TargetAbsent>());
      expect(c.offset, 100);
    });

    testWidgets('budget spent before the end: TargetNotBuilt (not Absent), position restored', (t) async {
      // why: a bounded search must say "gave up", not "does not exist": row 90
      // exists, 18 viewports down, and the budget is 3 (per direction; from the
      // top there is nothing above to search).
      final c = ScrollController();
      addTearDown(c.dispose);
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => list(c: c));
      final r = await revealTarget(root, GuideTarget.label((_) => 'row 90'), l, maxViewports: 3);
      await t.pump();
      expect(r, isA<TargetNotBuilt>());
      expect(c.offset, 0);
    });

    testWidgets('an already-found target is returned without scrolling', (t) async {
      // why: no needless motion for steps whose target is on screen.
      final c = ScrollController();
      addTearDown(c.dispose);
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => list(c: c));
      final r = await revealTarget(root, GuideTarget.label((_) => 'row 1'), l);
      expect(r, isA<TargetFound>());
      expect(c.offset, 0);
    });
  });
}
