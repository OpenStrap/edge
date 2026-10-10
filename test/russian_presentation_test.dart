import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/app_localizations_en.dart';
import 'package:openstrap_edge/l10n/app_localizations_ru.dart';
import 'package:openstrap_edge/l10n/date_text.dart';
import 'package:openstrap_edge/l10n/display_text.dart';
import 'package:openstrap_edge/l10n/presentation_text.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/pairing/device_picker.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/screens/workout_screen.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget harness(Widget child, {double scale = 1, String locale = 'ru'}) =>
    MaterialApp(
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    );

void main() {
  final ru = AppLocalizationsRu();
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader('Manrope');
    for (final file in Directory(
      'assets/fonts/Manrope',
    ).listSync().whereType<File>()) {
      if (file.path.endsWith('.ttf')) {
        loader.addFont(
          file.readAsBytes().then(
            (b) => ByteData.sublistView(Uint8List.fromList(b)),
          ),
        );
      }
    }
    await loader.load();
  });

  test(
    'Russian dates use grammatical months and detail labels are not ISO',
    () {
      expect(prettyDay('2026-10-05', ru), 'Понедельник, 5 октября');
      for (var month = 1; month <= 12; month++) {
        final day = '2026-${month.toString().padLeft(2, '0')}-05';
        final text = displayDay(day, ru);
        expect(text, isNot(contains('2026-')));
        expect(text, matches(RegExp(r'5 [а-яё]')));
      }
      expect(dayNavLabel('2025-10-05', ru), contains('5 октября'));
      expect(
        ecgDisplayWhen(
          DateTime(2026, 10, 5, 14, 49).millisecondsSinceEpoch ~/ 1000,
          ru,
        ),
        contains('5 окт. 2026'),
      );
      expect(nounInSentence(ru, 'ВСР'), 'ВСР');
      expect(nounInSentence(ru, 'Стабильность ВСР'), 'стабильность ВСР');
      expect(nounInSentence(ru, 'REM-сон'), 'REM-сон');
      expect(nounInSentence(ru, 'SpO₂'), 'SpO₂');
      expect(nounInSentence(ru, 'Сон'), 'сон');
    },
  );

  test('owned composed absence reasons preserve times and counts', () {
    const gap = 'Your band was off your wrist 00:00 – 14:32.';
    const noSleep =
        'no sleep was scored for this day — resting HR is only ever measured over a sleep window, never over waking hours.';
    const thin =
        'Too few clean beat-to-beat intervals to work this out. There were 0, and it needs 30.';
    for (final source in [
      gap,
      '$noSleep $gap',
      '$thin $gap',
      'Baevsky Stress Index → 0–100; resting autonomic tension (PRV). $gap',
    ]) {
      final text = presentationText(ru, source);
      expect(text, contains('00:00'));
      expect(text, contains('14:32'));
      expect(text, isNot(contains('Your band')));
      expect(text, isNot(contains('There were')));
      expect(text, isNot(contains('no sleep')));
      expect(presentationText(AppLocalizationsEn(), source), source);
    }
    expect(presentationText(ru, '$thin $gap'), contains('30'));
    expect(
      presentationText(
        ru,
        'no readiness inputs present — "—" (never imputed).',
      ),
      contains('не подставляются искусственно'),
    );
    expect(
      presentationText(ru, 'A user-entered sentence'),
      'A user-entered sentence',
    );
  });

  test(
    'timeline localizes known activities, duration and average without storage changes',
    () {
      final row = <String, dynamic>{
        'type': 'weight_training',
        'start_ts': 10,
        'end_ts': 10,
        'duration_min': 0,
        'avg_hr': 102,
      };
      final moments = dayMoments(
        timeline: {
          'sessions': [row],
        },
        l: ru,
      );
      expect(moments.single.title, 'Силовая тренировка');
      expect(moments.single.detail, contains('0 мин'));
      expect(moments.single.detail, contains('ср. пульс 102 уд/мин'));
      expect(row['type'], 'weight_training');
      expect(presentationText(ru, '1h 20m'), '1 ч 20 мин');
      for (final name in ['Cardio', 'Other']) {
        expect(catalogueName(ru, name), isNot(name));
      }
      for (final unit in ['cm', 'kg', 'bpm', 's', 'µV']) {
        expect(localizedText(ru, unit), isNot(unit));
      }
    },
  );

  test(
    'all registry category descriptions are Russian and generic names translate',
    () {
      for (final entry in kBandRegistry) {
        expect(
          deviceCategoryBlurb(ru, entry),
          matches(RegExp('[А-Яа-яЁё]')),
          reason: entry.id,
        );
      }
      for (final name in [
        'Bluetooth heart rate sensor',
        'Garmin watch',
        'Polar sensor',
        'Coros watch',
        'Smart ring (R11M/R10M)',
      ]) {
        expect(localizedText(ru, name), isNot(name));
      }
      for (final name in [
        'Casio G-Shock',
        'Jyou Band',
        'Watch9',
        'Bangle.js',
        'Oura Ring',
      ]) {
        expect(localizedText(ru, name), name);
      }
    },
  );

  test(
    'built-in journal labels translate while custom names remain verbatim',
    () {
      const custom = JournalFieldSpec(
        key: 'custom',
        label: 'Mood',
        kind: JournalFieldKind.rating,
        unit: '',
        max: 5,
        step: 1,
        custom: true,
      );
      final fields = [...kJournalFields, custom];
      final notes = dayNotes(
        fields: fields,
        journal: {
          for (final field in fields) field.key: const JournalMetricValue(2),
        },
        l: ru,
      );
      for (var i = 0; i < kJournalFields.length; i++) {
        expect(notes[i].title, matches(RegExp('[А-Яа-яЁё]')));
      }
      expect(notes.last.title, 'Mood');
      expect(notes.first.title, 'Настроение');
      expect(notes[1].title, 'Качество сна');
      expect(notes[2].title, 'Энергия');
      expect(
        ru.presentationWeightRepsLogged('20', localizedText(ru, 'kg'), 5),
        '20 кг × 5 — записано',
      );
      expect(ru.presentationVolumeUnit(localizedText(ru, 'lb')), 'Объём, фунт.');
    },
  );

  for (final n in [1, 2, 5, 21, 22, 25]) {
    testWidgets(
      '$n of 20 measures uses genitive and accessible localized output',
      (tester) async {
        await tester.pumpWidget(
          harness(
            Scaffold(
              body: Consistency(n, 20, 'Показатели', C.green, unit: 'measures'),
            ),
          ),
        );
        expect(find.text('из 20 измерений'), findsOneWidget);
        final semantics = tester
            .widgetList<Semantics>(find.byType(Semantics))
            .firstWhere(
              (widget) => widget.properties.label?.contains('из 20') == true,
            );
        expect(semantics.properties.label, contains('$n из 20 измерений'));
      },
    );
  }

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets(
        'Russian navigation and quick start fit $width dp at $scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            harness(
              AppShell(builder: (_, _) => const SizedBox()),
              scale: scale,
            ),
          );
          await tester.pumpAndSettle();
          final nav = find.text('Активность');
          expect(nav, findsOneWidget);
          final paragraph = tester.renderObject<RenderParagraph>(nav);
          expect(paragraph.maxLines, isNull);
          expect(paragraph.didExceedMaxLines, isFalse);
          expect(paragraph.size.height, greaterThan(0));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(
            harness(
              Scaffold(
                body: SingleChildScrollView(
                  child: StatusCard(
                    ru.pairingNotFoundTitle,
                    ru.pairingNotFoundBody,
                    fix: ru.pairingNotFoundAdviceFix,
                  ),
                ),
              ),
              scale: scale,
            ),
          );
          await tester.pumpAndSettle();
          final advice = find.text(ru.pairingNotFoundAdviceFix);
          expect(advice, findsOneWidget);
          expect(tester.renderObject<RenderParagraph>(advice).maxLines, isNull);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(
            harness(
              Scaffold(
                body: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (var row = 0; row < 2; row++)
                        Row(
                          children: [
                            for (var i = row * 3; i < row * 3 + 3; i++)
                              Expanded(
                                child: WorkoutQuickTile(quickStart[i], () {}),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              scale: scale,
            ),
          );
          await tester.pumpAndSettle();
          for (final activity in quickStart) {
            expect(find.text(activity.name), findsNothing);
            expect(find.text(activity.localizedName(ru)), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('active health tab is revealed when opened or selected', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var selected = 4;
    await tester.pumpWidget(
      harness(
        Scaffold(
          body: StatefulBuilder(
            builder: (c, setState) => SubTabs(
              const ['Обзор', 'Подробнее', 'Динамика', 'Показатели', 'Анализы'],
              selected,
              (i) => setState(() => selected = i),
            ),
          ),
        ),
        scale: 2,
      ),
    );
    await tester.pumpAndSettle();
    final last = tester.getRect(find.text('Анализы'));
    expect(last.left, greaterThanOrEqualTo(0));
    expect(last.right, lessThanOrEqualTo(320));
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(1000, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Обзор'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('Обзор')).left, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets(
        'ECG detail renders units, date and complete explanatory title at $width/$scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 2000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final ts =
              DateTime(2026, 10, 5, 14, 49).millisecondsSinceEpoch ~/ 1000;
          final reading = EcgReading(
            id: 'ru_fixture',
            deviceId: '',
            wrist: EcgWrist.left,
            startTs: ts,
            endTs: ts + 29,
            strapTerminalTs: ts + 29,
            strapTerminalSubsec: 0,
            resultCode: 1,
            category: EcgCategory.sinusRhythm,
            avgHr: 98,
            quality: 3,
            unreadableMask: 0,
            interruptions: 0,
            sampleCount: 0,
            minUv: 0,
            maxUv: 0,
            rmsUv: 0,
            missingSegments: 0,
            status: EcgReadingStatus.completed,
            notes: null,
            createdAt: ts * 1000,
          );
          await tester.pumpWidget(
            harness(
              EcgDetailScreen(
                data: EcgDetailData(reading: reading, packets: const []),
              ),
              scale: scale,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Синусовый ритм'), findsOneWidget);
          expect(find.textContaining('Это не диагноз'), findsOneWidget);
          final explanation = find.text(ru.ecgWaveformLabel);
          expect(explanation, findsOneWidget);
          expect(
            tester.renderObject<RenderParagraph>(explanation).maxLines,
            isNull,
          );
          expect(find.text('98 уд/мин'), findsOneWidget);
          expect(find.text('29 с'), findsOneWidget);
          expect(find.textContaining('2026-10-05'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
