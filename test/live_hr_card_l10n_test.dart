// LiveHrCard's empty states and trace caption must follow the app locale.
// StatusCard only translates strings its lookup tables already know, so a
// raw English literal here showed an English card on a translated screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget _page(AppState app, Locale locale, Widget child) =>
    ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

void main() {
  const english = [
    'No live reading',
    'No band is paired.',
    'Pair one from Profile to read live beats.',
  ];

  for (final code in ['de', 'ru', 'zh']) {
    testWidgets('unpaired empty state is translated ($code)', (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final l = lookupAppLocalizations(Locale(code));

      await t.pumpWidget(_page(app, Locale(code), const LiveHrCard()));
      await t.pumpAndSettle();

      for (final s in english) {
        expect(find.textContaining(s), findsNothing, reason: s);
      }
      expect(find.textContaining(l.liveHrNoReadingTitle), findsWidgets);
      expect(find.textContaining(l.liveHrNotPairedWhy), findsWidgets);
    });

    testWidgets('trace caption is translated ($code)', (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      final l = lookupAppLocalizations(Locale(code));

      await t.pumpWidget(_page(
        app,
        Locale(code),
        const LiveHrCard.preview(hr: 64, trace: [60, 62, 64, 66]),
      ));
      await t.pumpAndSettle();

      expect(find.textContaining('Not stored'), findsNothing);
      expect(find.text(l.liveHrTraceCaption(4, 60, 66)), findsOneWidget);
    });
  }

  test('every locale carries the live HR strings', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      final en = lookupAppLocalizations(const Locale('en'));
      if (locale.languageCode == 'en') continue;
      expect(l.liveHrNoReadingTitle, isNot(en.liveHrNoReadingTitle),
          reason: locale.toString());
      expect(l.liveHrNoRecentBeatWhy(30), contains('30'));
    }
  });
}
