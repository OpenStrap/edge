import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/app.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/theme/theme_switcher.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';

import 'backup_support.dart';

void main() {
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_presentation_test.db'));
  tearDownAll(() async => env.dispose());

  testWidgets('an import updates the app root and live presentation controllers',
      (tester) async {
    late String path;
    await tester.runAsync(() async {
      await env.wipe();
      FlutterSecureStorage.setMockInitialValues({});
      await setPrefs({'theme_choice': 'dark', 'locale_override': 'es',
        'units_system': 'imperial', 'clock_format': 'h12',
        'local_profile_json': '{"name":"Restored"}'});
      path = await LocalDb.exportCopy();
      await env.wipe();
    });
    final app = AppState.forTesting();
    final theme = ThemeController.seed(AppThemeChoice.light, Brightness.light);
    final locale = LocaleController.seed(null);
    final units = UnitsController.seed(UnitSystem.metric);
    final clock = ClockFormatController.seed(ClockFormat.h24);
    final coach = CoachConfig();
    addTearDown(() {
      app.dispose();
      coach.dispose();
      theme.dispose();
      locale.dispose();
      units.dispose();
      clock.dispose();
    });
    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<CoachConfig>.value(value: coach),
      ChangeNotifierProvider<ThemeController>.value(value: theme),
      ChangeNotifierProvider<LocaleController>.value(value: locale),
      ChangeNotifierProvider<UnitsController>.value(value: units),
      ChangeNotifierProvider<ClockFormatController>.value(value: clock),
    ], child: const OpenStrapApp()));
    // The existing overlay creates its fade controller lazily in run().
    // Initialise it while mounted so the app root can be disposed in this test.
    themeSwitchKey.currentState!.run(() {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() => app.importEdgeBackup(path));
    await tester.pump();
    expect(app.user?['name'], 'Restored');
    expect(theme.choice, AppThemeChoice.dark);
    expect(locale.code, 'es');
    expect(units.system, UnitSystem.imperial);
    expect(clock.format, ClockFormat.h12);
    final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(material.locale, const Locale('es'));
    expect(material.themeMode, ThemeMode.dark);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a wrong-typed clock setting is refused; the other settings still apply',
      (tester) async {
    late String path;
    await tester.runAsync(() async {
      await env.wipe();
      FlutterSecureStorage.setMockInitialValues({});
      await setPrefs({'theme_choice': 'dark', 'locale_override': 'es',
        'units_system': 'imperial', 'clock_format': true,
        'local_profile_json': '{"name":"Restored"}'});
      path = await LocalDb.exportCopy();
      await env.wipe();
    });
    final app = AppState.forTesting();
    final theme = ThemeController.seed(AppThemeChoice.light, Brightness.light);
    final locale = LocaleController.seed(null);
    final units = UnitsController.seed(UnitSystem.metric);
    final clock = ClockFormatController.seed(ClockFormat.h24);
    final coach = CoachConfig();
    addTearDown(() {
      app.dispose();
      coach.dispose();
      theme.dispose();
      locale.dispose();
      units.dispose();
      clock.dispose();
    });
    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<CoachConfig>.value(value: coach),
      ChangeNotifierProvider<ThemeController>.value(value: theme),
      ChangeNotifierProvider<LocaleController>.value(value: locale),
      ChangeNotifierProvider<UnitsController>.value(value: units),
      ChangeNotifierProvider<ClockFormatController>.value(value: clock),
    ], child: const OpenStrapApp()));
    // The existing overlay creates its fade controller lazily in run().
    // Initialise it while mounted so the app root can be disposed in this test.
    themeSwitchKey.currentState!.run(() {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final errors = <Object>[];
    final logs = <String>[];
    final previousPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    addTearDown(() => debugPrint = previousPrint);
    await tester.runAsync(() async {
      final completed = Completer<void>();
      runZonedGuarded(() async {
        try {
          await app.importEdgeBackup(path);
        } finally {
          completed.complete();
        }
      }, (error, stack) => errors.add(error));
      await completed.future;
    });
    debugPrint = previousPrint;
    await tester.pump();
    expect(errors, isEmpty, reason: 'controller reload failures must be caught');
    expect(logs, isNot(contains(contains('clock_format reload failed'))),
        reason: 'the wrong-typed row is refused before it is written');
    expect(app.lastImportPrefsRefused, 1);
    expect(app.user?['name'], 'Restored');
    expect(theme.choice, AppThemeChoice.dark);
    expect(locale.code, 'es');
    expect(units.system, UnitSystem.imperial);
    // Nothing was written for the clock, so it reads the stored state: unset.
    expect(clock.format, ClockFormat.system);
    final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(material.locale, const Locale('es'));
    expect(material.themeMode, ThemeMode.dark);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final prefs in [0, 2]) {
    testWidgets('ChatGPT sign-in notice is visible with $prefs restored settings',
        (tester) async {
      final result = ImportOutcome(source: 'OpenStrap backup',
          prefsRestored: prefs, needsReentry: const ['coach_chatgpt']);
      expect(result.needsReading, isTrue);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ImportReport(result))));
      expect(find.textContaining('Sign in again in AI settings'), findsOneWidget);
      expect(find.textContaining('Enter it again in AI settings'), findsNothing);
    });
  }

  for (final prefs in [0, 2]) {
    testWidgets('coach re-entry is visible with $prefs restored settings', (tester) async {
      final result = ImportOutcome(source: 'OpenStrap backup',
          prefsRestored: prefs, needsReentry: const ['coach_api_key']);
      expect(result.needsReading, isTrue);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ImportReport(result))));
      expect(find.textContaining('Enter it again in AI settings'), findsOneWidget);
      if (prefs > 0) {
        expect(find.text('2 settings restored'), findsOneWidget);
        expect(find.text('Nothing was imported'), findsNothing);
      }
    });
  }

  testWidgets('skipped settings are reported, not hidden', (tester) async {
    final result = ImportOutcome(source: 'OpenStrap backup',
        prefsRestored: 5, prefsRefused: 1);
    expect(result.needsReading, isTrue);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ImportReport(result))));
    expect(find.textContaining('1 setting in the backup could not be read'),
        findsOneWidget);
  });
}
