// The poster's elevation caption is built in the user's units, so an imperial
// "+394 ft elevation" has to be translated just like the metric one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/activity/share.dart'
    show localizedExportCaption;
import 'package:openstrap_edge/ui2/activity/summary.dart';

void main() {
  testWidgets('both elevation units are translated', (tester) async {
    final r = ActivityResult(
      allActivities.first,
      start: DateTime(2026, 5, 20, 7, 15),
      duration: const Duration(minutes: 45),
    );
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));
    expect(localizedExportCaption(ctx, r, '+120 m elevation'), '+120 м высоты');
    expect(localizedExportCaption(ctx, r, '+394 ft elevation'),
        '+394 фт высоты');
  });
}
