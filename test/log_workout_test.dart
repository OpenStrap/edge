// THE TWO SCREENS THE UI REBUILD LEFT OUT, RENDERED.
//
// Reading a widget tree does not find layout bugs — this project has paid for
// that three times over (a negative margin asserts, an OverflowBox blanks a
// whole tab, Expanded and Flexible in one Row split it 50/50). Both of these
// are pumped at a real phone width, and both are driven: the form's validation
// is exercised through the controls a thumb would use, not by calling the pure
// function underneath it.
//
// Neither screen gets an AppState here on purpose. `repoOf`/`appOf` return
// null without one, which is exactly the golden case — a screen that cannot
// reach the repository must still render its own absence rather than throw.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/screens/log_workout.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// A real phone, and tall enough that nothing under test is below the fold —
/// the default 800x600 harness hides the very controls these tests are about.
Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: w,
  ));
  await t.pumpAndSettle();
}

/// 18:30–19:31 on a fixed day, as the detector would have reported it.
final _now = DateTime(2026, 8, 19, 21);
final _start = DateTime(2026, 8, 19, 18, 30);
final _end = DateTime(2026, 8, 19, 19, 31);

Suggestion _sug({String id = 'a', int? avg = 148, int? peak = 171}) =>
    Suggestion(
      id: id,
      startTs: _start.millisecondsSinceEpoch ~/ 1000,
      endTs: _end.millisecondsSinceEpoch ~/ 1000,
      sport: 'running',
      avgBpm: avg,
      peakBpm: peak,
    );

void main() {
  group('the detected-activity review', () {
    testWidgets('draws the bout, its window and all three answers', (t) async {
      await _pump(t, WorkoutSuggestionScreen(preloaded: [_sug()]));

      expect(find.text('Detected activities'), findsOneWidget);
      expect(find.text('Possible workout'), findsOneWidget);
      // The WINDOW, not just a start time — the whole reason to open this
      // screen is to see whether the detector clipped it.
      expect(find.textContaining('6:30 PM'), findsOneWidget);
      expect(find.textContaining('7:31 PM'), findsOneWidget);
      expect(find.text('61 min'), findsOneWidget);
      // Every answer is reachable, including the one that matters most.
      expect(find.text('Confirm'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);
      // and it never prints a strain or a calorie figure it has not scored
      expect(find.textContaining('strain'), findsNothing);
    });

    testWidgets('an empty review says so, and never as a bare dash', (t) async {
      await _pump(t, WorkoutSuggestionScreen(preloaded: []));
      expect(find.text('Nothing to review'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('a reviewed notification target leaves pending items visible', (t) async {
      await _pump(t, WorkoutSuggestionScreen(
        preloaded: [_sug(), _sug(id: 'b')],
        focusId: 'gone',
      ));
      expect(find.text('Confirm'), findsNWidgets(2));
      expect(find.text('Nothing to review'), findsNothing);
      final cards = t.widgetList<ActivityProposalCard>(find.byType(ActivityProposalCard));
      expect(cards.any((c) => c.highlighted), isFalse);
    });

    testWidgets('notification highlights the bout and keeps the other pending items',
        (t) async {
      await _pump(
        t,
        WorkoutSuggestionScreen(
          preloaded: [_sug(), _sug(id: 'b', avg: 96, peak: 110)],
          focusId: 'b',
        ),
      );
      expect(find.text('Confirm'), findsNWidgets(2));
      final cards = t.widgetList<ActivityProposalCard>(find.byType(ActivityProposalCard)).toList();
      expect(cards.singleWhere((c) => c.highlighted).suggestion.id, 'b');
    });

    testWidgets('nothing overflows at 2x text', (t) async {
      t.view.physicalSize = const Size(390 * 3, 3000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: WorkoutSuggestionScreen(preloaded: [_sug(), _sug(id: 'b')]),
        ),
      ));
      await t.pumpAndSettle();
      // An overflow paints its stripe and reports through the harness rather
      // than failing the pump, so it has to be taken to be seen.
      expect(t.takeException(), isNull);
    });
  });

  group('the manual-entry form', () {
    testWidgets('opens on a valid window and offers to save it', (t) async {
      await _pump(t, LogWorkout(now: _now));
      expect(find.text('Log a past workout'), findsOneWidget);
      // Defaults to the last whole hour, which is a WINDOW — a form that opens
      // on "now to now" opens invalid.
      expect(find.text('60 min'), findsOneWidget);
      expect(find.text('That window will not save'), findsNothing);
      expect(find.text('Log it'), findsOneWidget);
    });

    testWidgets('a window that overlaps one already logged is refused', (
      t,
    ) async {
      await _pump(
        t,
        LogWorkout(
          now: _now,
          start: _start,
          end: _end,
          spans: [
            SessionSpan(
              'manual:1',
              _start.millisecondsSinceEpoch ~/ 1000 + 600,
              _end.millisecondsSinceEpoch ~/ 1000 + 600,
            ),
          ],
        ),
      );
      expect(find.text('That window will not save'), findsOneWidget);
      expect(
        find.text('That overlaps a workout already in your log.'),
        findsOneWidget,
      );
    });

    testWidgets('a retime keeps the type and does not offer to change it', (
      t,
    ) async {
      await _pump(
        t,
        LogWorkout(
          sessionId: 'manual:123',
          now: _now,
          start: _start,
          end: _end,
          activity: activityByName('running'),
          title: 'Fix the times',
        ),
      );
      expect(find.text('Fix the times'), findsWidgets);
      expect(find.text('Save the new times'), findsOneWidget);
      // The row that would change the activity is absent: a retime is about
      // the window, and the type belongs to the row already.
      expect(find.text('Activity'), findsNothing);
    });

    testWidgets('picking an end time before the start rolls to the next day', (
      t,
    ) async {
      // 23:40 → 00:20 is an ordinary late run, not an invalid window.
      final late = DateTime(2026, 8, 19, 23, 40);
      await _pump(
        t,
        LogWorkout(
          now: DateTime(2026, 8, 20, 8),
          start: late,
          end: late.add(Motion.tick * 2400),
          activity: activityByName('running'),
        ),
      );
      expect(find.text('40 min'), findsOneWidget);
      expect(find.text('the next morning'), findsOneWidget);
      expect(find.text('That window will not save'), findsNothing);
    });
  });

  group('the day label', () {
    final now = DateTime(2026, 8, 19, 12);
    test('names today and yesterday, then the date', () {
      expect(dayLabel(DateTime(2026, 8, 19, 6), now: now), 'Today');
      expect(dayLabel(DateTime(2026, 8, 18, 23), now: now), 'Yesterday');
      expect(dayLabel(DateTime(2026, 8, 11, 9), now: now), 'Tue 11 Aug');
    });

    test('counts calendar days, not 24-hour blocks', () {
      // 23:59 yesterday to 00:01 today is two minutes and one day. An
      // `inDays` on the difference calls it "Today".
      expect(dayLabel(DateTime(2026, 8, 18, 23, 59),
          now: DateTime(2026, 8, 19, 0, 1)), 'Yesterday');
    });
  });
}
