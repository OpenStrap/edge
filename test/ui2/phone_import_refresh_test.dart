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
}
