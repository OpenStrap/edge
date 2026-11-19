// Load time penalty: settle time per interaction, scored on loadCurve.
// Examples are hand-computed from docs/LAYOUT_SHIFT.md "Load time".
//
// Standard policy: loadCurve (100,0) (400,.1) (1000,.3) (2000,.6) (4000,1),
// loadWeight .25, warnAt .05, errorAt .25.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

import '../support/shift_builders.dart';

const _a = ShiftRect(0, 0, 10, 10);
const _b = ShiftRect(0, 0, 10, 20);

List<ShiftFinding> _load(Scenario s, [ShiftPolicy p = ShiftPolicy.standard]) =>
    score(s, p).findings.where((f) => f.rule == 'load').toList();

/// Interaction at 1000; x changes at 1000+[settle], then holds still for
/// another 100 ms so the screen counts as settled.
Scenario _settling(int settle,
        {List<AnimationSpan> animations = const [], bool settled = true}) =>
    sc([
      fr(1000, [el('x', _a)]),
      fr(1000 + settle, [el('x', _b)]),
      if (settled) fr(1000 + settle + 100, [el('x', _b)]),
    ],
        interactions: const [Interaction(1000, 'src')],
        animations: animations);

double _one(Scenario s, [ShiftPolicy p = ShiftPolicy.standard]) {
  final l = _load(s, p);
  expect(l, hasLength(1));
  return l.single.score;
}

void main() {
  group('curve', () {
    test('defaults', () {
      final p = ShiftPolicy.standard;
      expect(p.loadWeight, 0.25);
      expect(p.loadCurve.map((e) => '${e.ms}:${e.cost}').join(' '),
          '100:0.0 400:0.1 1000:0.3 2000:0.6 4000:1.0');
    });
    test('0 before the first point and at it', () {
      expect(ShiftPolicy.standard.loadAt(50), 0);
      expect(ShiftPolicy.standard.loadAt(100), 0);
    });
    test('interpolates linearly', () {
      expect(ShiftPolicy.standard.loadAt(250), closeTo(0.05, 1e-9)); // half of 0..0.1
      expect(ShiftPolicy.standard.loadAt(700), closeTo(0.2, 1e-9)); // half of .1..3
      expect(ShiftPolicy.standard.loadAt(3000), closeTo(0.8, 1e-9));
    });
    test('1 after the last point', () {
      expect(ShiftPolicy.standard.loadAt(4000), 1);
      expect(ShiftPolicy.standard.loadAt(60000), 1);
    });
  });

  group('settle time', () {
    test('score = loadWeight x curve(settle); rule, element and time', () {
      final f = _load(_settling(1000)).single;
      expect(f.rule, 'load');
      expect(f.elementId, 'src');
      expect(f.atMs, 2000); // interaction + settle
      expect(f.score, closeTo(0.075, 1e-9)); // .25 * .3
    });
    test('severity thresholds', () {
      expect(_load(_settling(400)).single.severity, ShiftSeverity.none); // .025
      expect(_load(_settling(1000)).single.severity, ShiftSeverity.warning); // .075
      expect(_load(_settling(2000)).single.severity, ShiftSeverity.warning); // .15
      expect(_load(_settling(4000)).single.severity, ShiftSeverity.error); // .25
    });
    test('immediate response costs nothing', () {
      expect(_one(_settling(80)), 0);
    });
    test('the finding is part of the total', () {
      final r = score(_settling(1000), ShiftPolicy.standard);
      final shifts = r.findings.where((f) => f.rule != 'load');
      expect(r.total,
          closeTo(shifts.fold(0.0, (a, f) => a + f.score) + 0.075, 1e-9));
    });
    test('no interactions => no load findings', () {
      final s = sc([
        fr(1000, [el('x', _a)]),
        fr(3000, [el('x', _b)]),
        fr(3100, [el('x', _b)]),
      ]);
      expect(_load(s), isEmpty);
    });
    test('an interaction that changes nothing has no load', () {
      final s = sc([
        fr(1000, [el('x', _a)]),
        fr(2000, [el('x', _a)]),
      ], interactions: const [Interaction(1000, 'src')]);
      expect(_load(s), isEmpty);
    });
    test('two interactions each get their own settle', () {
      final s = sc([
        fr(1000, [el('x', _a)]),
        fr(1400, [el('x', _b)]), // first settles at 400
        fr(3000, [el('x', _b)]),
        fr(4000, [el('x', _a)]), // second settles at 1000 after 3000
        fr(4500, [el('x', _a)]),
      ], interactions: const [
        Interaction(1000, 'one'),
        Interaction(3000, 'two'),
      ]);
      final l = _load(s);
      expect(l.map((f) => f.elementId), ['one', 'two']);
      expect(l[0].score, closeTo(0.025, 1e-9));
      expect(l[1].score, closeTo(0.075, 1e-9));
      expect(l[0].atMs, 1400);
      expect(l[1].atMs, 4000);
    });
  });

  group('activity', () {
    test('an element appearing counts', () {
      final s = sc([
        fr(1000, [el('x', _a)]),
        fr(2000, [el('x', _a), el('y', _a)]),
        fr(2100, [el('x', _a), el('y', _a)]),
      ], interactions: const [Interaction(1000, 'src')]);
      expect(_one(s), closeTo(0.075, 1e-9));
    });
    test('an element disappearing counts', () {
      final s = sc([
        fr(1000, [el('x', _a), el('spinner', _a)]),
        fr(2000, [el('x', _a)]),
        fr(2100, [el('x', _a)]),
      ], interactions: const [Interaction(1000, 'src')]);
      expect(_one(s), closeTo(0.075, 1e-9));
    });
    test('a colour change counts', () {
      final s = sc([
        fr(1000, [el('x', _a)]),
        fr(2000, [el('x', _a, color: 0xFF808080)]),
        fr(2100, [el('x', _a, color: 0xFF808080)]),
      ], interactions: const [Interaction(1000, 'src')]);
      expect(_one(s), closeTo(0.075, 1e-9));
    });
    test('the last change sets the settle, not the first', () {
      final s = sc([
        fr(1000, [el('x', _a)]),
        fr(1100, [el('x', _b)]),
        fr(1200, [el('x', _b)]),
        fr(2000, [el('x', _a)]),
        fr(2100, [el('x', _a)]),
      ], interactions: const [Interaction(1000, 'src')]);
      expect(_one(s), closeTo(0.075, 1e-9));
    });
  });

  group('unsettled', () {
    test('still changing at the last frame costs the full weight', () {
      final s = _settling(500, settled: false);
      expect(_one(s), closeTo(0.25, 1e-9)); // curve(500) is .15, ignored
      expect(_load(s).single.severity, ShiftSeverity.error);
    });
    test('full cost even when the change was instant', () {
      expect(_one(_settling(50, settled: false)), closeTo(0.25, 1e-9));
    });
    test('an animation chain does not discount it', () {
      final s = _settling(500, settled: false, animations: const [
        AnimationSpan(1100, 1300, chainId: 'c'),
        AnimationSpan(1300, 1500, chainId: 'c'),
      ]);
      expect(_one(s), closeTo(0.25, 1e-9));
    });
  });

  group('animation', () {
    const chain = [
      AnimationSpan(1100, 1400, chainId: 'c'),
      AnimationSpan(1400, 1700, chainId: 'c'),
    ];
    test('a qualifying chain during the load halves it', () {
      // settle 1000: .25 * .3 * .5
      expect(_one(_settling(1000, animations: chain)), closeTo(0.0375, 1e-9));
    });
    test('a chain that fails the cycle rule gives no discount', () {
      final bad = [
        const AnimationSpan(1100, 1900, chainId: 'c'), // 800 ms cycle
      ];
      expect(_one(_settling(1000, animations: bad)), closeTo(0.075, 1e-9));
    });
    test('a placeholder animation at the start shifts the curve', () {
      // starts 50 ms after the interaction: curve(1000 - 100) = .1 + .2*500/600
      const fade = [AnimationSpan(1050, 1200, elementId: 'x')];
      final expected = 0.25 * (0.1 + 0.2 * 500 / 600);
      expect(_one(_settling(1000, animations: fade)), closeTo(expected, 1e-9));
    });
    test('an animation starting after the grace window does not shift', () {
      const late = [AnimationSpan(1300, 1450, elementId: 'x')];
      expect(_one(_settling(1000, animations: late)), closeTo(0.075, 1e-9));
    });
  });

  group('presets', () {
    test('loadWeight: strict >= standard >= lenient', () {
      expect(ShiftPolicy.strict.loadWeight, 0.4);
      expect(ShiftPolicy.lenient.loadWeight, 0.15);
      final s = _settling(2000);
      final st = _one(s, ShiftPolicy.strict);
      final sd = _one(s);
      final le = _one(s, ShiftPolicy.lenient);
      expect(st, greaterThanOrEqualTo(sd));
      expect(sd, greaterThanOrEqualTo(le));
    });
    test('copyWith overrides', () {
      final p = ShiftPolicy.standard.copyWith(loadWeight: 1.0, loadCurve: const [
        LatencyPoint(0, 0),
        LatencyPoint(1000, 1),
      ]);
      expect(_one(_settling(500), p), closeTo(0.5, 1e-9));
    });
  });
}
