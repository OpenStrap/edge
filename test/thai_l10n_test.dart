import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Thai covers the English messages and preserves ICU arguments', () {
    Map<String, dynamic> arb(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
            as Map<String, dynamic>;
    final en = arb('en');
    final th = arb('th');
    final keys = en.keys.where((key) => !key.startsWith('@')).toSet();
    expect(th['@@locale'], 'th');
    expect(th.keys.where((key) => !key.startsWith('@')).toSet(), keys);
    for (final key in keys) {
      expect(th[key], isA<String>(), reason: key);
      expect(th[key], isNotEmpty, reason: key);
      final metadata = en['@$key'] as Map<String, dynamic>?;
      final arguments = metadata?['placeholders'] as Map<String, dynamic>?;
      for (final argument in arguments?.keys ?? <String>[]) {
        expect(
          RegExp(
            '\\{${RegExp.escape(argument)}(?:\\}|,)',
          ).hasMatch(th[key] as String),
          isTrue,
          reason: '$key must preserve $argument',
        );
      }
    }
  });

  test('Thai plural and select messages render numbers and dynamic names', () {
    final th = lookupAppLocalizations(const Locale('th'));
    expect(th.localeName, 'th');
    for (final n in [0, 1, 2, 14]) {
      expect(th.dataFilesShared(n), 'แชร์แล้ว $n ไฟล์');
    }
    expect(th.calmBreathingMinutesSemantic(5), '5 นาที');
    expect(
      th.investigateDroppedThin(2),
      'ไม่นับ 2 คืนเพราะมีชั่วโมงที่สังเกตได้น้อยเกินไป',
    );
    expect(th.activityExerciseCategory('Abs'), 'หน้าท้อง');
    expect(th.activityExerciseCategory('Custom'), 'Custom');
    expect(th.activityExerciseEquipment('Pullupbar', 'Pull-up bar'), 'บาร์โหน');
    expect(
      th.activityExerciseEquipment('custom', 'My equipment'),
      'My equipment',
    );
    expect(
      th.notifRecoveryReadySleptBody(80, 7, 30),
      'การฟื้นตัว 80 นอน 7 ชม. 30 นาที',
    );
  });

  testWidgets('Thai is reachable in the picker and persists after selection', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = LocaleController.seed('en');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<LocaleController>.value(
        value: controller,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, child) => MaterialApp(
            theme: buildTheme(Brightness.dark),
            locale: controller.locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const ProfileHomeView(stats: ProfileStats(name: 'Tester')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('ไทย'));
    await tester.tap(find.text('ไทย'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(controller.locale, const Locale('th'));
    expect(find.text('โปรไฟล์'), findsOneWidget);
    expect(find.text('ภาษา'), findsOneWidget);
    expect((await LocaleController.bootstrap()).code, 'th');
  });
}
