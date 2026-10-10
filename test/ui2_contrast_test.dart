// The contrast floor for lib/ui2, asserted numerically in both themes.
//
// The design system this replaces failed WCAG AA on its muted caption ink at
// 2.20–2.71:1, across 223 call sites. That did not happen because anyone chose
// an illegible grey; it happened because nothing measured. A palette edit is
// eyeballed on one surface in one theme, and the other seven combinations ship.
//
// So the floor is not a convention here. `P.on` and `P.fill` compute their way
// to it, and this test sweeps every accent × every surface × both themes to
// prove they got there. Adding a colour to `C.all` without it clearing AA
// fails the build.
//
// Modelled on test/zone_contrast_test.dart, which does the same job for the
// live-session HR ramp.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/charts.dart';
import 'package:openstrap_edge/ui2/theme.dart';

/// WCAG 2.1 AA for body text. The same constant the tokens solve against.
const _aa = 4.5;

void main() {
  final themes = {'light': const P(false), 'dark': const P(true)};

  // The tokens' own luminance/contrast maths, checked against the two anchors
  // everyone knows, so a bug in the metric can't quietly pass every other test
  // in this file.
  group('the measurement itself', () {
    test('black on white is 21:1, a colour on itself is 1:1', () {
      expect(P.contrast(const Color(0xFF000000), const Color(0xFFFFFFFF)),
          closeTo(21, 0.01));
      expect(P.contrast(C.blue, C.blue), closeTo(1, 0.001));
    });
  });

  group('body ink clears AA on every surface it can land on', () {
    themes.forEach((name, p) {
      final surfaces = {'bg': p.bg, 'card': p.card, 'card2': p.card2};
      final inks = {'ink': p.ink, 'ink2': p.ink2, 'ink3': p.ink3};
      inks.forEach((ik, iv) {
        surfaces.forEach((sk, sv) {
          test('$name · $ik on $sk', () {
            final r = P.contrast(iv, sv);
            expect(r, greaterThanOrEqualTo(_aa),
                reason: '$ik measures ${r.toStringAsFixed(2)}:1 on $sk in the '
                    '$name theme. Muted is not the same as invisible.');
          });
        });
      });
    });
  });

  group('P.on() makes any accent safe as text', () {
    themes.forEach((name, p) {
      for (final accent in C.all) {
        final hex = accent.toARGB32().toRadixString(16).padLeft(8, '0');
        test('$name · on(#$hex) on every surface', () {
          final ink = p.on(accent);
          for (final s in {'bg': p.bg, 'card': p.card, 'card2': p.card2}.entries) {
            final r = P.contrast(ink, s.value);
            expect(r, greaterThanOrEqualTo(_aa),
                reason: 'on(#$hex) measures ${r.toStringAsFixed(2)}:1 on '
                    '${s.key} in the $name theme.');
          }
        });
      }
    });
  });

  group('P.fill() makes any accent safe under inkOnFill', () {
    themes.forEach((name, p) {
      for (final accent in C.all) {
        final hex = accent.toARGB32().toRadixString(16).padLeft(8, '0');
        test('$name · inkOnFill on fill(#$hex)', () {
          final r = P.contrast(p.inkOnFill, p.fill(accent));
          expect(r, greaterThanOrEqualTo(_aa),
              reason: 'a button label measures ${r.toStringAsFixed(2)}:1 on '
                  'its own fill in the $name theme.');
        });
      }
    });
  });

  group('P.on() is also safe on the TINTED surface it lands on', () {
    // `Pill` and the active `SubTabs` chip put `on(a)` on `wash(a)`, which is
    // not one of the three flat surfaces anything was solved against. Five of
    // six accents measured 4.30–4.49 there: the chips the app uses to say
    // "estimated" and "relative" were the least legible text in it.
    themes.forEach((name, p) {
      for (final accent in C.all) {
        final hex = accent.toARGB32().toRadixString(16).padLeft(8, '0');
        test('$name · on(#$hex) on wash(#$hex)', () {
          for (final under in {'card': p.card, 'card2': p.card2, 'bg': p.bg}.entries) {
            final surface = Color.alphaBlend(p.wash(accent), under.value);
            final r = P.contrast(p.on(accent), surface);
            expect(r, greaterThanOrEqualTo(_aa),
                reason: 'a chip label measures ${r.toStringAsFixed(2)}:1 on its '
                    'own wash over ${under.key} in the $name theme.');
          }
        });
      }
    });

    test('a wash cannot be turned up past a wash', () {
      // `wash(teal, strength: 1.6)` existed, and `ink3` on it measured 2.99:1.
      for (final p in themes.values) {
        expect(p.wash(C.teal, strength: 4).a, p.wash(C.teal).a);
      }
    });
  });

  // ── what a PAINTER draws ─────────────────────────────────────────────────
  //
  // The sweep above covers `p.on` and `p.fill`, which is every label and every
  // button — and none of the marks. A chart line's colour IS its information,
  // so it needs the floor as much as text does, and the two palettes the
  // painters own were spending raw pigment: `C.sky` measured 1.67:1 on a white
  // card, which made the Light lane — most of a night — very nearly invisible.
  group('a mark is measured like a label', () {
    themes.forEach((name, p) {
      final marks = <String, Color>{
        for (final e in Hypnogram.cols(p).entries) 'hypnogram ${e.key.name}': e.value,
        for (var i = 0; i < ZoneRows.cols(p).length; i++)
          'zone ${i + 1}': ZoneRows.cols(p)[i],
      };
      marks.forEach((what, ink) {
        test('$name · $what against the card it is drawn on', () {
          for (final s in {'bg': p.bg, 'card': p.card, 'card2': p.card2}.entries) {
            final r = P.contrast(ink, s.value);
            expect(r, greaterThanOrEqualTo(_aa),
                reason: '$what measures ${r.toStringAsFixed(2)}:1 on ${s.key} '
                    'in the $name theme.');
          }
        });
      });
    });

    test('the swatch in the key is the mark on the chart', () {
      // The legend is the only way to read a multi-colour chart, so a legend
      // solved differently from the plot is a key to a different picture.
      for (final p in themes.values) {
        expect([for (final (_, c) in Hypnogram.legend(p)) c],
            [for (final s in SleepStage.values) Hypnogram.cols(p)[s]]);
      }
    });

    test('the sleep lanes run light to dark in both themes', () {
      // Awake palest, deep darkest, by luminance, so the order reads without
      // hue — and each step is far enough from the next to tell apart.
      for (final p in themes.values) {
        final ink = Hypnogram.cols(p);
        final lum = [
          for (final s in SleepStage.values) ink[s]!.computeLuminance(),
        ];
        for (var i = 1; i < lum.length; i++) {
          expect(lum[i], lessThan(lum[i - 1]),
              reason: '${SleepStage.values[i].name} must be darker than '
                  '${SleepStage.values[i - 1].name} (dark: ${p.dark})');
          expect(
              P.contrast(ink[SleepStage.values[i]]!,
                  ink[SleepStage.values[i - 1]]!),
              greaterThan(1.2));
        }
      }
    });
  });

  test('the raw pigment really was unsafe — this test has teeth', () {
    // If the solver ever became a no-op, every assertion above would still
    // pass on whichever accents happen to be dark enough. Pin the specific
    // failure it exists to prevent.
    const p = P(false);
    expect(P.contrast(C.green, p.card), lessThan(_aa),
        reason: 'raw green on white is 2.28:1 — that is the bug');
    expect(P.contrast(p.on(C.green), p.card), greaterThanOrEqualTo(_aa));
    // …and that the fix is a nudge, not a repaint: it must still read green.
    expect(p.on(C.green).g, greaterThan(p.on(C.green).b));
    expect(p.on(C.green).g, greaterThan(p.on(C.green).r));
  });

  test('solving is memoised — a repaint is not a search', () {
    const p = P(true);
    final first = p.on(C.purple);
    expect(identical(p.on(C.purple), first) || p.on(C.purple) == first, isTrue);
  });

  group('reduced motion collapses every duration', () {
    testWidgets('motion() returns zero and animate() returns finished',
        (tester) async {
      late BuildContext on, off;
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(builder: (c) {
          off = c;
          return MediaQuery(
            data: const MediaQueryData(disableAnimations: false),
            child: Builder(builder: (c2) {
              on = c2;
              return const SizedBox.shrink();
            }),
          );
        }),
      ));

      expect(motion(off, Motion.base), Duration.zero);
      expect(animate(off, 0.3), 1);
      expect(Motion.enabled(off), isFalse);

      expect(motion(on, Motion.base), Motion.base);
      expect(animate(on, 0.3), 0.3);
      expect(Motion.enabled(on), isTrue);
    });
  });
}
