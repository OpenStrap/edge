// Investigate's "nothing stored yet" line put the metric name through a bare
// toLowerCase(), so English read "Nothing stored for rem sleep yet." and German
// "Für ruhepuls ist noch nichts gespeichert." It now goes through
// nounInSentence, the same rule the Health rows and the metric detail use.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _pump(WidgetTester t, String key, {Locale? locale}) async {
  t.view.physicalSize = const Size(390 * 3, 3000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Investigate(key,
        data: InvestigateData(day: todayLabel(), series: const [])),
  ));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('english lowercases a name but keeps an acronym', (t) async {
    await _pump(t, 'resting_hr', locale: const Locale('en'));
    expect(find.text('Nothing stored for resting heart rate yet.'),
        findsOneWidget);

    await _pump(t, 'rem', locale: const Locale('en'));
    expect(find.text('Nothing stored for REM sleep yet.'), findsOneWidget);
    expect(find.text('Nothing stored for rem sleep yet.'), findsNothing);
  });

  testWidgets('german keeps the noun case', (t) async {
    await _pump(t, 'resting_hr', locale: const Locale('de'));
    expect(find.text('Für Ruhepuls ist noch nichts gespeichert.'),
        findsOneWidget);
    expect(find.text('Für ruhepuls ist noch nichts gespeichert.'),
        findsNothing);
  });
}
