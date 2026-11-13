import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  group('OS notification copy follows the app language', () {
    LocaleController? controller;

    setUp(() => SharedPreferences.setMockInitialValues({}));
    tearDown(() {
      controller?.dispose();
      controller = null;
      binding.platformDispatcher.clearLocalesTestValue();
    });

    test('russian UI gets russian titles and bodies', () async {
      controller = LocaleController.seed('ru')..useForPresentation();
      const t = NotificationService.osText;

      expect(await t('Your recovery is ready'), 'Оценка восстановления готова');
      expect(await t('Low battery'), 'Низкий заряд');
      expect(await t('Step goal reached'), 'Цель по шагам достигнута');
      expect(await t('Alarm not confirmed'), 'Будильник не подтверждён');

      // Bodies exactly as the producers interpolate them.
      expect(await t('Recovery 64, slept 7h 5m.'),
          'Восстановление 64, сон 7 ч 5 мин.');
      expect(await t('Recovery 64.'), 'Восстановление 64.');
      expect(
          await t('You hit about 10234 steps — at or above your 10000 goal.'),
          'Вы прошли около 10234 шагов — не меньше цели в 10000.');
      expect(await t('Your band is at 12%. Charge it soon.'),
          'Заряд браслета 12%. Скоро зарядите его.');
    });

    test('english UI and unknown copy pass through unchanged', () async {
      controller = LocaleController.seed('en')..useForPresentation();
      expect(await NotificationService.osText('Recovery 64, slept 7h 5m.'),
          'Recovery 64, slept 7h 5m.');
      controller!.dispose();
      controller = LocaleController.seed('ru')..useForPresentation();
      expect(await NotificationService.osText('Some unmapped reminder'),
          'Some unmapped reminder');
    });

    // Headless entries (background sync, BGTask) never build the app root, so
    // no controller is bound there. The saved setting must still win over the
    // phone's language.
    test('background: explicit english beats a russian phone', () async {
      SharedPreferences.setMockInitialValues({'locale_override': 'en'});
      binding.platformDispatcher.localesTestValue = const [Locale('ru')];
      expect(await NotificationService.osText('Low battery'), 'Low battery');
    });

    test('background: explicit russian beats an english phone', () async {
      SharedPreferences.setMockInitialValues({'locale_override': 'ru'});
      binding.platformDispatcher.localesTestValue = const [Locale('en')];
      expect(await NotificationService.osText('Low battery'), 'Низкий заряд');
    });

    test('background: no saved setting follows the phone', () async {
      binding.platformDispatcher.localesTestValue = const [Locale('ru')];
      expect(await NotificationService.osText('Low battery'), 'Низкий заряд');
    });

    test('background: an unsupported saved code falls back to the phone',
        () async {
      SharedPreferences.setMockInitialValues({'locale_override': 'xx'});
      binding.platformDispatcher.localesTestValue = const [Locale('ru')];
      expect(await NotificationService.osText('Low battery'), 'Низкий заряд');
    });
  });
}
