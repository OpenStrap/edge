// Laws the scorer must keep for any input.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

import '../support/shift_builders.dart';

/// A scenario with moves, a resize, a colour change, an interaction, focus and
/// an animation, scaled by [k] (rects only; times stay put). No dense control
/// pairs, since the dense gap is in absolute pixels and is not scale-free.
Scenario _busy(double k, {List<ElementSnapshot> extraStatic = const []}) {
  ShiftRect r(double l, double t, double w, double h) =>
      ShiftRect(l * k, t * k, w * k, h * k);
  return sc([
    fr(1000, [
      el('p', r(0, 0, 40, 20), role: ElementRole.paragraph),
      el('i', r(0, 30, 40, 10), role: ElementRole.input),
      el('c', r(50, 0, 20, 10), role: ElementRole.control, focusable: true),
      el('col', r(60, 60, 20, 20), color: 0xFF102030),
      ...extraStatic,
    ]),
    fr(1300, [
      el('p', r(0, 10, 40, 20), role: ElementRole.paragraph),
      el('i', r(0, 40, 40, 12), role: ElementRole.input),
      el('c', r(50, 0, 20, 10), role: ElementRole.control, focusable: true),
      el('col', r(60, 60, 20, 20), color: 0xFF405060),
      ...extraStatic,
    ]),
  ],
      viewport: ShiftRect(0, 0, 100 * k, 100 * k),
      interactions: const [Interaction(1000, 'c', intentTargetId: 'p')],
      focus: const [FocusEvent(900, 'c')],
      animations: const [AnimationSpan(1050, 1350, elementId: 'i')]);
}

void main() {
  test('no movement => total 0 and no findings', () {
    final s = sc([
      fr(0, [el('a', const ShiftRect(0, 0, 10, 10))]),
      fr(500, [el('a', const ShiftRect(0, 0, 10, 10))]),
      fr(900, [el('a', const ShiftRect(0, 0, 10, 10))]),
    ]);
    final r = score(s, ShiftPolicy.standard);
    expect(r.total, 0);
    expect(r.findings, isEmpty);
  });

  test('a busy scenario produces findings (guards the other laws)', () {
    expect(score(_busy(1), ShiftPolicy.standard).findings, isNotEmpty);
  });

  test('scores are never negative, under every preset', () {
    for (final p in [
      ShiftPolicy.standard,
      ShiftPolicy.strict,
      ShiftPolicy.lenient,
    ]) {
      final r = score(_busy(1), p);
      expect(r.total, greaterThanOrEqualTo(0));
      for (final f in r.findings) {
        expect(f.score, greaterThanOrEqualTo(0));
      }
    }
  });

  test('scaling every rect by 4 leaves each score unchanged', () {
    final a = score(_busy(1), ShiftPolicy.standard);
    final b = score(_busy(4), ShiftPolicy.standard);
    expect(b.findings.length, a.findings.length);
    for (var i = 0; i < a.findings.length; i++) {
      expect(b.findings[i].elementId, a.findings[i].elementId);
      expect(b.findings[i].score, closeTo(a.findings[i].score, 1e-9));
    }
    expect(b.total, closeTo(a.total, 1e-9));
  });

  test('adding a far, unrelated static element changes no finding', () {
    final base = score(_busy(1), ShiftPolicy.standard);
    final more = score(
        _busy(1, extraStatic: [
          el('far', const ShiftRect(90, 90, 5, 5), role: ElementRole.decorative),
        ]),
        ShiftPolicy.standard);
    expect(sig(more), sig(base));
  });

  test('element order within a frame does not change the total', () {
    final s = _busy(1);
    final flipped = Scenario(
      viewport: s.viewport,
      frames: [for (final f in s.frames) Frame(f.atMs, f.elements.reversed.toList())],
      interactions: s.interactions,
      focus: s.focus,
      animations: s.animations,
    );
    expect(total(flipped), closeTo(total(s), 1e-12));
  });

  test('deterministic: the same input twice gives an identical report', () {
    final s = _busy(1);
    expect(sig(score(s, ShiftPolicy.standard)),
        sig(score(s, ShiftPolicy.standard)));
    expect(sig(score(s, ShiftPolicy.standard)), isNotEmpty);
  });
  group('random rects (seeded)', () {
    // Rects anywhere around and inside the viewport, some empty, some far
    // larger than it. Every role, focus, colour and placeholder mixes in.
    List<ElementSnapshot> frame(Random rng, int n, double w, double h) => [
          for (var i = 0; i < n; i++)
            if (rng.nextInt(6) > 0)
              el('e$i', ShiftRect(
                  (rng.nextDouble() * 3 - 1) * w,
                  (rng.nextDouble() * 3 - 1) * h,
                  rng.nextInt(8) == 0 ? 0 : rng.nextDouble() * 2.5 * w,
                  rng.nextInt(8) == 0 ? 0 : rng.nextDouble() * 4 * h),
                  role: ElementRole.values[
                      rng.nextInt(ElementRole.values.length)],
                  color: 0xFF000000 | rng.nextInt(0xFFFFFF),
                  focusable: rng.nextBool(),
                  focused: rng.nextInt(5) == 0,
                  enabled: rng.nextInt(4) > 0),
        ];

    test('no NaN or Infinity reaches a finding; consistency stays bounded', () {
      final rng = Random(20261020);
      for (var run = 0; run < 300; run++) {
        final p = [
          ShiftPolicy.standard,
          ShiftPolicy.strict,
          ShiftPolicy.lenient,
        ][run % 3];
        final w = 1 + rng.nextDouble() * 999, h = 1 + rng.nextDouble() * 1999;
        final view = ShiftRect(rng.nextDouble() * 50, rng.nextDouble() * 50, w, h);
        final frames = [
          for (var f = 0; f < 4; f++) fr(f * 300, frame(rng, 8, w, h)),
        ];
        final s = sc(frames,
            viewport: view,
            interactions: [
              Interaction(0, 'e${rng.nextInt(8)}',
                  intentTargetId: 'e${rng.nextInt(8)}'),
              Interaction(500, 'e${rng.nextInt(8)}'),
            ],
            focus: [FocusEvent(200, 'e${rng.nextInt(8)}')],
            animations: const [AnimationSpan(100, 400, chainId: 'c')]);
        for (final f in score(s, p).findings) {
          expect(f.score.isFinite && f.score >= 0, isTrue,
              reason: 'run $run ${f.rule} ${f.elementId} ${f.score}');
        }
        // One consistency finding: at most one viewport x the largest
        // roleWeight x consistencyWeight, or the drift floor if larger.
        final wMax = [1.0, ...p.roleWeight.values].reduce(max);
        final bound = max(p.consistencyMoveScore, wMax * p.consistencyWeight);
        final c = compareLayouts(frames[0], frames[3], p, viewport: view);
        for (final f in c.findings) {
          expect(f.score.isFinite && f.score > 0, isTrue,
              reason: 'run $run ${f.elementId} ${f.score}');
          expect(f.score, lessThanOrEqualTo(bound + 1e-9),
              reason: 'run $run ${f.elementId}');
        }
      }
    });
  });

  test('a zero-area viewport is refused with ArgumentError', () {
    for (final v in const [
      ShiftRect(0, 0, 0, 100),
      ShiftRect(0, 0, 100, 0),
      ShiftRect(0, 0, -100, -100),
    ]) {
      final s = Scenario(
          viewport: v,
          frames: _busy(1).frames,
          interactions: _busy(1).interactions);
      expect(() => score(s, ShiftPolicy.standard), throwsArgumentError);
    }
  });
}
