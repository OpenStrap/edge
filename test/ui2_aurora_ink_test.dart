// Text on an aurora field clears 4.5:1 against the field's brightest point.
//
// `P.aurora` is solved for the page ink ONLY. The muted inks measure 1.6–2.6:1
// on a dark peak, and the first aurora tiles shipped their labels in ink2 and
// their units in ink3 — legible in light, 2:1 in dark, and nothing failed,
// because the contrast sweep measures tokens, not what a widget picked. This
// measures what the widgets actually painted.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ui2/screens/start_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _aa = 4.5;

void main() {
  final cases = <String, (Color, Widget)>{
    'SignalCard(aurora)': (
      C.domHealth,
      const SignalCard(LucideIcons.heart, C.domHealth, 'Heart rate', '52',
          unit: 'bpm', sub: 'Resting', aurora: true),
    ),
    'StartCard': (
      C.domMove,
      const StartCard(
        label: 'START A SESSION',
        count: 71,
        noun: 'activities',
        art: Art.bandHero,
        accent: C.domMove,
      ),
    ),
  };

  for (final b in Brightness.values) {
    for (final e in cases.entries) {
      testWidgets('${e.key} · ${b.name}: every word clears AA on the peak',
          (t) async {
        final (hue, widget) = e.value;
        await t.pumpWidget(MaterialApp(
          theme: buildTheme(b),
          home: Scaffold(body: SingleChildScrollView(child: widget)),
        ));
        final p = P(b == Brightness.dark);
        final peak = p.aurora(hue);
        final texts = t.widgetList<Text>(find.descendant(
            of: find.byType(AuroraTile), matching: find.byType(Text)));
        expect(texts, isNotEmpty);
        for (final text in texts) {
          final ink = text.style?.color;
          expect(ink, isNotNull, reason: '"${text.data}" has no colour');
          final r = P.contrast(ink!, peak);
          expect(r, greaterThanOrEqualTo(_aa),
              reason: '"${text.data}" measures ${r.toStringAsFixed(2)}:1 on '
                  'the aurora peak in ${b.name}. Only p.ink is solved there.');
        }
      });
    }
  }
}
