// A cycle read that throws must not look like cycle tracking being off.
//
// The catch used to swap in `const CycleData()`, which is `enabled: false`,
// so a failed read rendered the "Cycle tracking is off" opt-in card: her logs
// and prediction looked gone and the screen offered to turn on a feature that
// was already on.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/cycle_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget _frame(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: buildTheme(Brightness.light),
  home: Scaffold(body: ListView(children: [child])),
);

void main() {
  testWidgets('a failed read shows a retry card, not the opt-in card', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      _frame(
        CycleTab(
          loader: () async {
            calls++;
            if (calls == 1) throw StateError('database closed');
            return const CycleData(enabled: true);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Cycle tracking is off'), findsNothing);
    expect(find.textContaining('Turn on cycle tracking'), findsNothing);
    expect(find.textContaining('Could not read your cycle data'), findsOneWidget);

    await tester.tap(find.textContaining('Could not read your cycle data'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.textContaining('Could not read your cycle data'), findsNothing);
    expect(find.textContaining('Cycle tracking is off'), findsNothing);
    expect(find.textContaining('No period logged yet'), findsOneWidget);
  });

  testWidgets('a read that keeps failing stays on the retry card', (
    tester,
  ) async {
    await tester.pumpWidget(
      _frame(
        CycleTab(
          loader: () async => throw StateError('database closed'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Cycle tracking is off'), findsNothing);
    expect(find.textContaining('Could not read your cycle data'), findsOneWidget);
  });
}
