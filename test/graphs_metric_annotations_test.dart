// ANNOTATIONS ON THE METRIC-DETAIL HERO (Graphs PR, red tests).
//
// WHY: the hero trend draws an algorithm-version change as a bare dotted line
// that only a footnote explains. The annotation system draws it as an icon with
// a DASHED line (provenance, in its own neutral icon) and puts the user's own
// journal items (workouts, meals, timed journal fields) on the days they
// happened, behind a "Journal marks" chip that is OFF by default and reads
// nothing until it is turned on. Ported from the fork's
// metric_detail_annotations_test.dart; the clock is the real one (upstream's
// screen counts slots back from DateTime.now()), so every date is relative.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
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

ChartAnnotation _water() => ChartAnnotation(
      id: 'jw',
      kind: AnnotationKind.water,
      // Yesterday, 09:00: slot 5 of 0..6.
      at: _day(1, 9).millisecondsSinceEpoch / 1000,
      label: 'Drank water',
    );

const _algoId = 'algo:2';

Future<List<(String, String)>> _open(WidgetTester t,
    {Future<List<ChartAnnotation>> Function(String, String)? loader}) async {
  t.view.physicalSize = const Size(390 * 3, 1800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final calls = <(String, String)>[];
  await t.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: MetricDetail(
        'resting_hr',
        data: _data(),
        annotationLoader: (a, b) {
          calls.add((a, b));
          return (loader ?? (_, _) async => [_water()])(a, b);
        },
      ),
    ),
  ));
  await t.pumpAndSettle();
  await t.tap(find.text('7 days'));
  await t.pumpAndSettle();
  return calls;
}

Finder get _chip => find.byKey(MetricDetail.journalToggleKey);
Finder _icon(String id) => find.byKey(ChartAnnotationLane.iconKey(id));

bool _on(WidgetTester t) {
  return t.getSemantics(_chip).getSemanticsData().flagsCollection.isSelected == Tristate.isTrue;
}

void main() {
  group('algorithm-version marks', () {
    testWidgets('are an icon with a dashed line, always on, on the day\'s '
        'boundary', (t) async {
      await _open(t);
      expect(_icon(_algoId), findsOneWidget);
      expect(_icon(_algoId), findsOneWidget);
      expect(t.widget<AnnotationIcon>(_icon(_algoId)).kind,
          AnnotationKind.algoVersion);
      expect(find.byKey(ChartAnnotationLane.laneKey), findsOneWidget);
      expect(find.byKey(ChartAnnotationLane.linesKey), findsOneWidget);
      final lane = t.getRect(find.byKey(ChartAnnotationLane.laneKey));
      final lines = (t
              .widget<CustomPaint>(find.byKey(ChartAnnotationLane.linesKey))
              .painter as AnnotationLinesPainter)
          .lines;
      final line = lines.firstWhere((l) => l.id == _algoId);
      expect(line.dashed, isTrue);
      // The dotted line sat at (n - 1 - b - .5) / (n - 1) = 3.5 / 6.
      expect(line.x, moreOrLessEquals(lane.width * 3.5 / 6, epsilon: .5));
    });

    testWidgets('are spoken once, not "Algorithm version, Algorithm version"',
        (t) async {
      final h = t.ensureSemantics();
      await _open(t);
      expect(find.bySemanticsLabel('Algorithm version'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Algorithm version, Algorithm')),
          findsNothing);
      h.dispose();
    });

    testWidgets('the footnote calls them dashed, not dotted, in English',
        (t) async {
      await _open(t);
      expect(find.textContaining('dashed line'), findsOneWidget);
      expect(find.textContaining('dotted'), findsNothing);
    });
  });

  group('the journal chip', () {
    testWidgets('is on the hero, off by default, and nothing is read for it',
        (t) async {
      final calls = await _open(t);
      expect(_chip, findsOneWidget);
      expect(_on(t), isFalse);
      expect(calls, isEmpty, reason: 'off means no read at all');
      expect(_icon('jw'), findsNothing);
    });

    testWidgets('speaks its label so a screen reader can find it', (t) async {
      final h = t.ensureSemantics();
      await _open(t);
      expect(find.bySemanticsLabel('Journal marks'), findsOneWidget);
      h.dispose();
    });

    testWidgets('turning it on reads the window\'s days once and draws the '
        'marks on their day\'s slot', (t) async {
      final calls = await _open(t);
      await t.tap(_chip);
      await t.pumpAndSettle();
      expect(_on(t), isTrue);
      expect(calls, [(dayLabelOf(_day(6)), dayLabelOf(_day(0)))]);
      expect(_icon('jw'), findsOneWidget);
      expect(t.widget<AnnotationIcon>(_icon('jw')).kind, AnnotationKind.water);
      expect(find.byKey(ChartAnnotationLane.laneKey), findsOneWidget);
      expect(find.byKey(ChartAnnotationLane.linesKey), findsOneWidget);
      final lane = t.getRect(find.byKey(ChartAnnotationLane.laneKey));
      final lines = (t
              .widget<CustomPaint>(find.byKey(ChartAnnotationLane.linesKey))
              .painter as AnnotationLinesPainter)
          .lines;
      expect(lines.firstWhere((l) => l.id == 'jw').x,
          moreOrLessEquals(lane.width * 5 / 6, epsilon: .5),
          reason: 'yesterday is slot 5 of 0..6, where the line chart plots it');
    });

    testWidgets('turning it off removes the journal marks and keeps the '
        'algorithm mark', (t) async {
      await _open(t);
      await t.tap(_chip);
      await t.pumpAndSettle();
      await t.tap(_chip);
      await t.pumpAndSettle();
      expect(_on(t), isFalse);
      expect(_icon('jw'), findsNothing);
      expect(_icon(_algoId), findsOneWidget);
    });

    testWidgets('a failed read draws nothing and does not throw', (t) async {
      var asked = 0;
      await _open(t, loader: (_, _) async {
        asked++;
        throw StateError('the store cannot be read');
      });
      await t.tap(_chip);
      await t.pumpAndSettle();
      expect(asked, 1, reason: 'the loader really was asked, and it threw');
      expect(t.takeException(), isNull);
      expect(_icon('jw'), findsNothing);
      expect(_icon(_algoId), findsOneWidget);
    });
  });
}
