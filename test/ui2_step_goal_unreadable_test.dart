// The step goal editor on the steps detail screen must not close as if it had
// saved when what was typed cannot be read as a number.
//
// Driven through the real `MetricDetail('steps', data: d)` widget, which skips
// the repo/AppState load path. There is no AppState Provider above it, so any
// path that reaches `updateProfile` would throw here too.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _pumpSteps(WidgetTester t) async {
  t.view.physicalSize = const Size(390 * 3, 900 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final today = DateTime.now();
  final series = [
    for (var i = 6; i >= 0; i--)
      (
        t: today.subtract(Duration(days: i)).millisecondsSinceEpoch ~/ 1000,
        v: 6000.0,
      ),
  ];
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: MetricDetail(
        'steps',
        data: MetricData(daysAvailable: 10, series: series, stepGoal: 10000),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

Future<void> _openEditorAndType(WidgetTester t, String text) async {
  // The edit and save buttons' labels merge into the gauge card's one
  // semantics node ("60% | Edit daily step goal | Goal | ..."), and tapping
  // that node lands on the ring, so the taps go to the buttons themselves.
  final edit = find.text('10,000 steps');
  await t.ensureVisible(edit);
  await t.tap(edit);
  await t.pumpAndSettle();
  await t.enterText(find.byType(TextField), text);
  await t.pump();
  await t.tap(find.byIcon(LucideIcons.check));
  await t.pumpAndSettle();
}

void main() {
  for (final typed in ['12k', '12,000', '12.000 steps']) {
    testWidgets('an unreadable goal "$typed" keeps the editor open and says so',
        (t) async {
      final handle = t.ensureSemantics();
      await _pumpSteps(t);
      await _openEditorAndType(t, typed);

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Nothing was saved'), findsOneWidget);
      // The editor is still up, holding exactly what was typed.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text(typed), findsOneWidget);
      handle.dispose();
    });
  }

  testWidgets('a blank goal still closes the editor quietly', (t) async {
    final handle = t.ensureSemantics();
    await _pumpSteps(t);
    await _openEditorAndType(t, '');

    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(TextField), findsNothing);
    handle.dispose();
  });
}
