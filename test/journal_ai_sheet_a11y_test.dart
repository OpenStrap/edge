// The journal AI sheet's send control is an arrow icon with no text, so
// without a label a screen reader announced it as a bare "button". Its
// primary "Add to journal" button was a raw English literal, so it stayed
// English under a translated chat.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/journal_compose.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _ReadyCoach extends CoachConfig {
  @override
  bool get configured => true;
}

Future<void> _openSheet(WidgetTester t, Locale locale) async {
  // Wide enough that the test font's square glyphs don't overflow the
  // compose screen's Russian row labels, which is not what this checks.
  t.view.physicalSize = const Size(900 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);

  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: AppState.forTesting()),
        ChangeNotifierProvider<CoachConfig>.value(value: _ReadyCoach()),
      ],
      child: const Scaffold(body: JournalCompose(date: '2026-09-01')),
    ),
  ));
  await t.pumpAndSettle();
  // The entry link is localized, so tap it in the locale under test.
  await t.tap(find.text(
      lookupAppLocalizations(locale).journalComposeTalkItThroughWithAi));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('send control has a screen-reader name', (t) async {
    final handle = t.ensureSemantics();
    await _openSheet(t, const Locale('en'));
    expect(
      find.bySemanticsLabel('Send'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('send label and Add to journal follow the locale', (t) async {
    final handle = t.ensureSemantics();
    await _openSheet(t, const Locale('ru'));
    expect(find.bySemanticsLabel('Отправить'), findsOneWidget);
    expect(find.text('Add to journal'), findsNothing);
    expect(find.text('Добавить в дневник'), findsOneWidget);
    handle.dispose();
  });
}
