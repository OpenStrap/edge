// German capitalises nouns. The blank-metric title used to lowercase the row
// name for every locale, so a German user read "Kein Wert: ruhepuls".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Repo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() async => const {
        'status': {'today_day': '2026-08-16'}
      };

  @override
  Future<List<String>> availableDays() async => const ['2026-08-16'];
}

Future<void> _pump(WidgetTester t, Locale locale) async {
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = _Repo();
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ChangeNotifierProvider<AppState>.value(
      value: app,
      child: const Scaffold(body: HealthScreen()),
    ),
  ));
  for (var i = 0; i < 20; i++) {
    await t.pump();
  }
}

void main() {
  testWidgets('german keeps the noun case in the blank-metric title',
      (t) async {
    t.view.physicalSize = const Size(800 * 3, 4000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await _pump(t, const Locale('de'));
    expect(find.text('Kein Wert: Ruhepuls'), findsOneWidget);
    expect(find.text('Kein Wert: ruhepuls'), findsNothing);
  });

  testWidgets('english still lowercases it', (t) async {
    t.view.physicalSize = const Size(800 * 3, 4000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await _pump(t, const Locale('en'));
    expect(find.text('No resting heart rate'), findsOneWidget);
  });
}
