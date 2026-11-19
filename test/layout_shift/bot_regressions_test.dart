import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

import '../support/shift_builders.dart';

List<ShiftFinding> shifts(Scenario s, [ShiftPolicy p = ShiftPolicy.standard]) =>
    score(s, p).findings.where((f) => f.rule == 'shift').toList();

void main() {
  // why: invisible movement and colour must not spend the visible shift budget.
  test('offscreen movement and colour produce no shift', () {
    final s = sc([
      fr(0, [el('x', const ShiftRect(200, 0, 50, 50))]),
      fr(1000, [el('x', const ShiftRect(200, 20, 50, 50), color: 0xFFFFFFFF)]),
    ]);
    expect(shifts(s), isEmpty);
  });

  // why: hidden geometry must not inflate the visible colour impact.
  test('partly clipped colour uses only the visible area', () {
    const rect = ShiftRect(50, 0, 100, 100);
    final s = sc([
      fr(0, [el('x', rect)]),
      fr(1000, [el('x', rect, color: 0xFFFFFFFF)]),
    ]);
    // Visible area 5000/10000 * full colour delta * .5 colour weight.
    expect(shifts(s).single.score, closeTo(.25, 1e-9));
  });

  // why: changing only hidden bounds leaves the painted viewport unchanged.
  test('movement of hidden edges does not charge a full viewport', () {
    final s = sc([
      fr(0, [el('x', const ShiftRect(0, 0, 200, 100))]),
      fr(1000, [el('x', const ShiftRect(-10, 0, 220, 100))]),
    ]);
    expect(shifts(s), isEmpty);
  });

  // why: a size change around a fixed centre is still a visible layout shift.
  test('symmetric growth retains a nonzero size contribution', () {
    final s = sc([
      fr(0, [el('x', const ShiftRect(40, 40, 20, 20))]),
      fr(1000, [el('x', vp)]),
    ]);
    expect(shifts(s), hasLength(1));
    // Impact 1 * half the 80px dimension change / 100px viewport side.
    expect(shifts(s).single.score, closeTo(.4, 1e-9));
  });

  // why: disappearance cannot count toward a visible disabled interval.
  test('disabled shielding resets at absence and excludes the enabled frame', () {
    ElementSnapshot target(double top, bool enabled) => el('x',
        ShiftRect(0, top, 50, 50), focused: true, enabled: enabled);
    final broken = sc([
      fr(0, [target(0, false)]),
      fr(100, []),
      fr(500, [target(0, false)]),
      fr(550, [target(20, false)]),
      fr(600, [target(20, true)]),
    ]);
    final enabled = sc([
      fr(0, [target(0, false)]),
      fr(500, [target(20, true)]),
    ]);
    final noDiscount = ShiftPolicy.standard.copyWith(disabledDiscount: 1);
    for (final s in [broken, enabled]) {
      expect(shifts(s).single.score, shifts(s, noDiscount).single.score);
    }
    final continuous = sc([
      fr(0, [target(0, false)]),
      fr(250, [target(20, false)]),
      fr(500, [target(20, true)]),
    ]);
    expect(shifts(continuous).single.score,
        closeTo(shifts(continuous, noDiscount).single.score * .8, 1e-9));
  });

  // why: movement can remove focus in the same frame as it moves the target.
  test('focus amplification includes focus in the previous frame', () {
    final s = sc([
      fr(0, [el('x', const ShiftRect(0, 0, 50, 50), focused: true)]),
      fr(1000, [el('x', const ShiftRect(0, 20, 50, 50))]),
    ]);
    expect(shifts(s).single.score, closeTo(.07 * 2, 1e-9));
  });

  // why: coverage must compare geometry from matching frames, clipped to view.
  test('growing cover uses the old target bounds for previous coverage', () {
    final s = sc([
      fr(0, [el('cover', const ShiftRect(0, 0, 50, 50)),
        el('input', const ShiftRect(60, 0, 40, 40), focusable: true)]),
      fr(1000, [el('cover', const ShiftRect(0, 0, 100, 50)),
        el('input', const ShiftRect(0, 0, 40, 40), focusable: true)]),
    ]);
    final covers = score(s, ShiftPolicy.standard).findings
        .where((f) => f.rule == 'cover');
    expect(covers, hasLength(1));
    expect(covers.single.score, 1);
    final offscreen = sc([
      fr(0, [el('input', const ShiftRect(200, 0, 40, 40), focusable: true)]),
      fr(1000, [el('cover', const ShiftRect(200, 0, 100, 50)),
        el('input', const ShiftRect(200, 0, 40, 40), focusable: true)]),
    ]);
    expect(score(offscreen, ShiftPolicy.standard).findings
        .where((f) => f.rule == 'cover'), isEmpty);
  });

  // why: at least 90% coverage includes the exact documented boundary.
  test('exactly 90 percent placeholder coverage is free', () {
    Scenario filled(double width) => sc([
      fr(0, [el('skeleton', ShiftRect(0, 0, width, 100),
          role: ElementRole.placeholder)]),
      fr(1000, [el('content', vp)]),
      fr(1100, [el('content', vp)]),
    ], interactions: const [Interaction(0, 'source')]);
    List<ShiftFinding> appearances(double width) =>
        score(filled(width), ShiftPolicy.standard).findings
            .where((f) => f.rule == 'appear').toList();
    expect(appearances(90), isEmpty);
    expect(appearances(89), hasLength(1));
  });
}
