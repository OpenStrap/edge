// THE DAY STEPS SCREEN — the spans, and the one line about the sensors.
//
// Three things this screen may not get wrong, all of them honesty rather than
// layout:
//   * a stretch names the device that counted it, and never the wrong one;
//   * the accuracy line appears ONCE and says the right thing for the sensors
//     that actually counted — a day the phone carried alone must not be told
//     about wrists;
//   * a day whose count came off the strap's on-chip counter has no times
//     behind it, and must say THAT rather than "no steps" over a tile showing
//     thousands.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/ui2/screens/day_steps.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// Local 09:00 on an arbitrary day, as epoch seconds.
final _nine = DateTime(2026, 8, 17, 9).millisecondsSinceEpoch ~/ 1000;

DayStepSpan _span(
  int fromMin,
  int toMin,
  int steps, {
  bool band = false,
  String? activity,
}) => DayStepSpan(
  startTs: _nine + fromMin * 60,
  endTs: _nine + toMin * 60,
  steps: steps,
  fromBand: band,
  activity: activity,
);

/// An app state whose pairing a test can swap, the way an unpair or a re-pair
/// does, and announce.
class _Paired extends AppState {
  _Paired() : super.forTesting();

  void pair(String? generation) {
    paired = generation == null
        ? null
        : PairedDevice('remote', 'SN1', generation: generation);
    notifyListeners();
  }
}

Future<void> _pump(
  WidgetTester t,
  DayStepsData d, {
  double scale = 1,
  AppState? app,
}) async {
  t.view.physicalSize = Size(390 * 3, 3000 * 3 * scale);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final screen = MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: DayStepsDetail(data: d),
    ),
  );
  await t.pumpWidget(
    app == null
        ? screen
        : ChangeNotifierProvider<AppState>.value(value: app, child: screen),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('a mixed day names both devices, and the walk it watched', (
    t,
  ) async {
    await _pump(
      t,
      DayStepsData(
        spans: [
          _span(0, 60, 1200),
          _span(240, 300, 3240, band: true, activity: 'walking'),
        ],
        total: 4440,
        strap: 3240,
        phone: 1200,
        bandLabel: 'WHOOP 4',
      ),
    );
    // The owner's own example: a 13:00–14:00 activity counted by the strap and
    // a passively-counted stretch from the phone, on one screen, each naming
    // its device.
    expect(find.textContaining('1:00 PM – 2:00 PM'), findsOneWidget);
    expect(find.textContaining('WHOOP 4 · Walking'), findsOneWidget);
    expect(find.textContaining('9:00 AM – 10:00 AM'), findsOneWidget);
    expect(find.text('Your phone'), findsWidgets);
    // ONE accuracy line, and it names both failure directions.
    expect(find.textContaining('A wrist can read a walk low'), findsOneWidget);
  });

  testWidgets('a phone-only day is never told about wrists', (t) async {
    await _pump(
      t,
      DayStepsData(spans: [_span(0, 60, 1200)], total: 1200, phone: 1200),
    );
    expect(find.textContaining('had it on you for'), findsOneWidget);
    expect(find.textContaining('wrist'), findsNothing);
    // One sensor is not a legend.
    expect(find.text('WHOOP 4'), findsNothing);
  });

  testWidgets('with a WHOOP 4.0 paired, a phone-only day says why the band '
      'added nothing', (t) async {
    await _pump(
      t,
      DayStepsData(
        spans: [_span(0, 60, 1200)],
        total: 1200,
        phone: 1200,
        bandHasNoCounter: true,
      ),
    );
    expect(find.textContaining('had it on you for'), findsOneWidget);
    expect(
      find.textContaining('A WHOOP 4.0 has no step counter'),
      findsOneWidget,
    );
  });

  testWidgets('with a WHOOP 4.0 paired, a day with no steps says why', (
    t,
  ) async {
    await _pump(t, const DayStepsData(bandHasNoCounter: true));
    expect(find.textContaining('No steps counted'), findsOneWidget);
    expect(
      find.textContaining('A WHOOP 4.0 has no step counter'),
      findsOneWidget,
    );
  });

  testWidgets('the WHOOP 4.0 hint follows the band the app has paired', (
    t,
  ) async {
    // The day loaded with no hint; the live pairing decides.
    SharedPreferences.setMockInitialValues({});
    final app = _Paired()..pair('gen4');
    addTearDown(app.dispose);
    await _pump(
      t,
      DayStepsData(spans: [_span(0, 60, 1200)], total: 1200, phone: 1200),
      app: app,
    );
    const hint = 'A WHOOP 4.0 has no step counter';
    expect(find.textContaining(hint), findsOneWidget);

    app.pair('gen5');
    await t.pumpAndSettle();
    expect(find.textContaining(hint), findsNothing, reason: 'a 5.0 counts');

    app.pair('gen4');
    await t.pumpAndSettle();
    expect(find.textContaining(hint), findsOneWidget);

    app.pair(null);
    await t.pumpAndSettle();
    expect(find.textContaining(hint), findsNothing, reason: 'unpaired');
  });

  testWidgets('the WHOOP 4.0 hint never shows on a day the band counted, or '
      'for another band', (t) async {
    // The band counted: it evidently can, so the hint would be wrong.
    await _pump(
      t,
      DayStepsData(
        spans: [_span(240, 300, 3240, band: true)],
        total: 3240,
        strap: 3240,
        bandLabel: 'WHOOP 4',
        bandHasNoCounter: true,
      ),
    );
    expect(find.textContaining('has no step counter'), findsNothing);
    // A band with its own counter (or none paired): never mentioned.
    await _pump(
      t,
      DayStepsData(spans: [_span(0, 60, 1200)], total: 1200, phone: 1200),
    );
    expect(find.textContaining('has no step counter'), findsNothing);
    // An older day a WHOOP 5.0's own counter published, viewed with a WHOOP
    // 4.0 paired now: that band could count, so the hint would be false.
    await _pump(
      t,
      DayStepsData(
        spans: [_span(0, 60, 1200)],
        total: 1200,
        phone: 1200,
        dayTotal: 6012,
        daySource: 'strap_counter',
        bandHasNoCounter: true,
      ),
    );
    expect(find.textContaining('has no step counter'), findsNothing);
  });

  test('the no-counter hint follows the live band, not the day it loaded', () {
    expect(generationHasNoCounter('gen4'), isTrue);
    expect(generationHasNoCounter('gen5'), isFalse);
    expect(generationHasNoCounter(null), isFalse);
    // Unpaired since the day loaded: the live answer wins.
    expect(bandStillHasNoCounter(true, false), isFalse);
    // Paired since: likewise.
    expect(bandStillHasNoCounter(false, true), isTrue);
    // No app state to ask: what the day loaded with.
    expect(bandStillHasNoCounter(true, null), isTrue);
    expect(bandStillHasNoCounter(false, null), isFalse);
  });

  testWidgets('a day counted only by the strap\'s on-chip counter says the '
      'TIMES are missing, not the steps', (t) async {
    await _pump(
      t,
      const DayStepsData(dayTotal: 6012, daySource: 'strap_counter'),
    );
    expect(find.textContaining('No times behind'), findsOneWidget);
    expect(find.textContaining('6,012'), findsOneWidget);
    expect(find.textContaining('No steps counted'), findsNothing);
  });

  testWidgets('every stretch survives 3.1x text', (t) async {
    // The pump itself is the assertion: a `RenderFlex` overflow fails it. A
    // clock range is a long row name, and the row shipped its steps unit off
    // the right edge at this scale before it was removed.
    await _pump(
      t,
      DayStepsData(
        spans: [
          _span(0, 60, 1200),
          _span(240, 300, 3240, band: true, activity: 'walking'),
        ],
        total: 4440,
        strap: 3240,
        phone: 1200,
        bandLabel: 'WHOOP 4',
      ),
      scale: 3.1,
    );
  });

  test('contiguous hours from one sensor read as one stretch — but never '
      'across a gap, and never across the other sensor', () {
    // whoop-4.db, 2026-08-13, exactly as the table holds it: hourly phone rows
    // with an 11:00 gap, and the strap's run spans landing inside 17:00–19:00.
    final rows = [
      _span(0, 60, 892), // 09:00–10:00  (the fixture's clock, not the day's)
      _span(60, 120, 9),
      _span(120, 180, 1012),
      _span(240, 300, 228), // one hour missing before this one
      _span(480, 540, 1649),
      _span(532, 534, 51, band: true),
      _span(534, 540, 737, band: true, activity: 'run'),
      _span(540, 600, 5753),
      _span(541, 544, 352, band: true, activity: 'run'),
      _span(600, 660, 214),
      _span(660, 720, 2074),
    ];
    final merged = mergeAdjacent(rows);
    expect(merged.map((s) => (s.startTs - _nine, s.endTs - _nine, s.steps)), [
      (0, 180 * 60, 1913), // three contiguous phone hours, joined
      (240 * 60, 300 * 60, 228), // the gap kept it separate
      (480 * 60, 540 * 60, 1649), // a band stretch starts inside the next
      (532 * 60, 534 * 60, 51),
      (534 * 60, 540 * 60, 737),
      (540 * 60, 600 * 60, 5753),
      (541 * 60, 544 * 60, 352),
      (600 * 60, 720 * 60, 2288),
    ]);
  });

  test('an hour gets one bar, in the colour of the sensor that counted most '
      'of it', () {
    // 09:00–10:00 phone (600), with a strap walk 09:10–09:40 (900) inside it.
    final (band, phone) = hourlySteps([
      _span(0, 60, 600),
      _span(10, 40, 900, band: true),
    ]);
    expect(
      band[9],
      closeTo(1500, .5),
      reason: 'the hour still shows every step counted in it',
    );
    expect(
      phone[9],
      isNull,
      reason: 'two bars would hide one behind the other',
    );
    expect(band[10], isNull, reason: 'an uncovered hour is a hole, not a zero');
  });
}
