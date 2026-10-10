// The tab bar speaks the user's language, visibly and to a screen reader.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _pump(WidgetTester tester, Locale locale) =>
    tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppShell(builder: (c, d) => const SizedBox.shrink()),
    ));

void main() {
  testWidgets('a German user gets a German tab bar', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, const Locale('de'));
    await tester.pumpAndSettle();
    for (final de in ['Heute', 'Schlaf', 'Aktivität', 'Gesundheit']) {
      expect(find.text(de), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^${RegExp.escape(de)}')),
          findsWidgets);
    }
    expect(find.text('Today'), findsNothing);
    expect(find.text('Activity'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Today|Activity')), findsNothing);
    semantics.dispose();
  });

  testWidgets('no two tabs share a label in any locale', (tester) async {
    for (final locale in AppLocalizations.supportedLocales) {
      await _pump(tester, locale);
      await tester.pumpAndSettle();
      final c = tester.element(find.byType(AppShell));
      final labels = ShellDomain.values.map((d) => d.title(c)).toList();
      expect(labels.toSet().length, ShellDomain.values.length,
          reason: '$locale: $labels');
    }
  });
}
