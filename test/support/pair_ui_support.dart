// Shared harness for the pairing screens' widget tests: real theme, real
// localizations, a phone-sized view, no BLE.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> pumpPair(
  WidgetTester t,
  Widget home, {
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  Size size = const Size(412, 915),
  bool settle = true,
  Widget Function(Widget)? wrap,
}) async {
  t.view.physicalSize = size * 2;
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  final app = MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: locale,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(brightness),
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: home,
  );
  await t.pumpWidget(wrap?.call(app) ?? app);
  if (settle) {
    await t.pumpAndSettle();
  } else {
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }
}
