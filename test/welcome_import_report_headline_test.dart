import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';

Future<void> _pump(WidgetTester tester, ImportOutcome o) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ImportReport(o))),
    );

void main() {
  // A vendor export with only a workouts.csv selected lands 0 days, 0
  // journal rows and 0 lab rows — the headline used to fall all the way
  // through to "0 journal days written" (and, once labs existed, "0 lab
  // results written") for exactly this outcome.
  testWidgets('workouts-only outcome headlines the workout count, not a zero',
      (tester) async {
    await _pump(tester, const ImportOutcome(source: 'Vendor CSV export', workouts: 3));
    expect(find.textContaining('lab result'), findsNothing);
    expect(find.textContaining('journal'), findsNothing);
    expect(find.textContaining('3 workout'), findsOneWidget);
  });

  testWidgets('skipped-only outcome headlines the skip count, not a zero',
      (tester) async {
    await _pump(tester, const ImportOutcome(source: 'Vendor CSV export', skippedDays: 5));
    expect(find.textContaining('lab result'), findsNothing);
    expect(find.textContaining('already measured'), findsOneWidget);
  });

  testWidgets('lab-only outcome still headlines the lab count', (tester) async {
    await _pump(tester, const ImportOutcome(source: 'Lab results CSV', labRows: 2));
    expect(find.textContaining('2 lab results written'), findsOneWidget);
  });

  testWidgets('days beats every other counter for the headline', (tester) async {
    await _pump(
      tester,
      const ImportOutcome(
          source: 'OpenStrap backup', days: 10, workouts: 3, journalRows: 1, labRows: 1),
    );
    expect(find.textContaining('10 days imported'), findsOneWidget);
    // The others still show, just not as the headline — journal gets its own
    // "replaced" line rather than a second "written" one.
    expect(find.textContaining('3 workout'), findsOneWidget);
    expect(find.textContaining('1 lab result'), findsOneWidget);
    expect(find.textContaining('1 journal day replaced'), findsOneWidget);
  });
}
