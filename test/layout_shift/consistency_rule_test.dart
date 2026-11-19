// The `consistency` rule: the same element should sit in the same place on
// two settled layouts the user compares in their head (screen A vs screen B
// for a shared control, visit 1 vs visit 2 of one screen, first launch vs
// loaded). No timing: a mismatch costs the same whenever it shows up.
//
// API under test:
//   compareLayouts(Frame a, Frame b, ShiftPolicy p,
//       {required ShiftRect viewport, bool Function(String id)? only})
// Viewport: Frame carries no viewport, and guessing one from the elements'
// bounding box would make the score depend on what happens to be on screen,
// so the caller passes it as a REQUIRED named argument (same value it would
// give Scenario.viewport).
//
// Formula (brief D2), viewport 400 x 800: vpArea 320000, vpSide 800.
//   both present: (union/vpArea x d/vpSide + |area change|/vpArea)
//                 x roleWeight x consistencyWeight
//                 d = centre distance (as the shift rule); displacement and
//                 size deltas <= consistencyTolerancePx are free.
//   drift floor, every role except placeholder (coordinator, 2026-10-20):
//     v = max(v, consistencyMoveScore x min(1, d/consistencyRefPx)) when
//     d > consistencyTolerancePx; a resize uses the same floor with
//     d = max(|dW|, |dH|); moved AND resized takes the larger floor. The floor
//     is NOT multiplied by consistencyWeight. controlMoveScore /
//     controlMoveRefPx are not used by this rule.
//   one frame only (and `only` passes it): area/vpArea x consistencyWeight
//     (no floor).
// Standard policy: roleWeight control 1.5, paragraph 2, other 1;
// consistencyMoveScore .1, consistencyRefPx 8, warnAt .05, errorAt .25.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

import '../support/shift_builders.dart';

const _vp = ShiftRect(0, 0, 400, 800);
const _avatar = ShiftRect(340, 16, 40, 40);
const _title = ShiftRect(16, 12, 200, 30);
const _content = ShiftRect(16, 100, 368, 100);
const _card = ShiftRect(16, 200, 368, 200);

ShiftRect _dx(ShiftRect r, double dx) =>
    ShiftRect(r.left + dx, r.top, r.width, r.height);

ElementSnapshot _av(ShiftRect r) =>
    el('shared:avatar', r, role: ElementRole.control);

ShiftReport _cmp(Frame a, Frame b,
        {ShiftPolicy p = ShiftPolicy.standard,
        bool Function(String id)? only}) =>
    compareLayouts(a, b, p, viewport: _vp, only: only);

List<ShiftFinding> _charged(ShiftReport r) =>
    r.findings.where((f) => f.score > 0).toList();

void main() {
  const p = ShiftPolicy.standard;

  test('identical frames: no findings', () {
    final f = [_av(_avatar), el('shared:title', _title, role: ElementRole.paragraph)];
    final r = _cmp(fr(0, f), fr(0, f));
    expect(r.findings, isEmpty);
    expect(r.total, 0);
  });

  group('shared control drift', () {
    test('moved 4 px: a warning, rule consistency', () {
      final r = _cmp(fr(0, [_av(_avatar)]), fr(0, [_av(_dx(_avatar, 4))]));
      final c = _charged(r);
      expect(c, hasLength(1));
      expect(c.single.rule, 'consistency');
      expect(c.single.elementId, 'shared:avatar');
      // area term: union 44x40 = 1760; 1760/320000 x 4/800 x 1.5 = 4.125e-5.
      // drift floor: .1 x min(1, 4/8) = .05 (wins) = warnAt.
      expect(c.single.score, closeTo(0.05, 1e-9));
      expect(c.single.score, greaterThanOrEqualTo(p.warnAt));
      expect(c.single.severity, ShiftSeverity.warning);
    });

    test('moved 8 px or more: floor saturates at consistencyMoveScore', () {
      for (final d in [8.0, 24.0, -96.0]) {
        final r = _cmp(fr(0, [_av(_avatar)]), fr(0, [_av(_dx(_avatar, d))]));
        // 96 px: area term 136x40/320000 x 96/800 x 1.5 = .0031, under .1.
        expect(_charged(r).single.score, closeTo(0.1, 1e-9), reason: '$d px');
      }
    });

    test('the control-only knobs (controlMoveScore/RefPx) are not used', () {
      final a = fr(0, [_av(_avatar)]), b = fr(0, [_av(_dx(_avatar, 4))]);
      final q = p.copyWith(controlMoveScore: 0.9, controlMoveRefPx: 1);
      expect(_charged(_cmp(a, b, p: q)).single.score,
          closeTo(_charged(_cmp(a, b)).single.score, 1e-12));
    });
  });

  test('paragraph moved 12 px: drift floor applies to every role', () {
    // area term: union 200x42 = 8400; 8400/320000 x 12/800 x 2 = 7.875e-4.
    // floor: .1 x min(1, 12/8) = .1 (wins).
    final r = _cmp(
        fr(0, [el('shared:title', _title, role: ElementRole.paragraph)]),
        fr(0, [
          el('shared:title', const ShiftRect(16, 24, 200, 30),
              role: ElementRole.paragraph)
        ]));
    final c = _charged(r).single;
    expect(c.rule, 'consistency');
    expect(c.score, closeTo(0.1, 1e-9));
  });

  test('a placeholder gets no drift floor: base formula only', () {
    // 4 px: union 404x200 = 80800; 80800/320000 x 4/800 = .00126 x
    // roleWeight (1 when unmapped) - far under the .05 a floor would give.
    final r = _cmp(
        fr(0, [el('skeleton:rings', _card, role: ElementRole.placeholder)]),
        fr(0, [
          el('skeleton:rings', _dx(_card, 4), role: ElementRole.placeholder)
        ]));
    final scores = r.findings.map((f) => f.score);
    expect(scores.every((v) => v < 0.01), isTrue, reason: '$scores');
  });

  group('tolerance (consistencyTolerancePx = 1)', () {
    test('1 px drift is free', () {
      final r = _cmp(fr(0, [_av(_avatar), el('body', _content)]),
          fr(0, [_av(_dx(_avatar, 1)), el('body', _dx(_content, -1))]));
      expect(r.findings, isEmpty);
    });
    test('1 px size change is free', () {
      final r = _cmp(fr(0, [el('body', _content)]),
          fr(0, [el('body', const ShiftRect(16, 100, 368, 101))]));
      expect(r.findings, isEmpty);
    });
    test('2 px drift is not', () {
      final r = _cmp(fr(0, [_av(_avatar)]), fr(0, [_av(_dx(_avatar, 2))]));
      expect(_charged(r), hasLength(1));
    });
  });

  group('size change', () {
    test('same position, height 100 -> 140: at least the full floor', () {
      final r = _cmp(fr(0, [el('shared:content-top', _content)]),
          fr(0, [el('shared:content-top', const ShiftRect(16, 100, 368, 140))]));
      final c = _charged(r).single;
      expect(c.elementId, 'shared:content-top');
      // size term |36800 - 51520| / 320000 = .046; resize floor
      // .1 x min(1, 40/8) = .1 (the centre moving 20 px gives the same .1).
      expect(c.score, greaterThanOrEqualTo(0.1 - 1e-9));
    });

    test('height 100 -> 104: resize floor .1 x 4/8 = .05', () {
      // Centre moves 2 px (floor .025); resize floor d = max(0, 4) = 4 gives
      // .05; take the larger. Base: 368x104/320000 x 2/800 + 368x4/320000
      // = .0049, smaller.
      final r = _cmp(fr(0, [el('body', _content)]),
          fr(0, [el('body', const ShiftRect(16, 100, 368, 104))]));
      expect(_charged(r).single.score, closeTo(0.05, 1e-9));
    });
  });

  group('present in one layout only', () {
    // 368 x 200 = 73600; 73600 / 320000 x 1.0 = .23.
    const want = 73600 / 320000;

    test('in A only: charged by area/vpArea x consistencyWeight', () {
      final r = _cmp(fr(0, [_av(_avatar), el('card:first-week', _card)]),
          fr(0, [_av(_avatar)]));
      final c = _charged(r).single;
      expect(c.rule, 'consistency');
      expect(c.elementId, 'card:first-week');
      expect(c.score, closeTo(want, 1e-12));
    });

    test('in B only: charged the same', () {
      final r = _cmp(fr(0, [_av(_avatar)]),
          fr(0, [_av(_avatar), el('card:rings', _card)]));
      final c = _charged(r).single;
      expect(c.elementId, 'card:rings');
      expect(c.score, closeTo(want, 1e-12));
    });

    test('filtered out by `only`: not charged', () {
      final r = _cmp(fr(0, [_av(_avatar), el('card:first-week', _card)]),
          fr(0, [_av(_avatar), el('card:rings', _card)]),
          only: (id) => id.startsWith('shared:'));
      expect(r.findings, isEmpty);
    });
  });

  test("only: (id) => id.startsWith('shared:') ignores every other id", () {
    final a = fr(0, [
      _av(_avatar),
      el('body', _content),
      el('chip', const ShiftRect(16, 420, 80, 32), role: ElementRole.control),
      el('card:a', _card),
    ]);
    final b = fr(0, [
      _av(_avatar),
      el('body', _dx(_content, 200)),
      el('chip', const ShiftRect(200, 600, 80, 32), role: ElementRole.control),
      el('card:b', _card),
    ]);
    expect(_charged(_cmp(a, b)), isNotEmpty, reason: 'unfiltered: charged');
    final r = _cmp(a, b, only: (id) => id.startsWith('shared:'));
    expect(r.findings, isEmpty);

    // And a shared id that does move is still charged under the filter.
    final moved = fr(0, [_av(_dx(_avatar, 24)), ...b.elements.skip(1)]);
    final m = _cmp(a, moved, only: (id) => id.startsWith('shared:'));
    expect(m.findings.map((f) => f.elementId), ['shared:avatar']);
  });

  test('no latency or curve: frame times do not change the score', () {
    List<double> scores(int atA, int atB) => _cmp(
            fr(atA, [_av(_avatar), el('card:x', _card)]),
            fr(atB, [_av(_dx(_avatar, 8)), el('body', _content)]))
        .findings
        .map((f) => f.score)
        .toList();
    final base = scores(0, 0);
    expect(base, isNotEmpty);
    expect(scores(0, 16), base);
    expect(scores(0, 300000), base);
    expect(scores(5000, 100), base);
  });

  group('policy knobs', () {
    test('presets', () {
      expect(ShiftPolicy.standard.consistencyWeight, 1.0);
      expect(ShiftPolicy.strict.consistencyWeight, 1.5);
      expect(ShiftPolicy.lenient.consistencyWeight, 0.6);
      expect(ShiftPolicy.standard.consistencyTolerancePx, 1.0);
      expect(ShiftPolicy.standard.consistencyMoveScore, 0.1);
      expect(ShiftPolicy.strict.consistencyMoveScore, 0.15);
      expect(ShiftPolicy.lenient.consistencyMoveScore, 0.06);
      expect(ShiftPolicy.standard.consistencyRefPx, 8);
      expect(ShiftPolicy.strict.consistencyRefPx, 6);
      expect(ShiftPolicy.lenient.consistencyRefPx, 12);
    });

    test('copyWith round-trips', () {
      final q = ShiftPolicy.standard.copyWith(
          consistencyWeight: 2.0,
          consistencyTolerancePx: 3.0,
          consistencyMoveScore: 0.2,
          consistencyRefPx: 16);
      expect(q.consistencyWeight, 2.0);
      expect(q.consistencyTolerancePx, 3.0);
      expect(q.consistencyMoveScore, 0.2);
      expect(q.consistencyRefPx, 16);
      final same = ShiftPolicy.standard.copyWith();
      expect(same.consistencyWeight, ShiftPolicy.standard.consistencyWeight);
      expect(same.consistencyTolerancePx,
          ShiftPolicy.standard.consistencyTolerancePx);
      expect(same.consistencyMoveScore,
          ShiftPolicy.standard.consistencyMoveScore);
      expect(same.consistencyRefPx, ShiftPolicy.standard.consistencyRefPx);
    });

    test('consistencyWeight scales a one-sided finding linearly', () {
      // One-sided elements have no floor, so base is the whole score.
      Frame a() => fr(0, [el('card:x', _card)]);
      Frame b() => fr(0, const []);
      final base = _charged(_cmp(a(), b())).single.score;
      final doubled = _charged(_cmp(a(), b(),
              p: p.copyWith(consistencyWeight: p.consistencyWeight * 2)))
          .single
          .score;
      expect(base, closeTo(73600 / 320000, 1e-12));
      expect(doubled, closeTo(base * 2, 1e-12));
    });

    test('the drift floor ignores consistencyWeight', () {
      final a = fr(0, [_av(_avatar)]), b = fr(0, [_av(_dx(_avatar, 4))]);
      expect(
          _charged(_cmp(a, b, p: p.copyWith(consistencyWeight: 3)))
              .single
              .score,
          closeTo(0.05, 1e-9));
    });

    test('consistencyMoveScore and consistencyRefPx shape the floor', () {
      final a = fr(0, [_av(_avatar)]), b = fr(0, [_av(_dx(_avatar, 4))]);
      // .2 x min(1, 4/16) = .05; .2 x min(1, 4/4) = .2
      expect(
          _charged(_cmp(a, b,
                  p: p.copyWith(consistencyMoveScore: 0.2, consistencyRefPx: 16)))
              .single
              .score,
          closeTo(0.05, 1e-9));
      expect(
          _charged(_cmp(a, b,
                  p: p.copyWith(consistencyMoveScore: 0.2, consistencyRefPx: 4)))
              .single
              .score,
          closeTo(0.2, 1e-9));
    });

    test('consistencyTolerancePx widens the free band', () {
      final a = fr(0, [_av(_avatar)]), b = fr(0, [_av(_dx(_avatar, 2))]);
      expect(_charged(_cmp(a, b)), isNotEmpty);
      expect(_cmp(a, b, p: p.copyWith(consistencyTolerancePx: 2)).findings,
          isEmpty);
    });
  });

  test('pure: same input, same report', () {
    final a = fr(0, [_av(_avatar), el('card:x', _card)]);
    final b = fr(0, [_av(_dx(_avatar, 8)), el('body', _content)]);
    expect(sig(_cmp(a, b)), sig(_cmp(a, b)));
  });
}
