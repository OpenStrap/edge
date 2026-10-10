// The Sleep screen's judgement layer, below the fold.
//
// The goldens capture the top of the screen — the viewport is 1400 pt and the
// answer, the hypnogram and the stages fill it. Everything the screen actually
// DECIDES lives further down: which comparison verdict a measure earns, whether
// last night was extreme enough to mention, and whether there is enough history
// to say either. This pumps the whole page into a tall viewport and reads it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _onset = DateTime(2026, 5, 19, 23, 7).millisecondsSinceEpoch ~/ 1000;

Map<String, dynamic> _night({
  int tst = 443,
  int deep = 85,
  bool elevated = false,
}) => {
      'duration_min': tst,
      'in_bed_min': 486,
      'awake_min': 20,
      'efficiency': .91,
      'onset_ts': _onset,
      'wake_ts': _onset + 486 * 60,
      'light_min': 170,
      'deep_min': deep,
      'rem_min': 95,
      'hypnogram': [
        {'t': _onset, 'stage': 'light'},
        {'t': _onset + 3600, 'stage': 'deep'},
        {'t': _onset + 7200, 'stage': 'rem'},
        {'t': _onset + 486 * 60, 'stage': 'awake'},
      ],
      'nocturnal': {
        'sleeping_hr_avg': 52,
        'sleeping_hr_min': 46,
        'vs_baseline_bpm': elevated ? 4.6 : 0.4,
        'elevated': elevated,
      },
    };

List<double> _flat(int n, double v) => List<double>.filled(n, v);

/// The whole page, in a viewport tall enough to build every section — a
/// `RenderFlex` overflow anywhere below the fold fails the pump.
Future<void> _pump(WidgetTester t, SleepData d, {double scale = 1}) async {
  t.view.physicalSize = Size(390 * 3, 5200 * 3 * scale);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: SleepDetail(data: d),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('a measure inside the middle half of your nights is typical',
      (t) async {
    await _pump(
      t,
      SleepData(
        day: '2026-05-20',
        night: _night(),
        tstHistory: [for (var i = 0; i < 20; i++) 400 + i * 5],
        deepHistory: _flat(20, 85),
        effHistory: _flat(20, 91),
      ),
    );
    expect(find.text('Did you sleep enough?'), findsOneWidget);
    expect(find.textContaining('Typical for you'), findsWidgets);
  });

  testWidgets('a short night is measured against the median, not the band edge',
      (t) async {
    await _pump(
      t,
      SleepData(
        day: '2026-05-20',
        // 60 minutes under a history that never moves.
        night: _night(tst: 340),
        tstHistory: _flat(20, 400),
      ),
    );
    expect(find.textContaining('1h 00m shorter than usual'), findsOneWidget);
  });

  testWidgets('an extreme night and an elevated sleeping heart rate are called '
      'out; nothing else is', (t) async {
    await _pump(
      t,
      SleepData(
        day: '2026-05-20',
        night: _night(deep: 120, elevated: true),
        tstHistory: _flat(20, 440),
        deepHistory: [for (var i = 0; i < 20; i++) 60 + i.toDouble()],
        effHistory: _flat(20, 91),
      ),
    );
    expect(find.text('Unusual on Wednesday, 20 May'), findsOneWidget);
    // SLP-13a — the Light/Deep split is unvalidated and flagged
    // `deep_low_confidence` all the way up, so ranking last night's deep
    // minutes against 20 other nights of the same split is not a claim we own.
    expect(find.text('Most deep sleep lately'), findsNothing);
    expect(find.textContaining('Deep sleep came to'), findsNothing);
    expect(find.text('Sleeping heart rate ran high'), findsOneWidget);
    // Detection against the user's own baseline is never a diagnosis, and the
    // card has to say so on the card.
    expect(find.textContaining('not a diagnosis'), findsOneWidget);
    expect(find.textContaining('Nothing stood out'), findsNothing);
  });

  testWidgets('a tie with the record is not an extreme', (t) async {
    await _pump(
      t,
      SleepData(
        day: '2026-05-20',
        // Stage minutes are whole minutes, so tying the lowest of the last 20
        // is ordinary. It used to print "less than any of your last 20 nights,
        // the lowest of which was 41m".
        night: _night(deep: 41),
        tstHistory: _flat(20, 443),
        deepHistory: [41, for (var i = 0; i < 19; i++) 60 + i.toDouble()],
        effHistory: _flat(20, 91),
      ),
    );
    expect(find.text('Least deep sleep lately'), findsNothing);
    expect(find.textContaining('Nothing stood out'), findsOneWidget);
  });

  // ── SLP-13: stage minutes are intervals, and the width is this night's ──
  //
  // The share column that used to be here is gone with the exact minutes it was
  // computed from — a percentage beside a range restores, on the same row, the
  // precision the range exists to retire.
  group('stage ranges', () {
    Map<String, dynamic> staged({double? conf}) => {
          ..._night(tst: 420, deep: 80),
          'light_min': 250,
          'rem_min': 90,
          'awake_min': 60,
          'stages_confidence': ?conf,
        };

    testWidgets('a stage is a range, never a count', (t) async {
      await _pump(t,
          SleepData(day: '2026-05-20', night: staged(), tstHistory: _flat(20, 420)));
      // No confidence published => the WIDEST interval, which is the honest
      // default: we do not know how well we saw the night, so we say least.
      // deep 80m, half-width 0.75x = 60m.
      // Three times: beside the Deep lane, the Stages row, and the header of
      // the Deep comparison below it. All had to move — one card showing a
      // range while another still showed a count is the contradiction this
      // item exists to remove.
      expect(find.text('20m–2h 20m'), findsNWidgets(3));
      // And the share column is gone with the count it was computed from.
      for (final share in const ['52%', '17%', '19%', '13%']) {
        expect(find.text(share), findsNothing);
      }
      expect(find.textContaining('Shares of'), findsNothing);
    });

    testWidgets("a device-staged night shows the device's own minutes, no "
        'range', (t) async {
      final n = {
        ...staged(conf: 0.95),
        'sleep_source': 'vendor_staged',
        'rem_min': null,
      };
      await _pump(t,
          SleepData(day: '2026-05-20', night: n, tstHistory: _flat(20, 420)));
      // Three times: the Deep lane, the Stages row and the Deep comparison,
      // all the count.
      expect(find.text('1h 20m'), findsNWidgets(3));
      // Beside the Light lane and in the Stages row.
      expect(find.text('4h 10m'), findsNWidgets(2));
      expect(find.textContaining('Each stage is a range'), findsNothing);
    });

    testWidgets('a better-seen night gets a narrower range', (t) async {
      await _pump(
          t,
          SleepData(
              day: '2026-05-20',
              night: staged(conf: 0.6), // the segmenter's ceiling
              tstHistory: _flat(20, 420)));
      // Same 80 minutes, half-width 0.45x = 36m. Narrower than the 60m above,
      // from the night's own confidence rather than one published figure.
      expect(find.text('44m–1h 56m'), findsNWidgets(3));
    });

    testWidgets('the deep comparison stops asserting a difference', (t) async {
      await _pump(
        t,
        SleepData(
          day: '2026-05-20',
          night: staged(),
          tstHistory: _flat(20, 420),
          // Every past night 70 minutes: a degenerate band that last night's 80
          // sits above. On the old scalar row that printed "10m more than
          // usual" — a confident difference between two numbers neither of
          // which is a count.
          deepHistory: _flat(20, 70),
        ),
      );
      expect(find.textContaining('more than usual'), findsNothing);
      expect(find.textContaining('Not far enough from usual to call'),
          findsOneWidget);
    });
  });

  testWidgets('an ordinary night says so rather than manufacturing a finding',
      (t) async {
    await _pump(
      t,
      SleepData(
        day: '2026-05-20',
        night: _night(),
        tstHistory: [for (var i = 0; i < 20; i++) 400 + i * 5],
        deepHistory: [for (var i = 0; i < 20; i++) 70 + i.toDouble()],
        effHistory: _flat(20, 91),
      ),
    );
    expect(find.textContaining('Nothing stood out'), findsOneWidget);
  });

  testWidgets('with no history the screen compares nothing and claims nothing',
      (t) async {
    await _pump(
      t,
      SleepData(
        day: '2026-05-20',
        night: _night(elevated: true),
        tstHistory: const [430, 465, 410],
      ),
    );
    // Too little history to compare against. The section stays, carrying the
    // COUNT — absent-but-expected says when it arrives — but it must not claim
    // a comparison it cannot make.
    expect(find.textContaining('3 of 7 nights so far'), findsOneWidget);
    expect(find.textContaining('Typical for you'), findsNothing);
    // The extremes need history; the nocturnal detection carries its own
    // baseline, so the section is present for that alone.
    expect(find.text('Your shortest night lately'), findsNothing);
    expect(find.text('Sleeping heart rate ran high'), findsOneWidget);
  });

  for (final scale in const [2.0, 3.1]) {
    testWidgets('every section survives ${scale}x text', (t) async {
      await _pump(
        t,
        SleepData(
          day: '2026-05-20',
          night: _night(deep: 120, elevated: true),
          timeline: {
            'hr': [
              for (var i = 0; i < 60; i++)
                {'t': _onset + i * 480, 'v': 52 + (i % 11) - 5},
            ],
          },
          need: const Metric(
              value: 462, unit: 'min', confidence: .7, tier: MetricTier.estimate),
          bedtime: const Metric(
              value: 1360, confidence: .7, tier: MetricTier.estimate),
          tstHistory: _flat(20, 440),
          deepHistory: [for (var i = 0; i < 20; i++) 60 + i.toDouble()],
          effHistory: _flat(20, 91),
          onsetHistory: [
            for (var i = 0; i < 20; i++) _onset - (i + 1) * 86400 - 900,
          ],
        ),
        scale: scale,
      );
      expect(find.text('Unusual on Wednesday, 20 May'), findsOneWidget);
    });
  }

  // ── SLP-01 · a hole in the record is not sleep ────────────────────────────

  test('an unobserved stretch is not light sleep', () {
    // First half of the window never recorded, second half deep. The old
    // `_ => SleepStage.light` catch-all turned the whole first half into light
    // sleep, so a band that dropped four hours drew — and read — as a night.
    final st = SleepData(night: {
      ..._night(),
      'hypnogram': [
        {'t': _onset, 'stage': 'unobserved'},
        {'t': _onset + 243 * 60, 'stage': 'deep'},
        {'t': _onset + 486 * 60, 'stage': 'deep'},
      ],
    }).stages;
    expect(st.first, isNull);
    expect(st.last, SleepStage.deep);
    // Nothing in the hole became a stage, and nothing outside it became a hole.
    expect(st.where((s) => s == null).length, closeTo(st.length / 2, 4));
    expect(st.contains(SleepStage.light), isFalse);
  });

  testWidgets('a night with a hole names the window it was measured over',
      (t) async {
    await _pump(
      t,
      SleepData(
        day: '2026-05-20',
        night: _night(),
        tstHistory: _flat(20, 440),
        unobservedMin: 106, // 486 in bed, 380 watched
      ),
    );
    expect(find.text('WATCHED'), findsOneWidget);
    expect(find.text('6h 20m'), findsOneWidget);
    expect(find.textContaining('is not a measurement'), findsOneWidget);
  });

  testWidgets('a fully observed night says nothing about watching', (t) async {
    await _pump(t, SleepData(day: '2026-05-20', night: _night()));
    expect(find.text('WATCHED'), findsNothing);
    expect(find.text('ASLEEP OF THAT'), findsOneWidget);
  });

  // ── SLP-02 · settling time, forced windows only ───────────────────────────

  testWidgets('sleep-onset latency is banded, and only on your own window',
      (t) async {
    await _pump(
      t,
      SleepData(
        day: '2026-05-20',
        night: {..._night(), 'sleep_source': 'manual'},
        solMin: 37,
      ),
    );
    expect(find.textContaining('30–45 minutes'), findsOneWidget);
    // Never a single minute: the stager sees a wrist.
    expect(find.textContaining('37 minutes'), findsNothing);
  });

  testWidgets('an auto window never claims a settling time', (t) async {
    await _pump(
      t,
      SleepData(day: '2026-05-20', night: _night(), solMin: 37),
    );
    expect(find.textContaining('to asleep'), findsNothing);
  });

  // ── SLP-03 · the shape of the night ───────────────────────────────────────

  testWidgets('wake-ups are a floor with the threshold stated', (t) async {
    await _pump(
      t,
      SleepData(
        day: '2026-05-20',
        night: _night(),
        awakenings: 3,
        longestSleepMin: 162,
      ),
    );
    expect(find.textContaining('At least 3 wake-ups of 5 minutes or more'),
        findsOneWidget);
    expect(find.textContaining('invisible to a wrist'), findsOneWidget);
    expect(
        find.textContaining('Longest unbroken stretch 2h 42m'), findsOneWidget);
  });

  testWidgets('tonight is one takeaway, not six numbers', (t) async {
    await _pump(
      t,
      SleepData(
        day: '2026-05-20',
        night: _night(),
        need: const Metric(
            value: 462, unit: 'min', confidence: .7, tier: MetricTier.estimate),
        debt: const Metric(
            value: 22, unit: 'min', confidence: .7, tier: MetricTier.estimate),
        bedtime:
            const Metric(value: 1360, confidence: .7, tier: MetricTier.estimate),
      ),
    );
    expect(find.text('lights out'), findsOneWidget);
    expect(find.textContaining('Your need is 7h 42m'), findsOneWidget);
    expect(find.textContaining('22m down'), findsOneWidget);
  });

  group('correctedSleepWindow', () {
    test('a bedtime moved past midnight stays on the same night', () {
      final (on, off) = correctedSleepWindow(
        DateTime(2026, 3, 1, 23, 50),
        DateTime(2026, 3, 2, 7, 0),
        const TimeOfDay(hour: 0, minute: 20),
        const TimeOfDay(hour: 7, minute: 10),
      );
      expect(on, DateTime(2026, 3, 2, 0, 20));
      expect(off, DateTime(2026, 3, 2, 7, 10));
    });

    test('a bedtime moved back before midnight stays on the same night', () {
      final (on, off) = correctedSleepWindow(
        DateTime(2026, 3, 2, 0, 30),
        DateTime(2026, 3, 2, 7, 0),
        const TimeOfDay(hour: 23, minute: 40),
        const TimeOfDay(hour: 7, minute: 0),
      );
      expect(on, DateTime(2026, 3, 1, 23, 40));
      expect(off, DateTime(2026, 3, 2, 7, 0));
    });

    test('an ordinary correction only moves the clock', () {
      final (on, off) = correctedSleepWindow(
        DateTime(2026, 3, 1, 23, 7),
        DateTime(2026, 3, 2, 7, 5),
        const TimeOfDay(hour: 22, minute: 45),
        const TimeOfDay(hour: 6, minute: 30),
      );
      expect(on, DateTime(2026, 3, 1, 22, 45));
      expect(off, DateTime(2026, 3, 2, 6, 30));
    });

    test('a wake moved far later on a truncated night lands the same day', () {
      final (on, off) = correctedSleepWindow(
        DateTime(2026, 3, 2, 0, 30),
        DateTime(2026, 3, 2, 1, 0),
        const TimeOfDay(hour: 0, minute: 30),
        const TimeOfDay(hour: 13, minute: 30),
      );
      expect(on, DateTime(2026, 3, 2, 0, 30));
      expect(off, DateTime(2026, 3, 2, 13, 30));
    });
  });

  group('a device\'s own staging, beside ours', () {
    Map<String, Object?> deviceNight(String id, String label, String family,
            Map<String, int> minutes) =>
        {
          'device_id': id,
          'label': label,
          'family': family,
          'onset_ts': _onset,
          'wake_ts': _onset + 480 * 60,
          'duration_min': 460,
          'stage_min': minutes,
          'hypnogram': [
            {'t': _onset, 'stage': 'light'},
            {'t': _onset + 3600, 'stage': 'deep'},
            {'t': _onset + 480 * 60, 'stage': 'deep'},
          ],
        };

    testWidgets('a switcher offers OpenStrap and each device; picking one '
        'says whose staging it is and what it cannot report', (t) async {
      await _pump(
        t,
        SleepData(
          day: '2026-05-20',
          night: _night(),
          deviceNights: [
            deviceNight('mb-1', 'Mi Band', 'miband234',
                {'light': 400, 'deep': 60, 'wake': 20}),
            deviceNight('cm-1', 'Colmi ring', 'colmi',
                {'light': 250, 'deep': 100, 'rem': 110, 'wake': 20}),
          ],
        ),
      );
      expect(find.text('OpenStrap'), findsOneWidget);
      expect(find.text('Mi Band'), findsOneWidget);
      expect(find.text('Colmi ring'), findsOneWidget);
      expect(find.textContaining('Staged by'), findsNothing,
          reason: 'ours is the default view');

      await t.tap(find.text('Mi Band'));
      await t.pumpAndSettle();
      expect(find.text('Staged by Mi Band'), findsOneWidget);
      expect(find.textContaining('Deep 1h'), findsOneWidget);
      expect(find.textContaining('does not report REM'), findsOneWidget);

      // The pill row scrolls sideways; bring the last pill into view first.
      await t.ensureVisible(find.text('Colmi ring'));
      await t.pumpAndSettle();
      await t.tap(find.text('Colmi ring'));
      await t.pumpAndSettle();
      expect(find.text('Staged by Colmi ring'), findsOneWidget);
      expect(find.textContaining('does not report'), findsNothing);

      await t.ensureVisible(find.text('OpenStrap'));
      await t.pumpAndSettle();
      await t.tap(find.text('OpenStrap'));
      await t.pumpAndSettle();
      expect(find.textContaining('Staged by'), findsNothing);
    });

    testWidgets('no device night means no switcher', (t) async {
      await _pump(t, SleepData(day: '2026-05-20', night: _night()));
      expect(find.text('OpenStrap'), findsNothing);
    });
  });

  testWidgets("a band that folds REM into light: its light and deep show, "
      "and no REM row of 0", (t) async {
    final n = _night()..['rem_min'] = null;
    n['hypnogram'] = [
      for (final p in n['hypnogram'] as List)
        if ((p as Map)['stage'] != 'rem') p,
    ];
    await _pump(t, SleepData(day: '2026-05-20', night: _night()));
    final light = find.text('Light').evaluate().length;
    final deep = find.text('Deep').evaluate().length;
    await t.pumpWidget(const SizedBox());
    await _pump(t, SleepData(day: '2026-05-20', night: n));
    expect(find.text('Light').evaluate().length, light);
    expect(find.text('Deep').evaluate().length, deep);
    expect(find.text('REM'), findsNothing);
  });
}
