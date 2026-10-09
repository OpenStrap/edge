import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/app_localizations_ru.dart';
import 'package:openstrap_edge/l10n/presentation_text.dart';
import 'package:openstrap_edge/l10n/decimal_text.dart';
import 'package:openstrap_edge/l10n/display_text.dart';
import 'package:openstrap_edge/l10n/sweep_text.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/ui2/screens/findings_log.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart'
    show hm, thousands, unitBeside;

// Read message arguments, treating the braces around ICU options as syntax.
Set<String> messageVariables(String text) {
  final result = <String>{};
  var i = 0;
  String word() {
    while (i < text.length && text[i].trim().isEmpty) {
      i++;
    }
    final start = i;
    while (i < text.length && RegExp(r'[A-Za-z0-9_=]').hasMatch(text[i])) {
      i++;
    }
    return text.substring(start, i);
  }

  void message({bool nested = false}) {
    while (i < text.length) {
      if (text[i] == '}' && nested) {
        i++;
        return;
      }
      if (text[i] != '{') {
        i++;
        continue;
      }
      i++;
      result.add(word());
      while (i < text.length && text[i].trim().isEmpty) {
        i++;
      }
      if (i < text.length && text[i] == '}') {
        i++;
        continue;
      }
      if (i >= text.length || text[i++] != ',') {
        throw FormatException(text);
      }
      final kind = word();
      if (kind != 'plural' && kind != 'select' && kind != 'selectordinal') {
        throw FormatException('Unsupported ICU message: $text');
      }
      while (i < text.length && text[i].trim().isEmpty) {
        i++;
      }
      if (i >= text.length || text[i++] != ',') {
        throw FormatException(text);
      }
      while (i < text.length) {
        while (i < text.length && text[i].trim().isEmpty) {
          i++;
        }
        if (text[i] == '}') {
          i++;
          break;
        }
        word();
        while (i < text.length && text[i].trim().isEmpty) {
          i++;
        }
        if (i >= text.length || text[i++] != '{') {
          throw FormatException(text);
        }
        message(nested: true);
      }
    }
  }

  message();
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Russian ARB preserves every message and placeholder type', () {
    Map<String, dynamic> read(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
            as Map<String, dynamic>;
    final en = read('en');
    final ru = read('ru');
    Set<String> keys(Map<String, dynamic> data) =>
        data.keys.where((k) => !k.startsWith('@')).toSet();
    expect(ru['@@locale'], 'ru');
    expect(keys(ru), keys(en));
    for (final key in keys(en)) {
      expect((ru[key] as String).trim(), isNotEmpty, reason: key);
      expect(messageVariables(ru[key]), messageVariables(en[key]), reason: key);
      final ep = (en['@$key'] as Map?)?['placeholders'] as Map?;
      final rp = (ru['@$key'] as Map?)?['placeholders'] as Map?;
      for (final name in ep?.keys ?? <String>[]) {
        expect(rp?[name]?['type'], ep?[name]?['type'], reason: '$key.$name');
      }
    }
  });

  test('generated Russian plurals use one, few and many', () {
    final l = AppLocalizationsRu();
    expect(l.profileSourcesCount(1), '1 источник');
    expect(l.profileSourcesCount(2), '2 источника');
    expect(l.profileSourcesCount(5), '5 источников');
    expect(l.profileSourcesCount(21), '21 источник');
    expect(l.welcomeWorkoutsCount(22), '22 тренировки');
    expect(l.welcomeWorkoutsCount(25), '25 тренировок');
  });

  test('sensor limit uses Russian count forms without an ICU overlap', () {
    final ru = AppLocalizationsRu();
    final en = lookupAppLocalizations(const Locale('en'));
    const counts = {
      1: 'датчика',
      2: 'датчиков',
      5: 'датчиков',
      21: 'датчика',
      22: 'датчиков',
      25: 'датчиков',
    };
    for (final entry in counts.entries) {
      expect(
        ru.devicesSensorLimit(entry.key),
        'Этот телефон может подключить до ${entry.key} ${entry.value} вместе с браслетом. Удалите один, чтобы добавить другой.',
      );
      expect(
        en.devicesSensorLimit(entry.key),
        entry.key == 1
            ? 'One sensor is the most this phone will pair alongside your band. Remove it to add another.'
            : 'This phone will pair at most ${entry.key} sensors alongside your band. Remove one to add another.',
      );
    }
    final arb =
        jsonDecode(File('lib/l10n/app_ru.arb').readAsStringSync()) as Map;
    expect(arb['@devicesSensorLimit']['placeholders']['count']['type'], 'int');
    expect(arb['devicesSensorLimit'], isNot(contains('=1{')));
  });

  test(
    'formatting releases disposed controllers and follows system locale',
    () async {
      SharedPreferences.setMockInitialValues({});
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.localesTestValue = const [Locale('en')];
      addTearDown(binding.platformDispatcher.clearLocalesTestValue);
      final first = LocaleController.seed('ru');
      expect(LocaleController.displayLanguageCode, 'en');
      first.useForPresentation();
      final second = LocaleController.seed('en');
      expect(LocaleController.displayLanguageCode, 'ru');
      second.useForPresentation();
      first.dispose();
      expect(LocaleController.displayLanguageCode, 'en');
      await second.setCode('ru');
      expect(displayFixed(1.5, 1), '1,5');
      await second.setCode(null);
      expect(LocaleController.displayLanguageCode, 'en');
      binding.platformDispatcher.localesTestValue = const [Locale('ru')];
      expect(LocaleController.displayLanguageCode, 'ru');
      await second.setCode('en');
      second.dispose();
      expect(LocaleController.displayLanguageCode, 'ru');
      binding.platformDispatcher.localesTestValue = const [Locale('xx')];
      expect(LocaleController.displayLanguageCode, 'en');
    },
  );

  test('exercise names and search localize without changing source keys', () {
    expect(exerciseLibrary, hasLength(214));
    for (final exercise in exerciseLibrary) {
      final russian = exercise.labelFor('ru');
      expect(russian, matches(RegExp('[А-Яа-яЁё]')), reason: exercise.key);
      expect(exercise.labelFor('en'), exercise.label);
      expect(exercise.matches(russian, 'ru'), isTrue, reason: exercise.key);
      expect(
        exercise.matches(exercise.label, 'ru'),
        isTrue,
        reason: exercise.key,
      );
    }
    expect(exerciseByKey('bench_press')?.labelFor('ru'), 'Жим лёжа');
    expect(exerciseByKey('bench_press')?.labelFor('de'), 'Bankdrücken');
  });

  test(
    'formatting changes only presentation and follows the override',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = LocaleController.seed('ru');
      controller.useForPresentation();
      expect(hm(443), '7 ч 23 мин');
      expect(
        thousands(12345).replaceAll('\u00a0', ' ').replaceAll('\u202f', ' '),
        '12 345',
      );
      expect(displayFixed(1.5, 1), '1,5');
      expect(unitBeside('bpm'), 'уд/мин');
      expect(
        presentationText(AppLocalizationsRu(), 'Need 2 more nights'),
        'Нужно ещё 2 ночи',
      );
      await controller.setCode('en');
      expect(hm(443), '7h 23m');
      expect(thousands(12345), '12,345');
      expect(displayFixed(1.5, 1), '1.5');
      expect(unitBeside('bpm'), 'bpm');
      await controller.setCode(null);
      controller.dispose();
    },
  );

  test('preset journal tags and compound absence reasons localize', () {
    final l = AppLocalizationsRu();
    const expected = <String, String>{
      'caffeine': 'Кофеин',
      'alcohol': 'Алкоголь',
      'late meal': 'Поздний приём пищи',
      'stress': 'Стресс',
      'poor sleep': 'Плохой сон',
      'travel': 'Поездка',
      'screens late': 'Экран перед сном',
      'meds': 'Лекарства',
      'sick': 'Болезнь',
      'sauna': 'Сауна',
      'cold plunge': 'Холодное погружение',
      'social': 'Общение',
      'workout': 'Тренировка',
      'rest day': 'День отдыха',
    };
    for (final entry in expected.entries) {
      expect(localizedJournalTag(l, entry.key), entry.value, reason: entry.key);
    }

    const noSleep =
        'no sleep was scored for this day — resting HR is only ever measured over a sleep window, never over waking hours';
    expect(
      presentationText(
        l,
        '$noSleep Your band was off your wrist 00:00 – 14:32.',
      ),
      'За этот день сон не рассчитан: пульс в покое измеряется только во время сна, а не в часы бодрствования. '
      'Браслет был снят с запястья с 00:00 до 14:32.',
    );
  });

  test('all owned finding sentences retain their medical cautions', () {
    final l = AppLocalizationsRu();
    for (final kind in FindingKind.values) {
      for (final risen in [true, false]) {
        final finding = Finding(kind, '2026-10-05', risen: risen);
        expect(localizedText(l, finding.title), isNot(finding.title));
        expect(localizedText(l, finding.detail), isNot(finding.detail));
      }
    }
    final scored = Finding(FindingKind.lowReadiness, '2026-10-05', score: 21);
    expect(localizedText(l, scored.detail), contains('21'));
    expect(localizedText(l, scored.detail), isNot(scored.detail));
    final rhythm = Finding(FindingKind.irregularRhythm, '2026-10-05');
    expect(localizedText(l, rhythm.detail), contains('не диагноз'));
    expect(localizedText(l, rhythm.detail), contains('врач'));
    const pair =
        'steps 12000 and strain 15.2 — both outside your usual range on the same day, which is worth noticing but is not a measured relationship between them';
    final rendered = sweepText(l, pair);
    expect(rendered, contains('12000'));
    expect(rendered, contains('15.2'));
    expect(rendered, contains('связь между ними не измерялась'));
  });

  testWidgets('Russian medical findings wrap at large accessibility text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: FindingRow(
              Finding(FindingKind.irregularRhythm, '2026-10-05'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Irregular heart rhythm — screen'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'Russian override survives bootstrap and system choice clears it',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await LocaleController.bootstrap();
      expect(controller.locale, isNull);
      await controller.setCode('ru');
      final ru = await LocaleController.bootstrap();
      expect(ru.locale, const Locale('ru'));
      ru.dispose();
      await controller.setCode('en');
      final en = await LocaleController.bootstrap();
      expect(en.locale, const Locale('en'));
      en.dispose();
      await controller.setCode(null);
      final system = await LocaleController.bootstrap();
      expect(system.locale, isNull);
      system.dispose();
      controller.dispose();
    },
  );

  testWidgets('Russian tabs and activity names fit a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildTheme(Brightness.light),
        home: AppShell(
          builder: (context, domain) =>
              Text(allActivities.first.displayName(context)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Бег'), findsOneWidget);
    for (final title in [
      'Главная',
      'Здоровье',
      'Питание',
      'Тренировка',
      'Самочувствие',
    ]) {
      expect(find.text(title), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    expect(allActivities.first.typeKey, 'running');
  });
}
