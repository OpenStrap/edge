import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/auto_backup.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/data.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    prefs = await SharedPreferences.getInstance();
  });
  setUp(() async {
    await prefs.clear();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidBackupStorage.channel, null);
  });

  Future<AppState> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(1170, 6000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ThemeController>(
            create: (_) =>
                ThemeController.seed(AppThemeChoice.light, Brightness.light),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const DataScreen(),
        ),
      ),
    );
    await t.pumpAndSettle();
    return app;
  }

  testWidgets(
    'Android exposes the picker; cancelling keeps the default',
    (t) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            AndroidBackupStorage.channel,
            (call) async => null,
          );
      final app = await pump(t);
      expect(find.text('Backup folder'), findsOneWidget);
      await t.tap(find.text('Backup folder'));
      await t.pumpAndSettle();
      expect(app.backupFolder, isNull);
      expect(app.backupCadence, BackupCadence.off);
      expect(find.textContaining('Backup failed:'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'saving a folder while Off does not create a backup',
    (t) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidBackupStorage.channel, (call) async {
            calls.add(call.method);
            return {
              'uri': 'content://backups/tree/test',
              'name': 'Personal health backups',
            };
          });
      final app = await pump(t);
      await t.tap(find.text('Backup folder'));
      await t.pumpAndSettle();
      expect(app.backupFolder?.name, 'Personal health backups');
      expect(app.backupCadence, BackupCadence.off);
      expect(app.lastBackupAt, isNull);
      expect(calls, ['pick']);
      expect(find.text('Use default folder'), findsOneWidget);
      await t.tap(find.text('Use default folder'));
      await t.pumpAndSettle();
      expect(app.backupFolder, isNull);
      expect(app.backupCadence, BackupCadence.off);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'picker failure is shown and the selected folder is kept',
    (t) async {
      await prefs.setString(
        Prefs.backupFolder,
        jsonEncode({'uri': 'content://backups/tree/test', 'name': 'Backups'}),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidBackupStorage.channel, (call) async {
            throw PlatformException(
              code: 'picker_failed',
              message: 'No folder picker',
            );
          });
      final app = await pump(t);
      await t.tap(find.text('Backup folder'));
      await t.pumpAndSettle();
      expect(app.backupFolder?.name, 'Backups');
      expect(find.textContaining('No folder picker'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'saved failure stays visible with retry and folder actions',
    (t) async {
      await prefs.setString(Prefs.backupLastError, 'Choose the folder again.');
      await pump(t);
      expect(
        find.text('Backup failed: Choose the folder again.'),
        findsOneWidget,
      );
      expect(find.text('Back up now'), findsOneWidget);
      expect(find.text('Backup folder'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'long folder names wrap without overflowing the shared row',
    (t) async {
      await prefs.setString(
        Prefs.backupFolder,
        jsonEncode({
          'uri': 'content://backups/tree/test',
          'name': List.filled(10, 'A long personal backup folder').join(' '),
        }),
      );
      await pump(t);
      expect(t.takeException(), isNull);
      expect(
        find.textContaining('A long personal backup folder'),
        findsWidgets,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'iOS keeps the existing backup controls without an Android picker',
    (t) async {
      await pump(t);
      expect(find.text('Backup folder'), findsNothing);
      expect(find.text('Back up now'), findsOneWidget);
      expect(find.text('How often'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
