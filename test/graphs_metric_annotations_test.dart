// NO ANNOTATIONS ON THE METRIC-DETAIL HERO.
//
// WHY: marks spread over weeks say little and can mislead, so the multi-day
// hero draws no annotation lane and has no "Journal marks" chip. An
// algorithm-version change is the plain dotted line (`xMarks`) with its
// footnote, exactly as upstream draws it. The clock is the real one
// (upstream's screen counts slots back from DateTime.now()), so every date is
// relative.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

DateTime _day(int back, [int h = 12]) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - back, h);
}

int _stamp(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

// Seven days; the break is the first day computed the new way, 2 days behind
// today: slot 6 - 2 = 4, the mark half a slot to its left.
MetricData _data() => MetricData(
      daysAvailable: 40,
      series: [
        for (var back = 6; back >= 0; back--)
          (t: _stamp(_day(back)), v: 58.0 + back % 3),
      ],
      algoBreaks: [_stamp(_day(2))],
    );

Future<void> _open(WidgetTester t) async {
  t.view.physicalSize = const Size(390 * 3, 1800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: MetricDetail('resting_hr', data: _data())),
  ));
  await t.pumpAndSettle();
  await t.tap(find.text('7 days'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('draws no annotation lane, icon or Journal marks chip', (t) async {
    await _open(t);
    expect(find.byKey(ChartAnnotationLane.laneKey), findsNothing);
    expect(find.byKey(ChartAnnotationLane.linesKey), findsNothing);
    expect(find.byType(AnnotationIcon), findsNothing);
    expect(find.text('Journal marks'), findsNothing);
  });

  testWidgets('an algorithm-version change is the dotted line with its '
      'footnote', (t) async {
    await _open(t);
    expect(find.textContaining('The dotted line is a change'), findsOneWidget);
    expect(find.textContaining('dashed'), findsNothing);
    final h = t.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('Algorithm version')), findsNothing);
    h.dispose();
  });
}
