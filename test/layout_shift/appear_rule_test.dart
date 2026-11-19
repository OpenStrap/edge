// The `appear` rule: content that appears after the initial paint, in space
// nothing reserved for it, is charged by how much of the viewport it takes and
// how late it lands. A skeleton the content fills in place is free. See
// docs/LAYOUT_SHIFT.md "Appearing content".
//
// Viewport 400 x 800 (area 320000). Standard policy: loadCurve (100,0)
// (400,.1) (1000,.3) (2000,.6) (4000,1), loadWeight .25, errorAt .25,
// appearWeight .5, appearCoveredFree .9.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

import '../support/shift_builders.dart';

const _vp = ShiftRect(0, 0, 400, 800);
const _card = ShiftRect(0, 0, 400, 300);
// A 22 x 22 spinner centred where the card will go. It is a loading
// indicator (InlineLoading), so it is a placeholder: the space it held is free.
const _spinner = ShiftRect(189, 139, 22, 22);

List<ShiftFinding> _appear(ShiftReport r) =>
    r.findings.where((f) => f.rule == 'appear').toList();

/// Interaction at 0; the first frame (16 ms, the initial paint) holds
/// [placeholder]; at [landMs] the placeholder is gone and [content] appears;
/// 100 ms later nothing has changed, so the screen counts as settled.
Scenario _load(
  int landMs, {
  ElementSnapshot? placeholder,
  ElementSnapshot? content,
  List<Interaction> interactions = const [Interaction(0, 'tap')],
}) {
  final ph =
      placeholder ?? el('spinner', _spinner, role: ElementRole.placeholder);
  final ct = content ?? el('card', _card);
  return sc([
    fr(16, [ph]),
    fr(landMs, [ct]),
    fr(landMs + 100, [ct]),
  ], viewport: _vp, interactions: interactions);
}

double _appearScore(Scenario s) {
  final a = _appear(score(s, ShiftPolicy.standard));
  expect(a, hasLength(1));
  return a.single.score;
}

void main() {
  const p = ShiftPolicy.standard;

  test('bare spinner then content: the card is charged as appearing', () {
    final r = score(_load(3000), p);
    final a = _appear(r);
    expect(a, hasLength(1));
    expect(a.single.elementId, 'card');
    expect(a.single.atMs, 3000);
    expect(a.single.score, greaterThan(0));
    // Load time alone (settled at 3000) is .25 * .8 = .2; appearing content
    // must raise the number above it.
    expect(r.total, greaterThan(p.loadWeight * p.loadAt(3000)));
  });

  test('skeleton fill: content landing on its placeholder is free', () {
    final skeleton = _load(3000,
        placeholder: el('skeleton', _card, role: ElementRole.placeholder));
    final r = score(skeleton, p);
    expect(_appear(r).where((f) => f.score > 0), isEmpty);
    // And the skeleton scores strictly better than the bare spinner.
    expect(r.total, lessThan(score(_load(3000), p).total));
  });

  group('placeholder: only a vanished placeholder covers for free', () {
    test('ElementRole.placeholder exists', () {
      expect(ElementRole.values, contains(ElementRole.placeholder));
    });

    // First-launch card swap: a real card is replaced in place by a different
    // real card 3 s after the tap. Same rect, but it is a replacement, not a
    // fill: charged as if nothing stood there.
    // .5 x 120000 / 320000 x loadAt(3000) .8 = .15
    for (final role in [ElementRole.other, ElementRole.paragraph]) {
      test('a real ${role.name} card swapped in place is charged', () {
        final s = _load(3000,
            placeholder: el('card:welcome', _card, role: role),
            content: el('card:today', _card));
        final a = _appear(score(s, p));
        expect(a, hasLength(1));
        expect(a.single.elementId, 'card:today');
        expect(a.single.atMs, 3000);
        expect(a.single.score, closeTo(0.5 * 120000 / 320000 * 0.8, 1e-9));
      });
    }

    test('a decorative element is not a placeholder either', () {
      final s = _load(3000,
          placeholder: el('art', _card, role: ElementRole.decorative),
          content: el('card', _card));
      expect(_appear(score(s, p)).single.score, greaterThan(0));
    });

    test('a placeholder replaced in place by its content stays free', () {
      final s = _load(3000,
          placeholder: el('skeleton:rings', _card, role: ElementRole.placeholder),
          content: el('card:rings', _card));
      expect(_appear(score(s, p)).where((f) => f.score > 0), isEmpty);
    });
  });

  test('initial paint is free: elements in the first frame after the tap', () {
    final s = sc([
      fr(16, [el('card', _card), el('row', const ShiftRect(0, 300, 400, 60))]),
      fr(500, [el('card', _card), el('row', const ShiftRect(0, 300, 400, 60))]),
    ], viewport: _vp, interactions: const [Interaction(0, 'tap')]);
    expect(_appear(score(s, p)), isEmpty);
  });

  test('later is worse: landing at 3000 ms costs more than at 500 ms', () {
    expect(_appearScore(_load(3000)), greaterThan(_appearScore(_load(500))));
  });

  test('long load: a spinner held 300 s reaches errorAt, never below 4 s', () {
    Scenario held(int landMs) => sc([
          fr(16, [el('spinner', _spinner)]),
          fr(1000, [el('spinner', _spinner)]),
          fr(landMs - 1000, [el('spinner', _spinner)]),
          fr(landMs, [el('card', _card)]),
          fr(landMs + 100, [el('card', _card)]),
        ], viewport: _vp, interactions: const [Interaction(0, 'tap')]);
    final long = score(held(300000), p);
    final short = score(held(4000), p);
    expect(_appear(long).where((f) => f.score > 0), isNotEmpty);
    expect(long.total, greaterThanOrEqualTo(p.errorAt));
    expect(long.total, greaterThanOrEqualTo(short.total));
    // More than load time alone could ever charge.
    expect(long.total, greaterThan(p.loadWeight));
  });

  test('content appearing wholly outside the viewport is not charged', () {
    final below = _load(3000,
        content: el('card', const ShiftRect(0, 900, 400, 300)));
    expect(_appear(score(below, p)).where((f) => f.score > 0), isEmpty);
  });

  test('no interactions => no appear findings', () {
    expect(_appear(score(_load(3000, interactions: const []), p)), isEmpty);
  });

  group('policy knobs', () {
    test('presets', () {
      expect(ShiftPolicy.standard.appearWeight, 0.5);
      expect(ShiftPolicy.standard.appearCoveredFree, 0.9);
      expect(ShiftPolicy.strict.appearWeight, 0.75);
      expect(ShiftPolicy.lenient.appearWeight, 0.3);
    });
    test('copyWith round-trips', () {
      final q = ShiftPolicy.standard
          .copyWith(appearWeight: 0.2, appearCoveredFree: 0.8);
      expect(q.appearWeight, 0.2);
      expect(q.appearCoveredFree, 0.8);
      final same = ShiftPolicy.standard.copyWith();
      expect(same.appearWeight, ShiftPolicy.standard.appearWeight);
      expect(same.appearCoveredFree, ShiftPolicy.standard.appearCoveredFree);
    });
    test('appearWeight scales the finding linearly', () {
      final base = _appear(score(_load(3000), p)).single.score;
      final doubled = _appear(score(
              _load(3000), p.copyWith(appearWeight: p.appearWeight * 2)))
          .single
          .score;
      expect(doubled, closeTo(base * 2, 1e-9));
    });
  });

  test('score = appearWeight x uncovered/vpArea x loadAt(t - ix)', () {
    // uncovered = 120000 - 484 (the vanished spinner over the card) = 119516
    // .5 * 119516 / 320000 * .8
    expect(_appearScore(_load(3000)),
        closeTo(0.5 * 119516 / 320000 * 0.8, 1e-9));
  });
}
