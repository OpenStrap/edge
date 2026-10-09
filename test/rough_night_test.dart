// The two things about the rough-night card that must not regress: the gate
// that decides a night is worth saying anything about, and the fact that
// nobody meets the tag vocabulary before asking for it.
//
// The series below are the REAL 17-day export, `metric_series` verbatim. It is
// the only honest calibration available: the gate fires zero times on it, and a
// change that makes this file's first test fail has loosened a gate that exists
// to stop the app guessing at somebody's night.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/grammar.dart';
import 'package:openstrap_edge/ui2/screens/rough_night.dart';
import 'package:openstrap_edge/ui2/theme.dart';

/// The longest state the card can reach: every sign fired, every knowable
/// known, the full chip vocabulary. The fixtures here are deliberately the
/// longest realistic value, never the tidiest — the same rule the gallery runs.
const _longest = RoughNight(
  day: '2026-08-15',
  signs: 4,
  descriptor:
      'a rougher night than usual for you — your body worked harder overnight',
  moved: [
    'your resting heart rate ran higher',
    'your HRV ran lower',
    'your heart rate dropped less overnight than it usually does',
    'your skin ran warmer',
  ],
  knows: [
    'You trained until 9:40 PM, which often does this on its own.',
    'You are in the luteal phase, which lifts resting heart rate and skin '
        'temperature by itself.',
    'Your skin ran warmer than your usual — a warm room does this too.',
  ],
);

/// Real nights: date → (rhr, rmssd, dip_pct, skin_temp_z). A null is a night
/// the pipeline published no value for, and it stays out of the window rather
/// than being filled.
const _export = <String, (double?, double?, double?, double?)>{
  '2026-07-31': (87.951, null, null, null),
  '2026-08-01': (59.348, 58.865, 29.673, null),
  '2026-08-02': (58.076, 56.787, 33.307, null),
  '2026-08-03': (59.750, 67.404, 32.191, null),
  '2026-08-04': (62.925, 44.420, 26.027, -0.756),
  '2026-08-05': (55.673, 62.682, 28.890, -0.263),
  '2026-08-06': (56.728, 54.581, 27.980, -1.255),
  '2026-08-07': (78.291, null, null, null),
  '2026-08-08': (57.858, 56.651, 29.096, 0.082),
  '2026-08-09': (56.921, 71.737, 36.840, 0.069),
  '2026-08-10': (61.098, 46.023, 20.444, 0.176),
  '2026-08-11': (56.275, 58.757, 31.162, -0.157),
  '2026-08-12': (60.797, 51.680, 26.719, 0.014),
  '2026-08-13': (56.842, 55.476, 34.859, 0.335),
  '2026-08-14': (61.425, 41.187, 30.354, -0.951),
  '2026-08-15': (64.231, 43.103, 20.653, 0.147),
};

Map<String, Map<String, double>> _series([
  Map<String, (double?, double?, double?, double?)> src = _export,
]) {
  final out = {
    'rhr': <String, double>{},
    'rmssd': <String, double>{},
    'dip_pct': <String, double>{},
    'skin_temp_z': <String, double>{},
  };
  src.forEach((d, v) {
    if (v.$1 != null) out['rhr']![d] = v.$1!;
    if (v.$2 != null) out['rmssd']![d] = v.$2!;
    if (v.$3 != null) out['dip_pct']![d] = v.$3!;
    if (v.$4 != null) out['skin_temp_z']![d] = v.$4!;
  });
  return out;
}

void main() {
  group('late training', () {
    int sec(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
    Map<String, Object?> session(DateTime from, DateTime to) =>
        {'start_ts': sec(from), 'end_ts': sec(to)};

    test('only the evening before the night counts', () {
      final latest = lateTrainingEnd('2026-08-15', [
        // The evening before: this is the one that ran into the night.
        session(DateTime(2026, 8, 14, 20), DateTime(2026, 8, 14, 21, 10)),
        // This evening, hours after the night ended. Never its cause.
        session(DateTime(2026, 8, 15, 18, 30), DateTime(2026, 8, 15, 19, 40)),
      ]);
      expect(latest, DateTime(2026, 8, 14, 21, 10));
    });

    test('an early session the day before is not late', () {
      expect(
        lateTrainingEnd('2026-08-15', [
          session(DateTime(2026, 8, 14, 7), DateTime(2026, 8, 14, 8)),
        ]),
        isNull,
      );
    });

    test('a session that ran past midnight still counts', () {
      expect(
        lateTrainingEnd('2026-08-15', [
          session(DateTime(2026, 8, 14, 23, 30), DateTime(2026, 8, 15, 0, 20)),
        ]),
        DateTime(2026, 8, 15, 0, 20),
      );
    });
  });

  group('the gate', () {
    test('never fires on 17 days of the real export', () {
      final s = _series();
      final fired = <String>[];
      var decidable = 0;
      for (final day in _export.keys) {
        final r = roughNightSignCount(day, s);
        if (r == null) continue;
        decidable++;
        if (r.signs >= 2) fired.add(day);
      }
      // Seven nights had enough of the user's own record behind them to be
      // judged at all; none of them cleared two signs. If this ever fails,
      // read the MDC gate before "fixing" the number.
      expect(decidable, 7);
      expect(fired, isEmpty);
    });

    test('a short record is undecidable, never quiet', () {
      // Before the floor there is no state — and specifically not "signs: 0",
      // which would read as a night that was checked and found ordinary.
      expect(roughNightSignCount('2026-08-08', _series()), isNull);
    });

    test('a night whose baseline is one flat value cannot fire', () {
      // MAD is zero, so there is no minimal detectable change and therefore no
      // honest claim, however far tonight sits from the centre.
      final flat = {
        for (var i = 1; i <= 9; i++)
          '2026-09-0$i': (60.0, 50.0, 30.0, null as double?),
      }..['2026-09-10'] = (110.0, 5.0, 2.0, null);
      final r = roughNightSignCount('2026-09-10', _series(flat));
      expect(r?.signs, 0);
    });

    test('fires on a night that moved past its own detectable change', () {
      // The same flat window with a little real spread in it, so an MDC exists.
      final src = <String, (double?, double?, double?, double?)>{
        for (var i = 1; i <= 9; i++)
          '2026-09-0$i': (58.0 + i % 3, 50.0 - i % 4, 30.0 + i % 3, null),
      };
      src['2026-09-10'] = (75.0, 20.0, 30.0, null);
      final r = roughNightSignCount('2026-09-10', _series(src));
      expect(r, isNotNull);
      expect(r!.signs, greaterThanOrEqualTo(2));
      expect(r.moved, contains('your resting heart rate ran higher'));
      expect(r.moved, contains('your HRV ran lower'));
    });

    test('tonight is never inside its own baseline window', () {
      // A night included in the window it is measured against drags the median
      // toward itself and can never look unusual. Dropping the day from the
      // series entirely must not change the other nights' verdicts.
      final s = _series();
      final before = roughNightSignCount('2026-08-15', s)!.signs;
      s.forEach((_, m) => m.remove('2026-08-15'));
      s['rhr']!['2026-08-15'] = 64.231;
      s['rmssd']!['2026-08-15'] = 43.103;
      expect(roughNightSignCount('2026-08-15', s)!.signs, before);
    });
  });

  group('what the card says', () {
    const night = RoughNight(
      day: '2026-08-15',
      signs: 2,
      descriptor: 'a rougher night than usual for you — your body worked '
          'harder overnight',
      moved: ['your resting heart rate ran higher', 'your HRV ran lower'],
      knows: ['You trained until 9:40 PM, which often does this on its own.'],
    );

    Future<void> pump(WidgetTester t, Widget w) => t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: SingleChildScrollView(child: w)),
    ));

    testWidgets('offers no tag vocabulary until it is asked for', (t) async {
      await pump(t, const RoughNightCard(night: night, ask: 'unset'));
      // THE test. Every other assertion in this file is arithmetic; this one is
      // the product decision. A card that names alcohol unasked is the thing
      // the analytics refusal is about, and neutral phrasing does not fix it.
      expect(find.text('alcohol'), findsNothing);
      expect(find.text('caffeine'), findsNothing);
      expect(find.text('Tell it what happened'), findsOneWidget);
    });

    testWidgets('states what it knows instead of asking it', (t) async {
      await pump(t, const RoughNightCard(night: night, ask: 'on'));
      expect(
        find.text(
          'You trained until 9:40 PM, which often does this on its own.',
        ),
        findsOneWidget,
      );
      expect(find.text('alcohol'), findsOneWidget);
      // Never pre-selected, and never the headline.
      expect(find.text('Anything else?'), findsOneWidget);
    });

    testWidgets('declining ends the question for good', (t) async {
      await pump(t, const RoughNightCard(night: night, ask: 'never'));
      expect(find.text('alcohol'), findsNothing);
      expect(find.text('Tell it what happened'), findsNothing);
    });

    // The gallery sweeps cover this too, once every case in it compiles. This
    // one is here because the card's own longest state — four moved
    // measurements, four knowns, thirteen chips — is the thing worth pinning to
    // the file it lives in.
    for (final scale in const [1.0, 2.0, 3.1]) {
      testWidgets('nothing overflows at ${scale}x', (t) async {
        t.view.physicalSize = const Size(390 * 3, 6000 * 3);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        final errors = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.exceptionAsString());
        await t.pumpWidget(MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: RoughNightCard(night: _longest, ask: 'on'),
                ),
              ),
            ),
          ),
        ));
        await t.pump();
        FlutterError.onError = previous;
        expect(errors.where((e) => e.contains('overflowed')), isEmpty);
      });
    }

    testWidgets('every control clears 44 pt', (t) async {
      t.view.physicalSize = const Size(390 * 3, 6000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await pump(t, const RoughNightCard(night: _longest, ask: 'on'));
      final small = <String>[];
      for (final w in t.widgetList<Pressable>(find.byType(Pressable))) {
        if (w.onTap == null) continue;
        final s = t.getSize(find.byWidget(w));
        if (s.height < S.tap || s.width < S.tap) {
          small.add('${w.semanticLabel ?? 'unlabelled'} ${s.width}x${s.height}');
        }
      }
      expect(small, isEmpty, reason: small.join('\n'));
    });

    testWidgets('drops the illness tag once the illness watch answered it',
        (t) async {
      const flagged = RoughNight(
        day: '2026-08-15',
        signs: 2,
        descriptor: 'a rougher night than usual for you — x',
        moved: ['your HRV ran lower'],
        knows: ['Your resting heart rate flagged this night too — a rise.'],
        illnessFlagged: true,
      );
      expect(flagged.ask, isNot(contains('sick')));
      // And the one it never offers on any night: the card IS the sleep
      // measurement, so asking the user to confirm it grades the sensor.
      expect(night.ask, isNot(contains('poor sleep')));
      await pump(t, const RoughNightCard(night: flagged, ask: 'on'));
      expect(find.text('sick'), findsNothing);
    });
  });
}
