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
      expect(r, isA<TargetNotFound>());
      expect((r as TargetNotFound).reason, TargetFailure.noMatch);
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

    testWidgets('a target with no Pressable ancestor resolves to its own text rect', (t) async {
      // why: "grow to the Pressable" must not grow to the whole screen when
      // there is none (Section titles are plain text).
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => const Column(children: [Text('Plain')]));
      final r = GuideTarget.label((_) => 'Plain').resolve(root, l) as TargetFound;
      expect(r.rect, skLocalRect(t, find.text('Plain'), find.byKey(_root)));
    });

    testWidgets('rects are in the ROOT element coordinates, not the screen\'s', (t) async {
      // why: the overlay draws in the root's space; the root sits at (16, 40).
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => const Column(children: [Text('Plain')]));
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

  group('failure is typed and loud', () {
    testWidgets('a missing label is TargetNotFound(noMatch) that names what was sought', (t) async {
      // why: "unresolved target = typed failure (no silent empty guide)".
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => const Text('something else'));
      final r = GuideTarget.label((_) => 'Nowhere to be seen').resolve(root, l);
      switch (r) {
        case TargetFound():
          fail('must not resolve: $r');
        case TargetNotFound(:final reason, :final detail):
          expect(reason, TargetFailure.noMatch);
          expect(detail, contains('Nowhere to be seen'));
      }
    });

    testWidgets('a missing key is TargetNotFound(noMatch)', (t) async {
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => const Text('x'));
      final r = GuideTarget.key(const ValueKey('absent')).resolve(root, l);
      expect(r, isA<TargetNotFound>());
      expect((r as TargetNotFound).reason, TargetFailure.noMatch);
    });

    testWidgets('two matches are TargetNotFound(ambiguous), not "the first one"', (t) async {
      // why: a guide that silently points at the first of two "Strain" labels
      // is a wrong guide. The count is in the detail.
      final (root, l) = await _pumpIn(t, const Locale('en'),
          (_) => const Column(children: [Text('Strain'), Text('Strain')]));
      final r = GuideTarget.label((_) => 'Strain').resolve(root, l);
      expect(r, isA<TargetNotFound>());
      expect((r as TargetNotFound).reason, TargetFailure.ambiguous);
      expect(r.detail, contains('2'));
    });

    testWidgets('a match that is Offstage is not a match', (t) async {
      // why: an offstage widget has no place on screen; resolving it would
      // outline empty space.
      final (root, l) = await _pumpIn(t, const Locale('en'),
          (_) => const Column(children: [Offstage(child: Text('Hidden label'))]));
      final r = GuideTarget.label((_) => 'Hidden label').resolve(root, l);
      expect(r, isA<TargetNotFound>());
    });

    testWidgets('a found target never has an empty rect', (t) async {
      // why: the result is either a real on-screen rect or a failure.
      final (root, l) = await _pumpIn(t, const Locale('en'), (_) => const Text('Plain'));
      final r = GuideTarget.label((_) => 'Plain').resolve(root, l) as TargetFound;
      expect(r.rect.isEmpty, isFalse);
    });
  });
}
