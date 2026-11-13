// The language picker used to overflow its bottom sheet (capped at 9/16 of the
// screen) once the list grew past what fits. It must lay out without an
// overflow on a short screen, and every language must stay reachable.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  testWidgets('language sheet scrolls on a short screen and selects the last language',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final ctrl = LocaleController.seed(null);
    await tester.pumpWidget(ChangeNotifierProvider<LocaleController>.value(
      value: ctrl,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ProfileHomeView(stats: ProfileStats(name: 'Sahil')),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('System default').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'sheet must not overflow');

    final last = find.text('中文');
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    await tester.tap(last);
    await tester.pumpAndSettle();

    expect(ctrl.code, 'zh');
    expect(find.text('Deutsch'), findsNothing, reason: 'sheet should be dismissed');
  });
}
