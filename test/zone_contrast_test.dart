// Legibility guard for the HR-zone ramp.
//
// Two real bugs came out of the old (Ember) ramp, which this file used to
// guard until the palette it lived in was deleted (DESIGN_OVERHAUL.md Phase 7):
//
//   1. In light mode the ramp handed back hues tuned for a white background
//      and painted them on near-black.
//   2. The resting zone mapped to a SURFACE token, not an ink, and measured
//      1.03:1 against the session background: invisible, at the start of
//      every workout and whenever heart rate is low or absent.
//
// The ramp the app draws now is ZoneRows.pigment, solved through P, so both
// lessons are one assertion: every zone, in both themes, clears 4.5:1 on every
// surface — including zone 1, the resting one. A palette edit cannot silently
// reintroduce an unreadable zone.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/charts.dart' show ZoneRows;
import 'package:openstrap_edge/ui2/theme.dart' show C, P;

/// WCAG 2.1 relative luminance.
double _luminance(Color c) {
  double channel(double v) {
    final s = v / 255.0;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }

  return 0.2126 * channel((c.r * 255).roundToDouble()) +
      0.7152 * channel((c.g * 255).roundToDouble()) +
      0.0722 * channel((c.b * 255).roundToDouble());
}

/// WCAG 2.1 contrast ratio, 1.0 (identical) … 21.0 (black on white).
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  // ── the Volt ramp (DESIGN_OVERHAUL D7) ──────────────────────────────────
  //
  // Same 4.5:1 floor the ui2 contrast test uses for every mark.
  group('ZoneRows.cols (the ramp the app draws) is legible', () {
    for (final dark in [true, false]) {
      final p = P(dark);
      for (var z = 0; z < 5; z++) {
        test('zone ${z + 1}, ${dark ? 'dark' : 'light'}: 4.5:1 on every surface',
            () {
          final ink = ZoneRows.cols(p)[z];
          for (final s in {'bg': p.bg, 'card': p.card, 'card2': p.card2}.entries) {
            final r = _contrast(ink, s.value);
            expect(r, greaterThanOrEqualTo(4.5),
                reason: 'zone ${z + 1} is ${r.toStringAsFixed(2)}:1 on ${s.key}');
          }
        });
      }
    }

    test('the ramp is slate-blue, sky, volt, amber, coral', () {
      expect(ZoneRows.pigment, [C.blueSoft, C.sky, C.volt, C.amber, C.coral]);
    });

    test('neighbouring zones are different colours, not just lighter', () {
      for (final dark in [true, false]) {
        final c = ZoneRows.cols(P(dark));
        for (var z = 1; z < 5; z++) {
          expect(c[z], isNot(c[z - 1]),
              reason: 'zone ${z + 1} is zone $z in ${dark ? 'dark' : 'light'}');
        }
      }
    });
  });

}
