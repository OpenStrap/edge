// Hand-computed examples, one group per scoring step in docs/LAYOUT_SHIFT.md.
//
// Viewport is 100 x 100 (area 10000, longest side 100) unless stated.
// Reference mover M: 50x50 at (0,0) -> (0,20), role other:
//   union = 50x70 = 3500 -> 0.35 of viewport; distance 20/100 = 0.2
//   base = 0.35 * 0.2 = 0.07
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

import '../support/shift_builders.dart' hide total;

/// Shift arithmetic only. The load time finding has its own tests in
/// load_time_test.dart, so these scenarios filter it out.
double total(Scenario s, [ShiftPolicy p = ShiftPolicy.standard]) => score(s, p)
    .findings
    .where((f) => f.rule != 'load')
    .fold(0.0, (a, f) => a + f.score);

const _a = ShiftRect(0, 0, 50, 50);
const _b = ShiftRect(0, 20, 50, 50);

/// M moves at [t] ms after an interaction at 1000.
Scenario _afterInteraction(int t,
        {ElementRole role = ElementRole.other,
        List<AnimationSpan> animations = const [],
        List<Interaction>? interactions}) =>
    sc([
      fr(1000, [el('x', _a, role: role)]),
      fr(1000 + t, [el('x', _b, role: role)]),
    ],
        interactions: interactions ?? const [Interaction(1000, 'src')],
        animations: animations);

Scenario _mover({ElementRole role = ElementRole.other}) => sc([
      fr(0, [el('x', _a, role: role)]),
      fr(1000, [el('x', _b, role: role)]),
    ]);

void main() {
  group('geometry', () {
    test('area', () => expect(_a.area, closeTo(2500, 1e-9))); // 50*50
    test('center', () {
      expect(_a.center.x, closeTo(25, 1e-9));
      expect(_a.center.y, closeTo(25, 1e-9));
    });
    test('distanceTo is centre to centre', () {
      // (25,25) -> (25,45) = 20
      expect(_a.distanceTo(_b), closeTo(20, 1e-9));
    });
    test('union is the bounding box', () {
      final u = _a.union(_b); // (0,0)-(50,70)
      expect([u.left, u.top, u.width, u.height], [0, 0, 50, 70]);
    });
    test('intersect is the overlap, null when apart', () {
      final i = _a.intersect(_b)!; // (0,20)-(50,50) = 50x30
      expect([i.left, i.top, i.width, i.height], [0, 20, 50, 30]);
      expect(_a.intersect(const ShiftRect(60, 60, 5, 5)), isNull);
    });
  });

  group('step 1: base impact', () {
    test('move: 0.35 * 0.2 = 0.07', () {
      expect(total(_mover()), closeTo(0.07, 1e-9));
    });
    test('resize: union 50x70 = 0.35, centre moves 10 => 0.1; 0.035', () {
      final s = sc([
        fr(0, [el('x', const ShiftRect(0, 0, 50, 50))]),
        fr(1000, [el('x', const ShiftRect(0, 0, 50, 70))]),
      ]);
      expect(total(s), closeTo(0.035, 1e-9));
    });
    test('colour change alone: 0.25 * (102/255=0.4) * 0.5 = 0.05', () {
      final s = sc([
        fr(0, [el('x', _a, color: 0xFF000000)]),
        fr(1000, [el('x', _a, color: 0xFF666666)]),
      ]);
      expect(total(s), closeTo(0.05, 1e-9));
    });
    test('move + colour: 0.07 + 0.05 = 0.12', () {
      final s = sc([
        fr(0, [el('x', _a, color: 0xFF000000)]),
        fr(1000, [el('x', _b, color: 0xFF666666)]),
      ]);
      expect(total(s), closeTo(0.12, 1e-9));
    });
    test('an element that does not change scores nothing', () {
      final s = sc([
        fr(0, [el('x', _a)]),
        fr(1000, [el('x', _a)]),
      ]);
      expect(total(s), 0);
      expect(score(s, ShiftPolicy.standard).findings, isEmpty);
    });
    test('a shift is one finding for that element and frame', () {
      final f = score(_mover(), ShiftPolicy.standard).findings;
      expect(f, hasLength(1));
      expect(f.single.elementId, 'x');
      expect(f.single.atMs, 1000);
      expect(f.single.score, closeTo(0.07, 1e-9));
    });
  });

  group('step 2: role weights (base 0.07, no interaction)', () {
    const cases = {
      ElementRole.paragraph: 0.14, // *2
      ElementRole.input: 0.21, // *3
      ElementRole.control: 0.105, // *1.5
      ElementRole.media: 0.07, // *1
      ElementRole.decorative: 0.035, // *0.5
      ElementRole.other: 0.07, // *1
    };
    cases.forEach((role, expected) {
      test('${role.name} => $expected', () {
        expect(total(_mover(role: role)), closeTo(expected, 1e-9));
      });
    });
    test('paragraph and input cost more than decorative', () {
      expect(total(_mover(role: ElementRole.paragraph)),
          greaterThan(total(_mover(role: ElementRole.decorative))));
      expect(total(_mover(role: ElementRole.input)),
          greaterThan(total(_mover(role: ElementRole.decorative))));
    });
  });

  group('step 3: latency curve (base 0.07, interaction at 1000)', () {
    const cases = {
      50: 0.0, // before first point
      100: 0.0, // curve 0
      150: 0.0035, // curve 0.05 (halfway 0..0.1)
      200: 0.007, // curve 0.1
      300: 0.021, // curve 0.3
      350: 0.028, // curve 0.4
      400: 0.035, // curve 0.5
      500: 0.07, // curve 1
    };
    cases.forEach((t, expected) {
      test('t=$t ms => $expected', () {
        expect(total(_afterInteraction(t)), closeTo(expected, 1e-9));
      });
    });
    test('beyond the window the out-of-window cost (1.0) applies', () {
      expect(total(_afterInteraction(600)), closeTo(0.07, 1e-9));
    });
    test('out-of-window cost is a multiplier: 2.0 => 0.14', () {
      final p = ShiftPolicy.standard.copyWith(outOfWindowCost: 2.0);
      expect(total(_afterInteraction(600), p), closeTo(0.14, 1e-9));
    });
    test('no prior interaction counts as out of window (0.07)', () {
      // interaction is AFTER the shift
      final s = _afterInteraction(300, interactions: const [
        Interaction(5000, 'src'),
      ]);
      expect(total(s), closeTo(0.07, 1e-9));
    });
    test('the latest interaction before the shift is the reference', () {
      final s = _afterInteraction(300, interactions: const [
        Interaction(0, 'src'), // t would be 1300: out of window
        Interaction(1000, 'src'), // t = 300 => 0.3
      ]);
      expect(total(s), closeTo(0.021, 1e-9));
    });
  });

  group('animation grace', () {
    test('animation starting 50 ms after interaction: t=300 costs curve(200)', () {
      // 0.07 * 0.1 = 0.007
      final s = _afterInteraction(300, animations: const [
        AnimationSpan(1050, 1350, elementId: 'x'),
      ]);
      expect(total(s), closeTo(0.007, 1e-9));
    });
    test('animation starting exactly at the window edge (100) still earns it', () {
      final s = _afterInteraction(300, animations: const [
        AnimationSpan(1100, 1400, elementId: 'x'),
      ]);
      expect(total(s), closeTo(0.007, 1e-9));
    });
    test('animation starting 150 ms after interaction earns nothing: 0.021', () {
      final s = _afterInteraction(300, animations: const [
        AnimationSpan(1150, 1450, elementId: 'x'),
      ]);
      expect(total(s), closeTo(0.021, 1e-9));
    });
    test('animationGraceMs 200: t=300 -> curve(100)=0 => 0', () {
      final p = ShiftPolicy.standard.copyWith(animationGraceMs: 200);
      final s = _afterInteraction(300, animations: const [
        AnimationSpan(1050, 1350, elementId: 'x'),
      ]);
      expect(total(s, p), closeTo(0.0, 1e-9));
    });
  });

  group('step 4: chain discount (t=300 => 0.07*0.3 = 0.021)', () {
    // Interaction at 1000. Spans are absolute ms.
    List<AnimationSpan> chain(List<List<int>> se) => [
          for (final p in se)
            AnimationSpan(1000 + p[0], 1000 + p[1],
                elementId: 'x', chainId: 'c'),
        ];

    test('qualifying chain (150..650, 250 ms cycles) halves it: 0.0105', () {
      final s = _afterInteraction(300, animations: chain([
        [150, 400],
        [400, 650],
      ]));
      expect(total(s), closeTo(0.0105, 1e-9));
    });
    test('a 600 ms span disqualifies the chain: 0.021', () {
      final s = _afterInteraction(300, animations: chain([
        [150, 400],
        [400, 1000],
      ]));
      expect(total(s), closeTo(0.021, 1e-9));
    });
    test('a chain ending at 2500 after the interaction does not qualify', () {
      final s = _afterInteraction(300, animations: chain([
        [150, 500],
        [500, 900],
        [900, 1300],
        [1300, 1700],
        [1700, 2100],
        [2100, 2500],
      ]));
      expect(total(s), closeTo(0.021, 1e-9));
    });
    test('chainDiscount 0.25 => 0.00525', () {
      final p = ShiftPolicy.standard.copyWith(chainDiscount: 0.25);
      final s = _afterInteraction(300, animations: chain([
        [150, 400],
        [400, 650],
      ]));
      expect(total(s, p), closeTo(0.00525, 1e-9));
    });
  });

  group('step 5a: intent target pairing', () {
    // text 40x40 (60,0)->(60,10): union 40x50=2000 => 0.2; dist 10/100 => 0.1;
    // base 0.02. t=300 => *0.3 = 0.006.
    // copy button 10x10 at (63,20), centre (68,25); text centre before
    // (80,20), after (80,30): both 13 from the button (5-12-13), so the pair
    // distance is 0.13 whichever frame the scorer measures.
    const copy = ShiftRect(63, 20, 10, 10);
    Scenario pair({String? intent}) => sc([
          fr(1000, [
            el('copy', copy),
            el('text', const ShiftRect(60, 0, 40, 40)),
          ]),
          fr(1300, [
            el('copy', copy),
            el('text', const ShiftRect(60, 10, 40, 40)),
          ]),
        ], interactions: [
          Interaction(1000, 'copy', intentTargetId: intent),
        ]);

    test('non-paired element pays full: 0.006', () {
      expect(total(pair()), closeTo(0.006, 1e-9));
    });
    test('another element named as intent target leaves text unpaired', () {
      expect(total(pair(intent: 'other')), closeTo(0.006, 1e-9));
    });
    test('intent target: 0.006 * 0.5 * (1 + 0.5*0.13) = 0.003195', () {
      expect(total(pair(intent: 'text')), closeTo(0.003195, 1e-9));
    });
    test('pairedDiscount 0.25 => 0.006*0.25*1.065 = 0.0015975', () {
      final p = ShiftPolicy.standard.copyWith(pairedDiscount: 0.25);
      expect(total(pair(intent: 'text'), p), closeTo(0.0015975, 1e-9));
    });
    test('pairDistanceWeight 1.0 => 0.006*0.5*1.13 = 0.00339', () {
      final p = ShiftPolicy.standard.copyWith(pairDistanceWeight: 1.0);
      expect(total(pair(intent: 'text'), p), closeTo(0.00339, 1e-9));
    });
    test('pairDistanceWeight 0 => plain discount 0.003', () {
      final p = ShiftPolicy.standard.copyWith(pairDistanceWeight: 0);
      expect(total(pair(intent: 'text'), p), closeTo(0.003, 1e-9));
    });
  });

  group('step 5b: focus-history distance', () {
    // x 40x40 (0,0)->(0,30): union 40x70=2800 => 0.28; dist 30/100 => 0.3;
    // base 0.084, no interaction (cost 1). Centres (20,20)->(20,50).
    // far focus element centre (56,35): 39 from both (15-36-39) => 0.39.
    // near focus element centre (28,35): 17 from both (8-15-17) => 0.17.
    const farF = ShiftRect(51, 30, 10, 10);
    const nearF = ShiftRect(23, 30, 10, 10);
    Scenario withFocus(ShiftRect f, int focusAt, int frameAt) => sc([
          fr(frameAt - 1000, [
            el('x', const ShiftRect(0, 0, 40, 40)),
            el('f', f),
          ]),
          fr(frameAt, [
            el('x', const ShiftRect(0, 30, 40, 40)),
            el('f', f),
          ]),
        ], focus: [
          FocusEvent(focusAt, 'f'),
        ]);

    test('no focus history: 0.084', () {
      final s = sc([
        fr(1000, [el('x', const ShiftRect(0, 0, 40, 40))]),
        fr(2000, [el('x', const ShiftRect(0, 30, 40, 40))]),
      ]);
      expect(total(s), closeTo(0.084, 1e-9));
    });
    test('fresh far focus: 0.084 * (1 + 0.39) = 0.11676', () {
      expect(total(withFocus(farF, 2000, 2000)), closeTo(0.11676, 1e-9));
    });
    test('focus one half-life old: 0.084 * (1 + 0.195) = 0.10038', () {
      expect(total(withFocus(farF, 0, 2000)), closeTo(0.10038, 1e-9));
    });
    test('focus two half-lives old: 0.084 * (1 + 0.0975) = 0.09219', () {
      expect(total(withFocus(farF, 0, 4000)), closeTo(0.09219, 1e-9));
    });
    test('near focus costs less than far: 0.084 * 1.17 = 0.09828', () {
      final near = total(withFocus(nearF, 2000, 2000));
      expect(near, closeTo(0.09828, 1e-9));
      expect(total(withFocus(farF, 2000, 2000)), greaterThan(near));
    });
    test('focusDistanceWeight 2 => 0.084 * 1.78 = 0.14952', () {
      final p = ShiftPolicy.standard.copyWith(focusDistanceWeight: 2.0);
      expect(total(withFocus(farF, 2000, 2000), p), closeTo(0.14952, 1e-9));
    });
    test('focusHalfLifeMs 1000: age 2000 => w 0.25 => 0.09219', () {
      final p = ShiftPolicy.standard.copyWith(focusHalfLifeMs: 1000);
      expect(total(withFocus(farF, 0, 2000), p), closeTo(0.09219, 1e-9));
    });
  });

  group('step 5c: focused element', () {
    test('focused control shifted: 0.07 * 1.5 * 2 = 0.21', () {
      final s = sc([
        fr(0, [el('c', _a, role: ElementRole.control, focusable: true, focused: true)]),
        fr(1000, [el('c', _b, role: ElementRole.control, focusable: true, focused: true)]),
      ]);
      expect(total(s), closeTo(0.21, 1e-9));
    });
    test('same control unfocused: 0.105', () {
      final s = sc([
        fr(0, [el('c', _a, role: ElementRole.control, focusable: true)]),
        fr(1000, [el('c', _b, role: ElementRole.control, focusable: true)]),
      ]);
      expect(total(s), closeTo(0.105, 1e-9));
    });
    test('focusedMultiplier 3 => 0.07 * 1.5 * 3 = 0.315', () {
      final p = ShiftPolicy.standard.copyWith(focusedMultiplier: 3.0);
      final s = sc([
        fr(0, [el('c', _a, role: ElementRole.control, focusable: true, focused: true)]),
        fr(1000, [el('c', _b, role: ElementRole.control, focusable: true, focused: true)]),
      ]);
      expect(total(s, p), closeTo(0.315, 1e-9));
    });
  });

  group('coverage of focusable elements', () {
    // btn 20x20 at (0,0), area 400. Overlay 20x10 covers 200 => 0.5.
    const btn = ShiftRect(0, 0, 20, 20);
    Scenario cover(
            {bool focused = false,
            ShiftRect overlay = const ShiftRect(0, 0, 20, 10),
            int at = 1000,
            List<Interaction> ix = const []}) =>
        sc([
          fr(0, [el('btn', btn, focusable: true, focused: focused)]),
          fr(at, [
            el('btn', btn, focusable: true, focused: focused),
            el('overlay', overlay),
          ]),
        ], interactions: ix);

    test('overlay covering half: 1.0 * 0.5 * 1 = 0.5', () {
      expect(total(cover()), closeTo(0.5, 1e-9));
    });
    test('covering a focused element doubles it: 1.0', () {
      expect(total(cover(focused: true)), closeTo(1.0, 1e-9));
    });
    test('below the minimum fraction (80/400 = 0.2) costs nothing', () {
      expect(total(cover(overlay: const ShiftRect(0, 0, 20, 4))), 0);
    });
    test('cover is scaled by latency: 300 ms => 0.5 * 0.3 = 0.15', () {
      final s = cover(at: 1300, ix: const [Interaction(1000, 'src')]);
      expect(total(s), closeTo(0.15, 1e-9));
    });
    test('overlay growing over a button: 0.5 cover + 0.0008 own resize', () {
      // overlay 20x2 -> 20x10: union 200 => 0.02; centre moves 4 => 0.04.
      final s = sc([
        fr(0, [
          el('btn', btn, focusable: true),
          el('overlay', const ShiftRect(0, 0, 20, 2)),
        ]),
        fr(1000, [
          el('btn', btn, focusable: true),
          el('overlay', const ShiftRect(0, 0, 20, 10)),
        ]),
      ]);
      expect(total(s), closeTo(0.5008, 1e-9));
    });
    test('coverCost 2 => 1.0; coverMinFraction 0.6 => 0', () {
      expect(total(cover(), ShiftPolicy.standard.copyWith(coverCost: 2.0)),
          closeTo(1.0, 1e-9));
      expect(total(cover(), ShiftPolicy.standard.copyWith(coverMinFraction: 0.6)), 0);
    });
  });

  group('step 6a: dense controls', () {
    // A 20x20 at (0,0); B 20x20 at (24,0): gap 4 < 8.
    // B 0,0 -> 0,10 : union 20x30=600 => 0.06; dist 0.1 => 0.006; *1.5 = 0.009.
    const ctl = ElementRole.control;
    Scenario pairShift(double gapX, double aDy, double bDy) => sc([
          fr(0, [
            el('a', const ShiftRect(0, 0, 20, 20), role: ctl),
            el('b', ShiftRect(20 + gapX, 0, 20, 20), role: ctl),
          ]),
          fr(1000, [
            el('a', ShiftRect(0, aDy, 20, 20), role: ctl),
            el('b', ShiftRect(20 + gapX, bDy, 20, 20), role: ctl),
          ]),
        ]);

    test('gap 4, one moves: 0.009 * 3 = 0.027', () {
      expect(total(pairShift(4, 0, 10)), closeTo(0.027, 1e-9));
    });
    test('gap 12 (>= 8): no dense penalty, 0.009', () {
      expect(total(pairShift(12, 0, 10)), closeTo(0.009, 1e-9));
    });
    test('gap 4 but moving together: 0.009 + 0.009 = 0.018', () {
      expect(total(pairShift(4, 10, 10)), closeTo(0.018, 1e-9));
    });
    test('gap 4, moving apart (10 and 20): both tripled', () {
      // a: 0.06*0.1*1.5*3 = 0.027 ; b: union 20x40=800 => 0.08, dist 0.2
      // => 0.016*1.5*3 = 0.072 ; total 0.099
      expect(total(pairShift(4, 10, 20)), closeTo(0.099, 1e-9));
    });
    test('denseMultiplier 5 => 0.045; denseGapPx 2 => 0.009', () {
      expect(
          total(pairShift(4, 0, 10),
              ShiftPolicy.standard.copyWith(denseMultiplier: 5.0)),
          closeTo(0.045, 1e-9));
      expect(
          total(pairShift(4, 0, 10),
              ShiftPolicy.standard.copyWith(denseGapPx: 2.0)),
          closeTo(0.009, 1e-9));
    });
  });

  group('step 6b: disabled shield', () {
    // Focused control: 0.07 * 1.5 * 2 = 0.21 undiscounted.
    ElementSnapshot c(ShiftRect r, bool enabled) => el('c', r,
        role: ElementRole.control,
        focusable: true,
        focused: true,
        enabled: enabled);
    const b0 = _a;
    const b1 = _b;

    test('disabled 500 ms around the shift: 0.21 * 0.8 = 0.168', () {
      final s = sc([
        fr(1000, [c(b0, true)]),
        fr(1500, [c(b0, false)]),
        fr(1750, [c(b1, false)]),
        fr(2000, [c(b1, true)]),
      ]);
      expect(total(s), closeTo(0.168, 1e-9));
    });
    test('disabled only 200 ms: no discount, 0.21', () {
      final s = sc([
        fr(1000, [c(b0, true)]),
        fr(1500, [c(b0, false)]),
        fr(1600, [c(b1, false)]),
        fr(1700, [c(b1, true)]),
      ]);
      expect(total(s), closeTo(0.21, 1e-9));
    });
    test('disabledDiscount 0.5 => 0.105', () {
      final s = sc([
        fr(1000, [c(b0, true)]),
        fr(1500, [c(b0, false)]),
        fr(1750, [c(b1, false)]),
        fr(2000, [c(b1, true)]),
      ]);
      expect(
          total(s, ShiftPolicy.standard.copyWith(disabledDiscount: 0.5)),
          closeTo(0.105, 1e-9));
    });
  });

  group('severity thresholds (warn 0.05, error 0.25)', () {
    ShiftSeverity sev(Scenario s, [ShiftPolicy p = ShiftPolicy.standard]) =>
        score(s, p).findings.single.severity;

    test('0.035 is none', () {
      expect(sev(_mover(role: ElementRole.decorative)), ShiftSeverity.none);
    });
    test('0.07 is a warning', () {
      expect(sev(_mover()), ShiftSeverity.warning);
    });
    test('0.5 (cover of a half-covered button) is an error', () {
      final s = sc([
        fr(0, [el('btn', const ShiftRect(0, 0, 20, 20), focusable: true)]),
        fr(1000, [
          el('btn', const ShiftRect(0, 0, 20, 20), focusable: true),
          el('o', const ShiftRect(0, 0, 20, 10)),
        ]),
      ]);
      final r = score(s, ShiftPolicy.standard);
      expect(r.errors, hasLength(1));
      expect(r.warnings, isEmpty);
    });
    test('report.warnings / errors filter by severity', () {
      final r = score(_mover(), ShiftPolicy.standard);
      expect(r.warnings, hasLength(1));
      expect(r.errors, isEmpty);
    });
    test('errorAt 0.06 turns 0.07 into an error; warnAt 0.1 into none', () {
      expect(sev(_mover(), ShiftPolicy.standard.copyWith(errorAt: 0.06)),
          ShiftSeverity.error);
      expect(sev(_mover(), ShiftPolicy.standard.copyWith(warnAt: 0.1)),
          ShiftSeverity.none);
    });
  });

  group('policy tunability', () {
    test('latencyCurve replaced: (100,.2)(200,.4) at t=150 => 0.07*0.3', () {
      final p = ShiftPolicy.standard.copyWith(latencyCurve: const [
        LatencyPoint(100, 0.2),
        LatencyPoint(200, 0.4),
      ]);
      expect(total(_afterInteraction(150), p), closeTo(0.021, 1e-9));
    });
    test('roleWeight paragraph 4 => 0.28', () {
      final p = ShiftPolicy.standard.copyWith(roleWeight: const {
        ElementRole.paragraph: 4,
        ElementRole.other: 1,
      });
      expect(total(_mover(role: ElementRole.paragraph), p), closeTo(0.28, 1e-9));
    });
    test('colorWeight 1.0 => 0.25 * 0.4 * 1 = 0.1', () {
      final s = sc([
        fr(0, [el('x', _a, color: 0xFF000000)]),
        fr(1000, [el('x', _a, color: 0xFF666666)]),
      ]);
      expect(total(s, ShiftPolicy.standard.copyWith(colorWeight: 1.0)),
          closeTo(0.1, 1e-9));
    });
    test('interactionWindowMs 300: t=400 is out of window => 0.07', () {
      final p = ShiftPolicy.standard.copyWith(interactionWindowMs: 300);
      expect(total(_afterInteraction(400), p), closeTo(0.07, 1e-9));
    });
    test('the standard policy is the documented one', () {
      const p = ShiftPolicy.standard;
      expect(p.latencyCurve.map((e) => [e.ms, e.cost]).toList(), [
        [100, 0],
        [200, 0.1],
        [300, 0.3],
        [400, 0.5],
        [500, 1],
      ]);
      expect([p.warnAt, p.errorAt], [0.05, 0.25]);
      expect(p.latencyAt(150), closeTo(0.05, 1e-9));
    });
    test('strict >= standard >= lenient on the same scenario (t=300)', () {
      // strict curve(300)=0.5, standard 0.3, lenient 0.15 on base 0.07
      final s = _afterInteraction(300);
      final st = total(s, ShiftPolicy.strict);
      final sd = total(s, ShiftPolicy.standard);
      final le = total(s, ShiftPolicy.lenient);
      expect(st, closeTo(0.035, 1e-9));
      expect(sd, closeTo(0.021, 1e-9));
      expect(le, closeTo(0.0105, 1e-9));
      expect(st, greaterThanOrEqualTo(sd));
      expect(sd, greaterThanOrEqualTo(le));
    });
  });
}
