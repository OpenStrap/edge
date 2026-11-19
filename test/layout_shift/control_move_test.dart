// Control move score: the area-fraction base makes a small control's jump
// nearly free, yet displacing a touch target under the finger causes
// mis-taps. A control with a hazard (source, packed sibling, focused, dense)
// scores at least controlMoveScore x min(1, displacement / controlMoveRefPx)
// (x denseMultiplier if dense, x disabledDiscount if shielded).
//
// Viewport 100 x 100. Mover 'c': 10x10 control at (0,0) -> (0,D).
// D = 48: union 10x58 = .058, distance .48, base .02784; x1.5 = .04176.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

import '../support/shift_builders.dart';

const _ix = [Interaction(1000, 'src')];
const _c = ElementRole.control;

double shifts(Scenario s, [ShiftPolicy p = ShiftPolicy.standard]) => score(s, p)
    .findings
    .where((f) => f.rule == 'shift')
    .fold(0.0, (a, f) => a + f.score);

Scenario _src(double d, {int t = 0, List<Interaction> ix = _ix}) => sc([
      fr(1000, [el('src', const ShiftRect(0, 0, 10, 10), role: _c)]),
      fr(1000 + t, [el('src', ShiftRect(0, d, 10, 10), role: _c)]),
    ], interactions: ix);

void main() {
  group('control move score', () {
    test('source control moves one touch target: .1', () {
      expect(shifts(_src(48)), closeTo(0.1, 1e-9));
    });
    test('half a touch target scales linearly: .05', () {
      expect(shifts(_src(24)), closeTo(0.05, 1e-9));
    });
    test('beyond a touch target clamps at .1 (existing score .0763)', () {
      expect(shifts(_src(96)), closeTo(0.1, 1e-9));
    });
    test('outside the window the control move still applies', () {
      expect(shifts(_src(48, t: 600)), closeTo(0.1, 1e-9));
    });
    test('a non-control source keeps the old score: .035', () {
      final s = sc([
        fr(1000, [el('src', const ShiftRect(0, 0, 50, 50))]),
        fr(1000, [el('src', const ShiftRect(0, 20, 50, 50))]),
      ], interactions: _ix);
      expect(shifts(s), closeTo(0.035, 1e-9));
    });
    test('a control far from the source has no hazard: 0', () {
      final s = sc([
        fr(1000, [
          el('src', const ShiftRect(0, 0, 20, 20), role: _c),
          el('far', const ShiftRect(60, 0, 10, 10), role: _c),
        ]),
        fr(1000, [
          el('src', const ShiftRect(0, 0, 20, 20), role: _c),
          el('far', const ShiftRect(60, 48, 10, 10), role: _c),
        ]),
      ], interactions: _ix);
      expect(shifts(s), 0);
    });
    test('packed sibling shifting against a neighbour: .1 x 3 = .3', () {
      final s = sc([
        fr(1000, [
          el('src', const ShiftRect(0, 0, 20, 20), role: _c),
          el('sib', const ShiftRect(22, 0, 10, 10), role: _c),
        ]),
        fr(1000, [
          el('src', const ShiftRect(0, 0, 20, 20), role: _c),
          el('sib', const ShiftRect(22, 48, 10, 10), role: _c),
        ]),
      ], interactions: _ix);
      final f = score(s, ShiftPolicy.standard)
          .findings
          .singleWhere((f) => f.rule == 'shift');
      expect(f.score, closeTo(0.3, 1e-9));
      expect(f.severity, ShiftSeverity.error);
    });
    test('the intent target is exempt', () {
      final s = _src(48, ix: const [Interaction(1000, 'src', intentTargetId: 'src')]);
      expect(shifts(s), 0);
    });
    test('a focused control moves: .1', () {
      final s = sc([
        fr(1000, [el('c', const ShiftRect(0, 0, 10, 10), role: _c, focused: true)]),
        fr(1000, [el('c', const ShiftRect(0, 48, 10, 10), role: _c, focused: true)]),
      ], interactions: _ix);
      expect(shifts(s), closeTo(0.1, 1e-9));
    });
    test('a shielded focused control: .1 x .8 = .08', () {
      ElementSnapshot x(double y, bool en) => el('c', ShiftRect(0, y, 10, 10),
          role: _c, focused: true, enabled: en);
      final s = sc([
        fr(900, [x(0, true)]),
        fr(1000, [x(48, false)]),
        fr(1500, [x(48, false)]),
        fr(1600, [x(48, true)]),
      ], interactions: _ix);
      expect(shifts(s), closeTo(0.08, 1e-9));
    });
  });

  group('policy', () {
    test('defaults and presets', () {
      expect([
        ShiftPolicy.standard.controlMoveScore,
        ShiftPolicy.standard.controlMoveRefPx
      ], [0.1, 48]);
      expect([
        ShiftPolicy.strict.controlMoveScore,
        ShiftPolicy.strict.controlMoveRefPx
      ], [0.15, 40]);
      expect([
        ShiftPolicy.lenient.controlMoveScore,
        ShiftPolicy.lenient.controlMoveRefPx
      ], [0.06, 64]);
    });
    test('strict .15 * 48/40 clamps to .15; lenient .06 * 48/64 = .045', () {
      expect(shifts(_src(48), ShiftPolicy.strict), closeTo(0.15, 1e-9));
      expect(shifts(_src(48), ShiftPolicy.lenient), closeTo(0.045, 1e-9));
    });
    test('copyWith tunes it; zero turns it off (old score .04176)', () {
      final p = ShiftPolicy.standard.copyWith(controlMoveScore: 0.2, controlMoveRefPx: 96);
      expect(shifts(_src(48), p), closeTo(0.1, 1e-9));
      final off = ShiftPolicy.standard.copyWith(controlMoveScore: 0);
      expect(shifts(_src(48), off), closeTo(0.02784 * 1.5 * 0.5, 1e-9));
    });
  });
}
