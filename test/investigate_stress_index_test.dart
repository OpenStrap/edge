// Stress Nerd Stats shows the Baevsky index behind the score. The 0-100 score
// is clamped at both ends, so a night whose index sits below the scale's floor
// reads 0 with nothing on screen to say why; the index and level are the
// unclamped facts. They come from the day bundle, not a stored series.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

String _today() {
  final n = DateTime.now();
  return dayLabelOf(DateTime(n.year, n.month, n.day));
}

Future<void> _pump(WidgetTester t, InvestigateData data,
    {Locale? locale}) async {
  t.view.physicalSize = const Size(390 * 3, 3000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Investigate('stress', data: data),
  ));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('a score clamped to 0 still shows the index and level behind it',
      (t) async {
    await _pump(
      t,
      InvestigateData(day: _today(), series: const [0.0], stress: const {
        'si': 12.5,
        'level': 'low',
        'score': 0.0,
      }),
    );
    expect(find.text('STRESS INDEX'), findsOneWidget);
    expect(find.text('12.50'), findsOneWidget, reason: 'the index, to the 2 dp it is stored at');
    expect(find.text('low'), findsOneWidget, reason: 'the level');
    expect(find.text('0.0'), findsOneWidget, reason: 'the clamped score');
  });

  testWidgets('a night with no stress block draws no table of dashes',
      (t) async {
    await _pump(t, InvestigateData(day: _today(), series: const [0.0]));
    expect(find.text('STRESS INDEX'), findsNothing);
  });

  testWidgets('an absent score is a missing row, never a zero', (t) async {
    await _pump(
      t,
      InvestigateData(
          day: _today(),
          series: const [3.0],
          stress: const {'si': 12.5, 'level': 'low', 'score': null}),
    );
    expect(find.text('STRESS INDEX'), findsOneWidget);
    expect(find.text('12.50'), findsOneWidget);
    expect(find.text('Score (0–100)'), findsNothing,
        reason: 'MonoTable drops a row with no value');
    expect(find.text('0.0'), findsNothing);
  });

  testWidgets('a non-finite value is absent, not "NaN" or "Infinity"',
      (t) async {
    await _pump(
      t,
      InvestigateData(day: _today(), series: const [12.5], stress: {
        'si': 12.5,
        'level': 'low',
        'score': double.nan,
      }),
    );
    expect(find.text('NaN'), findsNothing);
    expect(find.text('Score (0–100)'), findsNothing);
  });

  testWidgets('the table and its level word follow the locale', (t) async {
    await _pump(
      t,
      InvestigateData(day: _today(), series: const [0.0], stress: const {
        'si': 12.5,
        'level': 'low',
        'score': 0.0,
      }),
      locale: const Locale('de'),
    );
    expect(find.text('STRESSINDEX'), findsOneWidget);
    expect(find.text('niedrig'), findsOneWidget);
    expect(find.text('Stress index'), findsNothing);
  });

  testWidgets('a level that is not a string is absent, not a crash', (t) async {
    await _pump(
      t,
      InvestigateData(day: _today(), series: const [12.5], stress: const {
        'si': 12.5,
        'level': 7,
        'score': 3.0,
      }),
    );
    expect(find.text('STRESS INDEX'), findsOneWidget);
    expect(find.text('Level'), findsNothing);
  });

  testWidgets('a small positive index is not shown as zero', (t) async {
    await _pump(
      t,
      InvestigateData(
          day: _today(),
          series: const [0.0],
          stress: const {'si': 0.04, 'level': 'low'}),
    );
    expect(find.text('0.04'), findsOneWidget);
  });

  testWidgets('a level with no index behind it draws no table', (t) async {
    await _pump(
      t,
      InvestigateData(
          day: _today(),
          series: const [3.0],
          stress: const {'level': 'moderate', 'score': null}),
    );
    expect(find.text('STRESS INDEX'), findsNothing);
    expect(find.text('moderate'), findsNothing);
  });

  testWidgets('an unknown level token is absent, not shown raw', (t) async {
    await _pump(
      t,
      InvestigateData(
          day: _today(),
          series: const [3.0],
          stress: const {'si': 12.5, 'level': 'moderate', 'score': 5.0}),
    );
    expect(find.text('STRESS INDEX'), findsOneWidget);
    expect(find.text('moderate'), findsNothing);
    expect(find.text('Level'), findsNothing);
  });

  group('stressBlockOf', () {
    test('returns the block of the bundle it is given', () {
      expect(
          stressBlockOf({
            'stress': {'si': 12.5, 'score': null},
            'scalars': {'stress': 99.0},
          }),
          {'si': 12.5, 'score': null},
          reason: 'only the block itself; no other field stands in for a '
              'missing value');
    });

    test('is empty when there is no stress block', () {
      expect(stressBlockOf(null), isEmpty);
      expect(stressBlockOf({'stress': 'x'}), isEmpty);
      expect(stressBlockOf(const {}), isEmpty);
    });
  });
}
