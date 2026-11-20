// The screen's re-read of the db must not throw out of _refresh: _run awaits
// it in its finally, and a throw there left _busy (every button off) stuck.
// No db is opened in a widget test, so the re-read fails here for real.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/profile/phone_import.dart';

void main() {
  testWidgets('a failed refresh does not escape and leaves buttons live',
      (t) async {
    await t.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PhoneImport(),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(t.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('_run clears busy when the job and the refresh both fail',
      (t) async {
    await t.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PhoneImport(),
    ));
    await t.pump(const Duration(milliseconds: 50));
    final btn = find.text('Read resting heart rate');
    await t.ensureVisible(btn);
    await t.tap(btn);
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // Buttons are live again: a second tap starts another run.
    await t.tap(btn);
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
