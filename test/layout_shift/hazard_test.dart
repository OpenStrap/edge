// Hazard floor: shifts of the source, the focused and packed controls are not
// free inside the interaction window, whatever the latency curve says.
//
// Viewport 100 x 100. Reference mover M: 50x50 at (0,0) -> (0,20), role other:
//   union 50x70 = 0.35, distance 0.2, base = 0.07.
// Interaction at 1000 (source 'src'); the shift lands at 1000 + t.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

import '../support/shift_builders.dart';

const _a = ShiftRect(0, 0, 50, 50);
const _b = ShiftRect(0, 20, 50, 50);
const _ix = [Interaction(1000, 'src')];

/// Shift findings only (the load finding has its own tests).
double shifts(Scenario s, [ShiftPolicy p = ShiftPolicy.standard]) => score(s, p)
    .findings
    .where((f) => f.rule == 'shift')
    .fold(0.0, (a, f) => a + f.score);

double covers(Scenario s, [ShiftPolicy p = ShiftPolicy.standard]) => score(s, p)
    .findings
    .where((f) => f.rule == 'cover')
    .fold(0.0, (a, f) => a + f.score);

/// [id] moves M-style at 1000 + [t].
Scenario _move(String id,
        {int t = 0,
        ElementRole role = ElementRole.other,
        bool focused = false,
        List<Interaction> ix = _ix,
        List<FocusEvent> focus = const []}) =>
    sc([
      fr(1000, [el(id, _a, role: role, focused: focused)]),
      fr(1000 + t, [el(id, _b, role: role, focused: focused)]),
    ], interactions: ix, focus: focus);

void main() {
  group('source', () {
    test('the source moving at 0 ms: 0.07 * 0.5 = 0.035', () {
      expect(shifts(_move('src')), closeTo(0.035, 1e-9));
    });
    test('a non-source mover at 0 ms stays free', () {
      expect(shifts(_move('x')), 0);
    });
    test('packed sibling of the source: .009 * .5 * 3 = .0135', () {
      // src control (0,0,20,20) static. sib control 10x10 (22,0)->(22,20):
      // gap 2 < 8. union 10x30 = 0.03, d 0.2 => base 0.006; control 1.5 =
      // 0.009; floor max(source .5, dense .3) = .5 => .0045; dense x3 = .0135.
      final s = sc([
        fr(1000, [
          el('src', const ShiftRect(0, 0, 20, 20), role: ElementRole.control),
          el('sib', const ShiftRect(22, 0, 10, 10), role: ElementRole.control),
        ]),
        fr(1000, [
          el('src', const ShiftRect(0, 0, 20, 20), role: ElementRole.control),
          el('sib', const ShiftRect(22, 20, 10, 10), role: ElementRole.control),
        ]),
      ], interactions: _ix);
      expect(shifts(s), closeTo(0.0135, 1e-9));
    });
    test('a control far from the source gets no floor', () {
      final s = sc([
        fr(1000, [
          el('src', const ShiftRect(0, 0, 20, 20), role: ElementRole.control),
          el('far', const ShiftRect(60, 0, 10, 10), role: ElementRole.control),
        ]),
        fr(1000, [
          el('src', const ShiftRect(0, 0, 20, 20), role: ElementRole.control),
          el('far', const ShiftRect(60, 20, 10, 10), role: ElementRole.control),
        ]),
      ], interactions: _ix);
      expect(shifts(s), 0);
    });
  });

  group('focus', () {
    test('focused in the after frame: 0.07 * .5 * 2 = 0.07', () {
      expect(shifts(_move('x', focused: true)), closeTo(0.07, 1e-9));
    });
    test('focused only in the before frame: 0.07 * .5 = 0.035', () {
      final s = sc([
        fr(1000, [el('x', _a, focused: true)]),
        fr(1000, [el('x', _b)]),
      ], interactions: _ix);
      expect(shifts(s), closeTo(0.035, 1e-9));
    });
    test('recent focus history (age 100 < half-life): 0.035', () {
      expect(shifts(_move('x', focus: const [FocusEvent(900, 'x')])),
          closeTo(0.035, 1e-9));
    });
    test('focus history exactly one half-life old still counts (w = .5)', () {
      expect(shifts(_move('x', focus: const [FocusEvent(-1000, 'x')])),
          closeTo(0.035, 1e-9));
    });
    test('stale focus history (age 2500 > half-life) is free', () {
      expect(shifts(_move('x', focus: const [FocusEvent(-1500, 'x')])), 0);
    });
  });

  group('dense', () {
    test('packed control shifting against a neighbour: .009*.3*3 = .0081', () {
      final s = sc([
        fr(1000, [
          el('a', const ShiftRect(0, 0, 20, 20), role: ElementRole.control),
          el('b', const ShiftRect(22, 0, 10, 10), role: ElementRole.control),
        ]),
        fr(1000, [
          el('a', const ShiftRect(0, 0, 20, 20), role: ElementRole.control),
          el('b', const ShiftRect(22, 20, 10, 10), role: ElementRole.control),
        ]),
      ], interactions: const [Interaction(1000, 'elsewhere')]);
      expect(shifts(s), closeTo(0.0081, 1e-9));
    });
  });

  group('exemptions and limits', () {
    test('the intent target gets no floor', () {
      expect(
          shifts(_move('x', ix: const [
            Interaction(1000, 'src', intentTargetId: 'x')
          ])),
          0);
    });
    test('the intent target gets no floor even when focused', () {
      expect(
          shifts(_move('x', focused: true, ix: const [
            Interaction(1000, 'src', intentTargetId: 'x')
          ])),
          0);
    });
    test('floor raises only: t=300 source .3 -> .5 => .035', () {
      expect(shifts(_move('src', t: 300)), closeTo(0.035, 1e-9));
    });
    test('floor never lowers a high latency: t=450 L=.75 => .0525', () {
      expect(shifts(_move('src', t: 450)), closeTo(0.0525, 1e-9));
    });
    test('out of window cost is untouched: t=600 => .07', () {
      expect(shifts(_move('src', t: 600)), closeTo(0.07, 1e-9));
    });
    test('no prior interaction: out of window cost, no floor change', () {
      expect(shifts(_move('src', ix: const [])), closeTo(0.07, 1e-9));
    });
    test('disabled shield still discounts: .07*.5*2*.8 = .056', () {
      ElementSnapshot x(ShiftRect r, bool en) =>
          el('x', r, focused: true, enabled: en);
      final s = sc([
        fr(900, [x(_a, true)]),
        fr(1000, [x(_b, false)]),
        fr(1500, [x(_b, false)]),
        fr(1600, [x(_b, true)]),
      ], interactions: _ix);
      expect(shifts(s), closeTo(0.056, 1e-9));
    });
  });

  group('cover', () {
    Scenario cover({bool source = false, bool focused = false}) => sc([
          fr(1000, [
            el(source ? 'src' : 'btn', _a, focusable: true, focused: focused),
          ]),
          fr(1000, [
            el(source ? 'src' : 'btn', _a, focusable: true, focused: focused),
            el('toast', _a),
          ]),
        ], interactions: _ix);
    test('covering the source: 1 * 1 * .5 = .5', () {
      expect(covers(cover(source: true)), closeTo(0.5, 1e-9));
    });
    test('covering a focused element: 1 * .5 * 2 = 1', () {
      expect(covers(cover(focused: true)), closeTo(1.0, 1e-9));
    });
    test('covering an unrelated element at 0 ms stays free', () {
      expect(covers(cover()), 0);
    });
  });

  group('policy', () {
    test('defaults', () {
      const p = ShiftPolicy.standard;
      expect([p.sourceShiftFloor, p.focusShiftFloor, p.denseShiftFloor],
          [0.5, 0.5, 0.3]);
    });
    test('presets: strict >= standard >= lenient', () {
      const s = ShiftPolicy.strict,
          d = ShiftPolicy.standard,
          l = ShiftPolicy.lenient;
      expect([s.sourceShiftFloor, s.focusShiftFloor, s.denseShiftFloor],
          [0.75, 0.75, 0.5]);
      expect([l.sourceShiftFloor, l.focusShiftFloor, l.denseShiftFloor],
          [0.3, 0.3, 0.15]);
      expect(s.sourceShiftFloor >= d.sourceShiftFloor, isTrue);
      expect(d.sourceShiftFloor >= l.sourceShiftFloor, isTrue);
      expect(s.focusShiftFloor >= d.focusShiftFloor, isTrue);
      expect(d.focusShiftFloor >= l.focusShiftFloor, isTrue);
      expect(s.denseShiftFloor >= d.denseShiftFloor, isTrue);
      expect(d.denseShiftFloor >= l.denseShiftFloor, isTrue);
    });
    test('strict and lenient change the source cost: .0525 / .021', () {
      expect(shifts(_move('src'), ShiftPolicy.strict), closeTo(0.0525, 1e-9));
      expect(shifts(_move('src'), ShiftPolicy.lenient), closeTo(0.021, 1e-9));
    });
    test('copyWith tunes each floor; zero turns the floor off', () {
      final p = ShiftPolicy.standard.copyWith(sourceShiftFloor: 0.9);
      expect(shifts(_move('src'), p), closeTo(0.063, 1e-9));
      final off = ShiftPolicy.standard.copyWith(sourceShiftFloor: 0);
      expect(shifts(_move('src'), off), 0);
      expect(
          ShiftPolicy.standard
              .copyWith(focusShiftFloor: 0.2, denseShiftFloor: 0.1)
              .focusShiftFloor,
          0.2);
    });
  });
}
