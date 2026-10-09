import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/display_text.dart';
import 'package:openstrap_edge/l10n/presentation_text.dart';
import 'package:openstrap_edge/l10n/sweep_text.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';
import 'package:openstrap_edge/ui2/screens/coach_text.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  Widget russianPage(Widget child) => MaterialApp(
    locale: const Locale('ru'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(Brightness.light),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  test('step goals use Russian count forms and preserve English labels', () {
    final ru = lookupAppLocalizations(const Locale('ru'));
    final en = lookupAppLocalizations(const Locale('en'));
    const counts = {
      1: 'шаг',
      2: 'шага',
      5: 'шагов',
      21: 'шаг',
      22: 'шага',
      25: 'шагов',
    };
    for (final entry in counts.entries) {
      expect(
        ru.metricDetailStepsGoalValue(entry.key, '${entry.key}'),
        '${entry.key} ${entry.value}',
      );
      expect(
        en.metricDetailStepsGoalValue(entry.key, '${entry.key}'),
        '${entry.key} steps',
      );
    }
    expect(
      ru.liveHrShowingDeviceSemantics('SampleBand'),
      contains('SampleBand'),
    );
    expect(ru.devicesResetSourceSemantics('Пульс'), contains('Пульс'));
  });

  testWidgets('card accessibility reads the same localized units as its text', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        russianPage(
          const Column(
            children: [
              SignalCard(Icons.favorite, C.red, 'Пульс', '72', unit: 'bpm'),
              DeepDiveCard('Подробности пульса', '72', 'bpm', 'Открыть', C.red),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('bpm'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Пульс, 72 уд/мин')), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Подробности пульса, 72 уд/мин')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('the live pulse status is Russian in the shared renderer', (
    tester,
  ) async {
    await tester.pumpWidget(
      russianPage(const LiveHrCard.preview(hr: 72, trace: [])),
    );
    await tester.pumpAndSettle();
    expect(find.text('LIVE'), findsNothing);
    expect(
      find.text(lookupAppLocalizations(const Locale('ru')).devicesLive),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  test('English presentation preserves original text and punctuation', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final messages =
        jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map;
    final literals = messages.entries.where(
      (entry) =>
          !entry.key.toString().startsWith('@') &&
          entry.value is String &&
          !entry.value.toString().contains('{'),
    );
    const dynamic = [
      'no sleep was scored for this day — resting HR is only ever measured over a sleep window, never over waking hours',
      'no sleep was scored for this day — resting HR is only ever measured over a sleep window, never over waking hours Your band was off your wrist 00:00 – 14:32.',
      'Too few clean beat-to-beat intervals to work this out. There were 0, and it needs 30.',
      'Your band is at 17%. Charge it soon.',
      'Recovery 63, slept 7h 12m.',
      'Provider error (429): custom provider response',
      'steps 12000 — above your usual range (usually 8000–9000)',
    ];
    for (final text in [
      ...literals.map((e) => e.value as String),
      ...dynamic,
    ]) {
      expect(localizedText(en, text), text);
      expect(presentationText(en, text), text);
      expect(coachPresentationText(en, text), text);
      expect(sweepText(en, text), text);
    }
  });

  testWidgets('an empty chart selection has a Russian screen-reader value', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        russianPage(
          Scrubber(
            value: null,
            onChanged: (_) {},
            label: 'График',
            describe: (value) => '$value',
            child: const SizedBox(width: 300, height: 50),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.byType(Scrubber)).getSemanticsData().value,
        'Ничего не выбрано',
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  test(
    'language catalogues keep canonical activity and exercise identities',
    () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        expect(l.profileTitle, isNotEmpty, reason: locale.toString());
        for (final activity in allActivities) {
          final key = activity.typeKey;
          final name = activity.name;
          expect(activity.localizedName(l), isNotEmpty);
          expect(activity.name, name);
          expect(activity.typeKey, key);
          if (locale.languageCode == 'en') {
            expect(activity.localizedName(l), name);
          }
          if (locale.languageCode == 'ru' && name != 'CrossFit') {
            expect(activity.localizedName(l), matches(RegExp('[А-Яа-яЁё]')));
          }
        }
        for (final exercise in exerciseLibrary) {
          expect(exercise.labelFor(locale.languageCode), isNotEmpty);
          expect(exerciseByKey(exercise.key), same(exercise));
        }
      }
    },
  );

  test('Russian presentation leaves unknown external content unchanged', () {
    final ru = lookupAppLocalizations(const Locale('ru'));
    const text =
        'My custom tag / device: 7h 12m; caffeine; API https://example.test';
    expect(localizedJournalTag(ru, text), text);
    expect(localizedText(ru, text), text);
    expect(presentationText(ru, text), text);
    expect(coachPresentationText(ru, text), text);
    expect(sweepText(ru, text), text);
  });
}
