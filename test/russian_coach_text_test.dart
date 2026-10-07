import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/app_localizations_ru.dart';
import 'package:openstrap_edge/ui2/screens/coach_text.dart';

void main() {
  test('owned provider errors localize while server details stay verbatim', () {
    final l = AppLocalizationsRu();
    expect(
      coachPresentationText(l, 'Provider error (429): provider detail'),
      'Ошибка провайдера (429): provider detail',
    );
    expect(
      coachPresentationText(l, 'Empty response from provider.'),
      'Провайдер вернул пустой ответ.',
    );
    expect(
      coachPresentationText(l, 'a user or model sentence'),
      'a user or model sentence',
    );
    expect(
      coachPresentationText(
        l,
        'That request grew to 401 KB, over the 400 KB safety limit for data leaving this device. Start a new chat or ask a narrower question (aggregate with AVG/MIN/MAX/COUNT instead of selecting every row).',
      ),
      contains('превысил предел 400 КБ'),
    );
  });

  testWidgets(
    'action confirmations preserve arguments and medication cautions',
    (tester) async {
      final requests = [
        ActionRequest(
          tool: 'log_journal',
          title: 'Log journal',
          summary: 'Add journal for 2026-10-05: tags [], note "original note".',
          args: {'note': 'original note'},
        ),
        ActionRequest(
          tool: 'log_period',
          title: 'Log period',
          summary: 'Log a period start on 2026-10-05.',
          args: {},
        ),
        ActionRequest(
          tool: 'start_workout',
          title: 'Start workout',
          summary: '',
          args: {'type': 'running'},
        ),
        ActionRequest(
          tool: 'end_workout',
          title: 'End workout',
          summary: '',
          args: {},
        ),
        ActionRequest(
          tool: 'log_food',
          title: 'Log food',
          summary: '',
          args: {'label': 'Original food', 'meal': 'lunch', 'kcal': 240},
        ),
        ActionRequest(
          tool: 'log_journal_fields',
          title: 'Log how the day went',
          summary: '',
          args: {
            'fields': {'water_ml': 500, 'mood': 4},
          },
        ),
        ActionRequest(
          tool: 'add_completed_workout',
          title: 'Log a workout',
          summary: '',
          args: {'duration_min': 30, 'type': 'running', 'start_time': '09:30'},
        ),
        ActionRequest(
          tool: 'add_medication',
          title: 'Add a medication',
          summary: '',
          args: {
            'name': 'Original medication',
            'time': '08:15',
            'weekdays': [1, 3, 5],
          },
        ),
        ActionRequest(
          tool: 'mark_medication',
          title: 'Mark a dose',
          summary: '',
          args: {'name': 'Original medication', 'state': 'not_taken'},
        ),
        ActionRequest(
          tool: 'set_step_goal',
          title: 'Set step goal',
          summary: '',
          args: {'goal': 9000},
        ),
      ];
      final rendered = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              rendered.clear();
              rendered.addAll(
                requests.map((request) => coachActionSummary(context, request)),
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final sentence in rendered) {
        expect(sentence, matches(RegExp('[А-Яа-яЁё]')));
      }
      expect(rendered[0], contains('original note'));
      expect(rendered[0], contains('2026-10-05'));
      expect(rendered[2], contains('Бег'));
      expect(rendered[4], contains('Original food'));
      expect(rendered[5], contains('500'));
      expect(rendered[7], contains('Original medication'));
      expect(rendered[7], contains('не проверяет взаимодействие лекарств'));
      expect(rendered[7], isNot(contains('Mon')));
      expect(rendered[8], contains('не принято'));
      expect(requests[7].args['time'], '08:15');
      expect(requests[8].args['state'], 'not_taken');
    },
  );
}
