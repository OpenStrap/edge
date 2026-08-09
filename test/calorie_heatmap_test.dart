// The workouts activity heatmap's pure layer — day bucketing, the intensity
// scale, and the streak count. All of it is calendar arithmetic over LOCAL
// days, which is exactly where this kind of widget goes wrong: a grid keyed off
// UTC drifts a day for anyone east of Greenwich, and a grid built by adding
// Duration(days: 1) silently loses or repeats a day across a DST transition.
// These tests pin the geometry with an injected `today` so they don't depend on
// when the suite runs.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/workouts/calorie_heatmap.dart';

/// WCAG 2.1 relative luminance.
double _luminance(Color c) {
  double channel(double v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }

  return 0.2126 * channel((c.r * 255).roundToDouble()) +
      0.7152 * channel((c.g * 255).roundToDouble()) +
      0.0722 * channel((c.b * 255).roundToDouble());
}

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  test('grid is weeks x 7 local days, Monday-aligned, ending on this Sunday',
      () {
    final today = DateTime(2026, 6, 10); // a Wednesday
    final days = buildHeatDays(const [], today: today, weeks: 13);

    expect(days.length, 13 * 7);
    expect(days.first.date.weekday, DateTime.monday);
    expect(days.last.date.weekday, DateTime.sunday);
    // Full weeks: the grid runs to the END of today's week, not to today.
    expect(days.last.date, DateTime(2026, 6, 14));
    expect(days.first.date, DateTime(2026, 3, 16));
  });

  test('sessions bucket into their LOCAL day; same-day sessions sum', () {
    final today = DateTime(2026, 6, 10);
    int ts(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

    final days = buildHeatDays([
      // Two efforts on the Monday — a morning run and an evening lift.
      {
        'start_ts': ts(DateTime(2026, 6, 8, 7, 30)),
        'calories': 420,
        'duration_min': 45,
        'type': 'run',
      },
      {
        'start_ts': ts(DateTime(2026, 6, 8, 18, 5)),
        'calories': 260,
        'duration_min': 30,
        'type': 'lift',
      },
      {
        'start_ts': ts(DateTime(2026, 6, 9, 6, 0)),
        'calories': 310,
        'duration_min': 33,
        'type': 'ride',
      },
    ], today: today, weeks: 13);

    final byDate = {for (final d in days) d.date: d};

    final mon = byDate[DateTime(2026, 6, 8)]!;
    expect(mon.kcal, 680, reason: 'both Monday sessions counted');
    expect(mon.sessions, 2);
    expect(mon.durationMin, 75);

    final tue = byDate[DateTime(2026, 6, 9)]!;
    expect(tue.kcal, 310);
    expect(tue.sessions, 1);

    // A rest day is a real zero, not a gap in the list.
    expect(byDate[DateTime(2026, 6, 7)]!.kcal, 0);
    expect(byDate[DateTime(2026, 6, 7)]!.sessions, 0);
  });

  test('days after today are flagged future, today itself is not', () {
    final today = DateTime(2026, 6, 10); // Wednesday
    final days = buildHeatDays(const [], today: today, weeks: 13);
    final byDate = {for (final d in days) d.date: d};

    // Thu/Fri/Sat/Sun of the current week haven't happened. Drawing them as
    // empty wells would read as "you skipped Saturday" — so they carry a flag
    // the grid uses to render nothing at all.
    expect(byDate[DateTime(2026, 6, 11)]!.isFuture, isTrue);
    expect(byDate[DateTime(2026, 6, 14)]!.isFuture, isTrue);

    expect(byDate[DateTime(2026, 6, 10)]!.isFuture, isFalse,
        reason: 'today is drawn — it is in progress, not unreachable');
    expect(byDate[DateTime(2026, 6, 9)]!.isFuture, isFalse);
    expect(days.where((d) => d.isFuture).length, 4);
  });

  test('the grid keeps exactly one cell per date across a DST transition', () {
    // Late March / early November span the EU and US clock changes. Whatever
    // zone the suite runs in, every date must appear exactly once and the
    // spacing must stay one calendar day.
    for (final today in [DateTime(2026, 4, 8), DateTime(2026, 11, 11)]) {
      final days = buildHeatDays(const [], today: today, weeks: 13);
      final dates = days.map((d) => d.date).toList();

      expect(dates.toSet().length, dates.length, reason: 'no repeated date');
      for (final d in dates) {
        expect(d.hour, 0, reason: 'every cell sits at local midnight');
      }
      for (var i = 1; i < dates.length; i++) {
        final prev = dates[i - 1];
        expect(dates[i], DateTime(prev.year, prev.month, prev.day + 1),
            reason: 'consecutive calendar days, no skips');
      }
    }
  });

  test('scale is the p90 of TRAINED days, with a floor', () {
    HeatDay d(int kcal) => HeatDay(date: DateTime(2026, 1, 1), kcal: kcal);

    // Ten trained days, 100..1000. Nearest-rank p90 lands on 900 — the scale
    // deliberately ignores the single hardest day so one outlier session
    // doesn't flatten the whole quarter into pale tints.
    expect(
      heatScale([for (var i = 1; i <= 10; i++) d(i * 100)]),
      900,
    );

    // Rest days must not drag the percentile down; only trained days count.
    expect(
      heatScale([...List.generate(50, (_) => d(0)), for (var i = 1; i <= 10; i++) d(i * 100)]),
      900,
    );

    // A beginner's light week would otherwise make a 70 kcal walk "max red".
    expect(heatScale([d(50), d(60), d(70)]), 250, reason: 'floored');

    // Nothing logged at all — still a usable divisor, never zero.
    expect(heatScale(const []), 250);
    expect(heatScale([d(0), d(0)]), 250);
  });

  test('level 0 means rest; 1..4 split the scale into quarters', () {
    // Zero is its OWN bucket, not "the bottom of the ramp" — a rest day and a
    // very light day must never paint the same, or the grid stops answering
    // "where are my gaps".
    expect(heatLevel(0, 800), 0);
    expect(heatLevel(1, 800), 1);

    expect(heatLevel(200, 800), 1); // 25% — boundary belongs to the lower band
    expect(heatLevel(201, 800), 2);
    expect(heatLevel(400, 800), 2);
    expect(heatLevel(401, 800), 3);
    expect(heatLevel(600, 800), 3);
    expect(heatLevel(601, 800), 4);

    // Above the p90 there is nowhere left to go — the top bucket absorbs it.
    expect(heatLevel(5000, 800), 4);

    // A degenerate scale must not divide by zero.
    expect(heatLevel(100, 0), 4);
    expect(heatLevel(0, 0), 0);
  });

  test('streak counts consecutive trained days ending today or yesterday', () {
    final today = DateTime(2026, 6, 10); // Wednesday
    int ts(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
    Map<String, dynamic> w(DateTime d) =>
        {'start_ts': ts(d), 'calories': 300, 'duration_min': 30};

    // Mon, Tue, Wed(today) trained; Sunday off.
    var days = buildHeatDays([
      w(DateTime(2026, 6, 8, 7)),
      w(DateTime(2026, 6, 9, 7)),
      w(DateTime(2026, 6, 10, 7)),
    ], today: today);
    expect(currentStreak(days, today: today), 3);

    // Today not trained YET, but yesterday was — the streak is still alive.
    // Ending it at midnight would tell you that you broke it before you've
    // even had a chance to train.
    days = buildHeatDays([
      w(DateTime(2026, 6, 8, 7)),
      w(DateTime(2026, 6, 9, 7)),
    ], today: today);
    expect(currentStreak(days, today: today), 2);

    // Neither today nor yesterday — the streak really is over.
    days = buildHeatDays([
      w(DateTime(2026, 6, 6, 7)),
      w(DateTime(2026, 6, 7, 7)),
    ], today: today);
    expect(currentStreak(days, today: today), 0);

    expect(currentStreak(buildHeatDays(const [], today: today), today: today), 0);
  });

  test('thousands are grouped so a 13-week total stays readable', () {
    // A quarter's burn is a five-figure number. Every other stat in the app is
    // three digits or fewer and renders as a bare int, which is why there was
    // no grouping helper to reach for — at 22140 the run of digits is genuinely
    // hard to parse at a glance.
    expect(groupThousands(0), '0');
    expect(groupThousands(7), '7');
    expect(groupThousands(780), '780');
    expect(groupThousands(999), '999');
    expect(groupThousands(1000), '1,000');
    expect(groupThousands(1080), '1,080');
    expect(groupThousands(22140), '22,140');
    expect(groupThousands(1000000), '1,000,000');
    // Defensive: a negative can't arise from summed calories, but the helper
    // must not mangle the sign if one ever does.
    expect(groupThousands(-1080), '-1,080');
  });

  test('month labels mark the column where each new month begins', () {
    // Without these the grid shows rhythm but not WHEN — you can see a
    // three-week gap and have no idea whether it was March or May.
    final today = DateTime(2026, 6, 10); // grid: Mon 16 Mar .. Sun 14 Jun
    final labels = monthLabels(buildHeatDays(const [], today: today));

    // Column Mondays: 16/23/30 Mar, 6/13/20/27 Apr, 4/11/18/25 May, 1/8 Jun.
    expect(labels.map((l) => l.column).toList(), [0, 3, 7, 11]);
    expect(labels.map((l) => l.text).toList(), ['Mar', 'Apr', 'May', 'Jun']);
  });

  test('a month label is not repeated when a month spans the grid edge', () {
    // A 4-week window sitting entirely inside one month must produce exactly
    // one label, not one per column.
    final labels = monthLabels(
      buildHeatDays(const [], today: DateTime(2026, 6, 24), weeks: 3),
    );
    expect(labels.length, 1);
    expect(labels.single.text, 'Jun');
    expect(labels.single.column, 0);
  });

  test('only LOGGED sessions reach the grid — not detections or live', () {
    // getSessions() merges unconfirmed auto-detected bouts in alongside saved
    // ones. If those reached the grid it would disagree with both the feed and
    // TrainingSummaryCard while the "Suggested workouts" cards still sat above
    // it waiting to be confirmed — the same day would be shaded here and
    // absent there. A live session has no final calorie tally yet, so it is
    // held back too rather than shaded as a near-zero day.
    final kept = loggedForHeatmap([
      {'id': 'a', 'calories': 300, 'status': 'complete'},
      {'id': 'auto_2026-06-08_123', 'source': 'auto', 'status': 'detected'},
      {'id': 'b', 'calories': 400, 'status': 'live'},
      {'id': 'c', 'calories': 500},
    ]);

    expect(kept.map((w) => w['id']), ['a', 'c']);
  });

  test('a CONFIRMED auto-detection is a logged workout and reaches the grid',
      () {
    // The row _logDetectedSession saves when the user taps Confirm on a
    // suggestion. `source` stays 'auto' forever — it records where the workout
    // came from, not whether it is still a proposal — while `status` moves to
    // 'done'. Filtering on source would drop it, which is how a real workout
    // ends up in the feed (tagged `auto`) and in TrainingSummaryCard while the
    // grid shows that day as rest. Someone whose training is mostly
    // detected-then-confirmed would get a near-empty board, and since the card
    // is hidden until a day has kcal, no board at all.
    final kept = loggedForHeatmap([
      {
        'id': 'auto:1749000000',
        'source': 'auto',
        'status': 'done',
        'calories': 480,
      },
      {'id': 'manual-1', 'source': 'manual', 'status': 'done', 'calories': 300},
    ]);

    expect(kept.map((w) => w['id']), ['auto:1749000000', 'manual-1']);
  });

  // The ramp is the whole feature: if two adjacent buckets read as one colour,
  // the grid is decoration. Asserted numerically in BOTH palettes so a future
  // token edit can't quietly collapse a step — the same reasoning as
  // zone_contrast_test.dart.
  group('intensity ramp stays readable', () {
    // Below roughly this, two swatches sitting side by side stop being
    // separable at a ~20px cell.
    const minStep = 1.25;

    for (final entry in <String, Palette>{
      'paper': kLightPalette,
      'char': kDarkPalette,
    }.entries) {
      final mode = entry.key;
      final palette = entry.value;

      test('$mode: luminance is monotonic across levels 0..4', () {
        final lums = [
          for (var l = 0; l <= 4; l++) _luminance(heatColorIn(palette, l)),
        ];
        // Hotter reads DARKER on paper and BRIGHTER on char — one construction,
        // inverted by the palette, because ink flips with the mode.
        final ordered = palette.isDark
            ? List.of(lums)
            : List.of(lums.reversed);
        for (var i = 1; i < ordered.length; i++) {
          expect(ordered[i], greaterThan(ordered[i - 1]),
              reason: '$mode ramp is not monotonic: $lums');
        }
      });

      for (var l = 1; l <= 4; l++) {
        test('$mode: level ${l - 1} and $l are distinguishable', () {
          final ratio =
              _contrast(heatColorIn(palette, l), heatColorIn(palette, l - 1));
          expect(ratio, greaterThanOrEqualTo(minStep),
              reason: '$mode L${l - 1}->L$l is only '
                  '${ratio.toStringAsFixed(2)}:1 apart');
        });
      }

      test('$mode: steps are evenly spaced, not bunched at one end', () {
        // A minimum step isn't sufficient on its own: a ramp can clear it and
        // still be lopsided, spending most of its range between levels 0 and 1
        // and almost none between 3 and 4. Equal kcal differences should look
        // like equal colour differences, so hold the spread between the widest
        // and narrowest step.
        final steps = [
          for (var l = 1; l <= 4; l++)
            _contrast(heatColorIn(palette, l), heatColorIn(palette, l - 1)),
        ];
        final spread =
            steps.reduce(math.max) / steps.reduce(math.min);
        expect(spread, lessThanOrEqualTo(1.55),
            reason: '$mode ramp is lopsided — steps '
                '${steps.map((s) => s.toStringAsFixed(2)).toList()}');
      });

      test('$mode: an empty day is distinct from the card behind it', () {
        // Level 0 is a well, not the card — you have to be able to see the
        // grid's shape even where nothing was logged.
        final ratio = _contrast(
          heatColorIn(palette, 0),
          palette.isDark ? palette.surfaceAlt : palette.surface,
        );
        expect(ratio, greaterThan(1.0),
            reason: '$mode empty cell is invisible against the tile');
      });
    }
  });

  group('CalorieHeatmapCard', () {
    tearDown(() => AppColors.active = kLightPalette);

    final today = DateTime(2026, 6, 10); // Wednesday
    int ts(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

    List<HeatDay> sample() => buildHeatDays([
          {
            'start_ts': ts(DateTime(2026, 6, 8, 7)),
            'calories': 300,
            'duration_min': 30,
          },
          {
            'start_ts': ts(DateTime(2026, 6, 9, 7)),
            'calories': 780,
            'duration_min': 52,
          },
        ], today: today);

    Widget shell(List<HeatDay> days) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CalorieHeatmapCard(days: days, today: today),
            ),
          ),
        );

    // NOT pumpAndSettle: the peak-day ember pulse repeats for as long as the
    // card is on screen, by design, so "settle" never arrives. Pump past the
    // reveal and the header cross-fade instead.
    Future<void> settleAnimated(WidgetTester t) async {
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
    }

    testWidgets('opens on the summary, not on a selected day', (t) async {
      await t.pumpWidget(shell(sample()));
      await settleAnimated(t);

      expect(find.text('1,080'), findsOneWidget, reason: '13-week total');
      expect(find.textContaining('2 sessions'), findsOneWidget);
      expect(find.textContaining('2-day streak'), findsOneWidget);
    });

    testWidgets('tapping a day swaps the header to that day, and back',
        (t) async {
      await t.pumpWidget(shell(sample()));
      await settleAnimated(t);

      await t.tap(find.byKey(const ValueKey('heat-2026-06-09')));
      await settleAnimated(t);

      expect(find.text('780'), findsOneWidget);
      expect(find.textContaining('Tue 9 Jun'), findsOneWidget);
      expect(find.text('1,080'), findsNothing,
          reason: 'the summary yields to the day readout');

      // Tapping the same cell again releases the selection.
      await t.tap(find.byKey(const ValueKey('heat-2026-06-09')));
      await settleAnimated(t);
      expect(find.text('1,080'), findsOneWidget);
    });

    testWidgets('a rest day reads as rest, not as a missing readout',
        (t) async {
      await t.pumpWidget(shell(sample()));
      await settleAnimated(t);

      await t.tap(find.byKey(const ValueKey('heat-2026-06-07')));
      await settleAnimated(t);

      expect(find.textContaining('Sun 7 Jun'), findsOneWidget);
      expect(find.textContaining('No workout'), findsOneWidget);
    });

    testWidgets('month names are rendered above the grid', (t) async {
      await t.pumpWidget(shell(sample()));
      await settleAnimated(t);

      // Grid runs Mon 16 Mar .. Sun 14 Jun 2026 for a today of 10 Jun.
      for (final m in ['Mar', 'Apr', 'May', 'Jun']) {
        expect(find.text(m), findsOneWidget, reason: '$m label missing');
      }
    });

    testWidgets('a month starting in the final column is still labelled',
        (t) async {
      // Wed 3 Jun 2026: the grid's last column opens on Mon 1 Jun, so June
      // starts in the rightmost week. Dropping that label to avoid overflowing
      // the card would leave the MOST RECENT weeks — the ones nearest today —
      // as the only unnamed stretch of the board.
      final today = DateTime(2026, 6, 3);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CalorieHeatmapCard(
              days: buildHeatDays(const [], today: today),
              today: today,
            ),
          ),
        ),
      ));
      await settleAnimated(t);

      expect(find.text('Jun'), findsOneWidget);
      expect(t.takeException(), isNull, reason: 'and it must not overflow');
    });

    testWidgets('future days are not rendered at all', (t) async {
      await t.pumpWidget(shell(sample()));
      await settleAnimated(t);

      // Today exists...
      expect(find.byKey(const ValueKey('heat-2026-06-10')), findsOneWidget);
      // ...but the rest of the week hasn't happened, so there is no cell to
      // mistake for a skipped day.
      expect(find.byKey(const ValueKey('heat-2026-06-11')), findsNothing);
      expect(find.byKey(const ValueKey('heat-2026-06-14')), findsNothing);
    });

    testWidgets('a selection that scrolls out of the window does not crash',
        (t) async {
      await t.pumpWidget(shell(sample()));
      await settleAnimated(t);
      await t.tap(find.byKey(const ValueKey('heat-2026-06-08')));
      await settleAnimated(t);
      expect(find.textContaining('Mon 8 Jun'), findsOneWidget);

      // The card is rebuilt with a LATER window — a refresh crossing midnight,
      // or simply a later session. The previously selected day is no longer on
      // the board, and looking it up must not throw.
      final later = DateTime(2026, 12, 9);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CalorieHeatmapCard(
              days: buildHeatDays(const [], today: later),
              today: later,
            ),
          ),
        ),
      ));
      await settleAnimated(t);

      expect(t.takeException(), isNull);
      // Falls back to the summary rather than showing a phantom day.
      expect(find.textContaining('sessions'), findsOneWidget);
    });

    testWidgets('a part-week list renders, and the header says its own span',
        (t) async {
      // `days` is a constructor argument, so the widget has to survive a list
      // buildHeatDays didn't produce. The column count rounds UP, so the last
      // column indexes past the end of a part-week list, and a header that
      // hardcoded 13 would be describing a window the caller never asked for.
      final days = buildHeatDays(const [], today: today, weeks: 3)
          .take(17) // two whole weeks + 3 days
          .toList();

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CalorieHeatmapCard(days: days, today: today),
          ),
        ),
      ));
      await settleAnimated(t);

      expect(t.takeException(), isNull);
      // TileHeader uppercases its label.
      expect(find.textContaining('3 WEEKS'), findsOneWidget);
      expect(find.textContaining('13 WEEKS'), findsNothing);
    });

    testWidgets('a single-week board says "1 week", not "1 weeks"', (t) async {
      // Three days still round up to one column, and deriving the count is
      // pointless if the only spans it serves read as broken English.
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CalorieHeatmapCard(
              days: buildHeatDays(const [], today: today, weeks: 1)
                  .take(3)
                  .toList(),
              today: today,
            ),
          ),
        ),
      ));
      await settleAnimated(t);

      expect(t.takeException(), isNull);
      expect(find.textContaining('1 WEEK'), findsOneWidget);
      expect(find.textContaining('1 WEEKS'), findsNothing);
    });

    testWidgets('the board fits without overflowing a narrow phone',
        (t) async {
      // Cell size is derived from the available width but clamped at both
      // ends, and a clamped-up minimum can push 13 columns wider than the row
      // that holds them. Overflow paints a yellow-and-black banner over the
      // card, so pin the narrow end.
      t.view.physicalSize = const Size(320 * 3, 700 * 3);
      t.view.devicePixelRatio = 3.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      await t.pumpWidget(shell(sample()));
      await settleAnimated(t);

      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('heat-2026-06-09')), findsOneWidget);
    });

    testWidgets('reduced motion leaves no animation running', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Builder(
          // copyWith, not a bare MediaQueryData: constructing one from scratch
          // resets size to zero and drops textScaler, padding and brightness,
          // so the test would quietly stop describing a real device the moment
          // the card reads any other MediaQuery field.
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: Scaffold(
              body: SingleChildScrollView(
                child: CalorieHeatmapCard(days: sample(), today: today),
              ),
            ),
          ),
        ),
      ));
      // pumpAndSettle times out if any ticker keeps scheduling frames — the
      // peak-day pulse repeats forever, so this is the assertion that it is
      // genuinely suppressed rather than merely started at zero opacity.
      await t.pumpAndSettle();
      expect(find.text('1,080'), findsOneWidget);
    });
  });
}
