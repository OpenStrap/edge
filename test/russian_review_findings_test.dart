import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/display_text.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/sync/paired_device.dart';
import 'package:openstrap_edge/ui2/activity/zones.dart';
import 'package:openstrap_edge/ui2/pairing/device_picker.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/screens/coach.dart';
import 'package:openstrap_edge/ui2/screens/coach_text.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show axisDay;
import 'package:openstrap_edge/ui2/screens/journal_compose.dart'
    show OsTextField;
import 'package:openstrap_edge/ui2/screens/readiness_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget page(Widget child, {String locale = 'ru', double scale = 1}) =>
    MaterialApp(
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    );

class SensorApp extends AppState {
  final List<Map<String, Object?>> rows;
  SensorApp(this.rows) : super.forTesting();
  @override
  List<Map<String, Object?>> get sensors => rows;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final ru = lookupAppLocalizations(const Locale('ru'));

  for (final locale in ['en', 'ru']) {
    for (final fields in [
      ['Weight'],
      ['Weight', 'Height'],
    ]) {
      testWidgets('unreadable ${fields.length} fields in $locale', (t) async {
        await t.pumpWidget(
          page(
            Scaffold(
              body: Builder(
                builder: (c) => TextButton(
                  onPressed: () => sayUnreadable(c, fields),
                  child: const Text('check'),
                ),
              ),
            ),
            locale: locale,
          ),
        );
        await t.tap(find.text('check'));
        await t.pumpAndSettle();
        final joined = fields.join(', ');
        final expected = locale == 'en'
            ? (fields.length == 1
                  ? '$joined is not a number. Nothing was saved.'
                  : '$joined are not numbers. Nothing was saved.')
            : (fields.length == 1
                  ? 'В поле «$joined» должно быть число. Ничего не сохранено.'
                  : 'В полях «$joined» должны быть числа. Ничего не сохранено.');
        expect(
          find.text(expected),
          findsOneWidget,
          reason: t
              .widgetList<Text>(find.byType(Text))
              .map((w) => w.data)
              .where((s) => s?.contains('процентил') ?? false)
              .join('\n'),
        );
      });
    }
  }

  test(
    'formatters resolve all preferred locales and prioritize override',
    () async {
      SharedPreferences.setMockInitialValues({});
      addTearDown(binding.platformDispatcher.clearLocalesTestValue);
      final controller = LocaleController.seed(null)..useForPresentation();
      addTearDown(controller.dispose);
      binding.platformDispatcher.localesTestValue = const [
        Locale('ja', 'JP'),
        Locale('ru', 'RU'),
      ];
      expect(LocaleController.displayLanguageCode, 'ru');
      binding.platformDispatcher.localesTestValue = const [
        Locale('fr', 'FR'),
        Locale('ru', 'RU'),
      ];
      expect(LocaleController.displayLanguageCode, 'fr');
      await controller.setCode('en');
      expect(LocaleController.displayLanguageCode, 'en');
      await controller.setCode('ru');
      binding.platformDispatcher.localesTestValue = const [
        Locale('ja'),
        Locale('ko'),
      ];
      expect(LocaleController.displayLanguageCode, 'ru');
      await controller.setCode(null);
      expect(LocaleController.displayLanguageCode, 'en');
    },
  );

  testWidgets('manual zone threshold labels localize known names only', (
    t,
  ) async {
    t.view.physicalSize = const Size(800, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    const names = ['Warm-up', 'Easy', 'Aerobic', 'Threshold', 'Max effort'];
    const expected = [
      'Разминка',
      'Лёгкая нагрузка',
      'Аэробная нагрузка',
      'Пороговая нагрузка',
      'Максимальная нагрузка',
    ];
    for (var i = 0; i < names.length; i++) {
      expect(localizedText(ru, names[i]), expected[i]);
      expect(
        localizedText(lookupAppLocalizations(const Locale('en')), names[i]),
        names[i],
      );
    }
    const custom = 'My custom aerobic zone';
    expect(localizedText(ru, custom), custom);
    final zones = [
      for (var i = 0; i < 5; i++)
        (
          zone: i + 1,
          name: i == 4 ? custom : names[i],
          lo: 60 + i * 20,
          hi: 79 + i * 20,
        ),
    ];
    await t.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: page(ZonesDetail(data: ZonesData(zones: zones, age: 30))),
      ),
    );
    await t.pumpAndSettle();
    await t.ensureVisible(find.text(ru.activityZonesSetYourOwnLink));
    await t.tap(find.text(ru.activityZonesSetYourOwnLink));
    await t.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is OsTextField &&
              w.label ==
                  ru.supplementZoneStartsAt(
                    i + 1,
                    i == 4 ? custom : expected[i],
                  ),
        ),
        findsOneWidget,
      );
      expect(zones[i].name, i == 4 ? custom : names[i]);
    }
    expect(t.takeException(), isNull);
  });

  for (final locale in ['ru', 'en']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'metric and trend visible/spoken units agree at $locale/$scale',
        (t) async {
          final handle = t.ensureSemantics();
          try {
            await t.pumpWidget(
              page(
                Scaffold(
                  body: SingleChildScrollView(
                    child: Column(
                      children: [
                        const MetricRow(
                          Icons.favorite,
                          C.red,
                          'Pulse',
                          '72',
                          unit: 'bpm',
                        ),
                        const TrendCard('Trend', '76', 'bpm', '+2', '7 days', [
                          70,
                          72,
                          76,
                        ], C.red),
                      ],
                    ),
                  ),
                ),
                locale: locale,
                scale: scale,
              ),
            );
            await t.pumpAndSettle();
            final unit = locale == 'ru' ? 'уд/мин' : 'bpm';
            expect(find.text(unit), findsNWidgets(2));
            expect(
              find.bySemanticsLabel(RegExp('Pulse, 72 $unit')),
              findsOneWidget,
            );
            expect(
              find.bySemanticsLabel(RegExp('Trend, 76 $unit')),
              findsOneWidget,
            );
            expect(t.takeException(), isNull);
          } finally {
            handle.dispose();
          }
        },
      );
    }
  }

  for (final custom in [false, true]) {
    testWidgets('live selector preserves supplied names: $custom', (t) async {
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      app.paired = PairedDevice('primary', 'serial', generation: 'gen4');
      app.device.connection = 'connected';
      final now = DateTime.now().millisecondsSinceEpoch;
      app.debugFeedEngineState(
        '',
        DeviceState()
          ..connection = 'connected'
          ..liveHr = 61
          ..liveHrAt = now,
      );
      app.debugFeedEngineState(
        'second',
        DeviceState()
          ..connection = 'connected'
          ..liveHr = 72
          ..liveHrAt = now,
      );
      if (custom) app.device.strapName = 'Custom band 7h 12m';
      final handle = t.ensureSemantics();
      try {
        await t.pumpWidget(
          ChangeNotifierProvider<AppState>.value(
            value: app,
            child: page(const Scaffold(body: LiveHrCard())),
          ),
        );
        await t.pumpAndSettle();
        final label = custom ? 'Custom band 7h 12m' : ru.dayStepsYourBand;
        expect(find.text(label), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            RegExp(RegExp.escape(ru.liveHrShowingDeviceSemantics(label))),
          ),
          findsOneWidget,
        );
        expect(t.takeException(), isNull);
      } finally {
        handle.dispose();
      }
    });
  }

  testWidgets(
    'registry labels are fallback names; stored names stay verbatim',
    (t) async {
      final rows = <Map<String, Object?>>[
        {'id': 'unnamed', 'adapter_id': 'ble_hrs', 'label': null},
        {
          'id': 'named',
          'adapter_id': 'ble_hrs',
          'label': 'Bluetooth heart rate sensor',
        },
      ];
      final app = SensorApp(rows);
      addTearDown(app.dispose);
      final sources = liveSources(app).where((s) => !s.isBand).toList();
      expect(sources[0].nameIsFallback, isTrue);
      expect(sources[1].nameIsFallback, isFalse);
      await t.pumpWidget(
        page(
          Scaffold(
            body: Builder(
              builder: (c) => Column(
                children: [
                  for (final source in sources) Text(source.displayName(c)),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.text(localizedText(ru, 'Bluetooth heart rate sensor')),
        findsOneWidget,
      );
      expect(find.text('Bluetooth heart rate sensor'), findsOneWidget);
      expect(rows[0]['label'], isNull);
      expect(rows[1]['label'], 'Bluetooth heart rate sensor');
    },
  );

  testWidgets('category search accepts original and Russian blurb', (t) async {
    await t.pumpWidget(page(const DevicePickerScreen()));
    await t.pumpAndSettle();
    final entry = kBleHrs;
    for (final query in [
      deviceCategoryBlurb(null, entry),
      deviceCategoryBlurb(ru, entry),
    ]) {
      await t.enterText(find.byType(TextField).first, query);
      await t.pumpAndSettle();
      expect(find.text(localizedText(ru, entry.label)), findsOneWidget);
    }
    expect(t.takeException(), isNull);
  });

  final schedules = <(List<Object?>?, bool)>[
    ([1, 2, 3, 4, 5, 6, 7], true),
    ([1, 1, 1, 1, 1, 1, 1], false),
    // No valid day left: addMedication saves every day, so that is shown.
    ([0, 8, 9, 10, 11, 12, 13], true),
    ([1.5, 2, 3, 4, 5, 6, 7], false),
    ([1, 1, 2, 3, 4, 5, 6, 7, 7], true),
    (null, true),
    ([], true),
  ];
  for (var i = 0; i < schedules.length; i++) {
    testWidgets('medication schedule distinct valid days case $i', (t) async {
      final (days, daily) = schedules[i];
      final args = <String, dynamic>{
        'name': 'Original',
        'time': '08:15',
        'weekdays': ?days,
      };
      final before = jsonEncode(args);
      String? summary;
      await t.pumpWidget(
        page(
          Builder(
            builder: (c) {
              summary = coachActionSummary(
                c,
                ActionRequest(
                  tool: 'add_medication',
                  title: '',
                  summary: 'original',
                  args: args,
                ),
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(summary!.contains(localizedText(ru, 'every day')), daily);
      expect(summary, contains('не проверяет взаимодействие лекарств'));
      expect(jsonEncode(args), before);
    });
  }

  testWidgets(
    'stored known model error rerenders on locale change without refetch',
    (t) async {
      final cfg = CoachConfig();
      addTearDown(cfg.dispose);
      var requests = 0;
      await http.runWithClient(
        () async {
          Widget setup(String locale) =>
              ChangeNotifierProvider<CoachConfig>.value(
                value: cfg,
                child: page(
                  const CoachSetup(key: ValueKey('same-setup')),
                  locale: locale,
                ),
              );
          await t.pumpWidget(setup('en'));
          await t.pumpAndSettle();
          final en = lookupAppLocalizations(const Locale('en'));
          await t.scrollUntilVisible(
            find.text(en.coachListModels),
            400,
            scrollable: find.byType(Scrollable).first,
          );
          await t.tap(find.text(en.coachListModels));
          await t.pumpAndSettle();
          const raw =
              'Models request failed (429): Empty response from provider.';
          expect(find.text(raw), findsOneWidget);
          final state = t.state(find.byType(CoachSetup));
          await t.pumpWidget(setup('ru'));
          await t.pumpAndSettle();
          expect(t.state(find.byType(CoachSetup)), same(state));
          expect(
            find.text(
              ru.supplementCoachModelsError(
                '429',
                'Empty response from provider.',
              ),
            ),
            findsOneWidget,
          );
          expect(requests, 1);
          await t.pumpWidget(setup('en'));
          await t.pumpAndSettle();
          expect(find.text(raw), findsOneWidget);
          expect(requests, 1);
        },
        () => MockClient((request) async {
          requests++;
          return http.Response('Empty response from provider.', 429);
        }),
      );
    },
  );

  testWidgets('Russian percentile numbers use the dative ordinal', (t) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final n in [1, 2, 3, 11, 12, 21, 22, 23, 100]) {
      await t.pumpWidget(
        page(
          MetricDetail(
            'resting_hr',
            key: ValueKey(n),
            data: MetricData(
              series: [(t: now, v: 60.0)],
              percentile: {'percentile_of_you': n},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.text(ru.metricDetailPercentileTodayNoBand('$n-му')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    }
  });

  for (final today in [true, false]) {
    for (final hasBand in [false, true]) {
      testWidgets('Russian percentile message today=$today band=$hasBand', (
        t,
      ) async {
        final now = DateTime.now();
        final at = today ? now : DateTime(now.year, now.month, now.day - 2, 12);
        final ts = at.millisecondsSinceEpoch ~/ 1000;
        const band = 'Original provider label';
        await t.pumpWidget(
          page(
            MetricDetail(
              'resting_hr',
              data: MetricData(
                series: [(t: ts, v: 60.0)],
                daysAvailable: 7,
                percentile: {
                  'percentile_of_you': 12,
                  if (hasBand) 'label': band,
                },
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        if (!today) {
          await t.tap(find.text(ru.metricDetailRange7Days));
          await t.pumpAndSettle();
        }
        final expected = today
            ? (hasBand
                  ? ru.metricDetailPercentileTodayBand('12-му', band)
                  : ru.metricDetailPercentileTodayNoBand('12-му'))
            : (hasBand
                  ? ru.metricDetailPercentileFromBand(
                      axisDay(ts),
                      '12-му',
                      band,
                    )
                  : ru.metricDetailPercentileFromNoBand(axisDay(ts), '12-му'));
        expect(
          expected,
          contains('соответствует 12-му процентилю вашей истории'),
        );
        expect(find.text(expected), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('SubTabs reveal stays horizontal at ${scale}x text', (t) async {
      t.view.physicalSize = const Size(320, 700);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final vertical = ScrollController(initialScrollOffset: 200);
      addTearDown(vertical.dispose);
      var index = 4;
      late StateSetter update;
      const labels = [
        'Обзор',
        'Подробнее',
        'Динамика',
        'Показатели',
        'Анализы',
      ];
      await t.pumpWidget(
        page(
          Scaffold(
            body: SingleChildScrollView(
              controller: vertical,
              child: Column(
                children: [
                  const SizedBox(height: 600),
                  StatefulBuilder(
                    builder: (c, setState) {
                      update = setState;
                      return SubTabs(
                        labels,
                        index,
                        (i) => setState(() => index = i),
                        disabled: const {2},
                      );
                    },
                  ),
                  const SizedBox(height: 900),
                ],
              ),
            ),
          ),
          scale: scale,
        ),
      );
      await t.pumpAndSettle();
      final tabs = find.byType(SubTabs);
      final strip = find.descendant(
        of: tabs,
        matching: find.byType(SingleChildScrollView),
      );
      final horizontal = t.widget<SingleChildScrollView>(strip).controller!;
      void checkVisible(String label) {
        final viewport = t.getRect(strip);
        final selected = t.getRect(find.text(label));
        expect(selected.left, greaterThanOrEqualTo(viewport.left));
        expect(selected.right, lessThanOrEqualTo(viewport.right));
        expect(vertical.offset, 200);
      }

      expect(horizontal.offset, greaterThan(0));
      checkVisible(labels.last);
      update(() => index = 0);
      await t.pumpAndSettle();
      checkVisible(labels.first);
      update(() => index = 4);
      await t.pumpAndSettle();
      checkVisible(labels.last);
      final disabled = find.ancestor(
        of: find.text(labels[2]),
        matching: find.byType(Pressable),
      );
      expect(t.widget<Pressable>(disabled).onTap, isNull);
      expect(
        t.widget<Pressable>(disabled).semanticLabel,
        ru.supplementUnavailable(labels[2]),
      );
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    });
  }

  testWidgets(
    'readiness breakdown localizes input labels without changing keys',
    (t) async {
      final rows = [
        for (final key in ['hrv', 'rhr', 'resp', 'temp'])
          <String, dynamic>{
            'label': key,
            'weight': 0.25,
            'used': true,
            'past_mdc': true,
            'weighted_contribution': 15,
          },
      ];
      final before = jsonEncode(rows);
      await t.pumpWidget(
        page(
          ReadinessDetail(
            data: ReadinessData(
              readiness: const Metric(value: 60),
              breakdown: rows,
              inputsUsed: 4,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      for (final name in [
        ru.homeDriverHrv,
        ru.homeDriverRhr,
        ru.homeDriverResp,
        ru.homeDriverTemp,
      ]) {
        expect(find.text(name), findsWidgets);
      }
      expect(jsonEncode(rows), before);
      expect(t.takeException(), isNull);
    },
  );
}
