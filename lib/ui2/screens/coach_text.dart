import 'package:flutter/widgets.dart';

import '../../coach/coach_actions.dart';
import '../../coach/coach_engine.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/display_text.dart';
import '../activity/catalogue.dart';

/// Presentation only: never modifies action arguments or the model transcript.
String coachActionSummary(BuildContext context, ActionRequest request) {
  final l = AppLocalizations.of(context);
  if (l == null || l.localeName == 'en') return request.summary;
  final a = request.args;
  String text(Object? v) => '$v';
  String date() =>
      a['date'] == null ? localizedText(l, 'today') : text(a['date']);
  String type() {
    final raw = text(a['type'] ?? 'workout');
    for (final activity in allActivities) {
      if (activity.typeKey == raw || activity.name == raw) {
        return activity.displayName(context);
      }
    }
    return localizedText(l, raw);
  }

  switch (request.tool) {
    case 'log_journal':
      final day = RegExp(
        r'^Add journal for ([^:]+):',
      ).firstMatch(request.summary)?[1];
      if (day == null) return request.summary;
      final tags = a['tags'];
      return l.supplementCoachJournal(
        day,
        tags is List
            ? '${tags.map((t) => localizedJournalTag(l, '$t')).toList()}'
            : text(tags ?? []),
        text(a['note'] ?? ''),
      );
    case 'log_period':
      final day = RegExp(
        r'^Log a period start on (.*?)\.$',
      ).firstMatch(request.summary)?[1];
      return day == null ? request.summary : l.supplementCoachPeriod(day);
    case 'start_workout':
      return l.supplementCoachStart(type());
    case 'end_workout':
      return localizedText(l, 'End the active workout.');
    case 'log_food':
      final name = text(a['label']);
      final meal = localizedText(l, text(a['meal']));
      return a['kcal'] == null
          ? l.supplementCoachFood(name, meal, date())
          : l.supplementCoachFoodEnergy(name, meal, date(), text(a['kcal']));
    case 'log_journal_fields':
      final fields = a['fields'];
      final description = fields is! Map || fields.isEmpty
          ? localizedText(l, 'nothing')
          : fields.entries
                .map(
                  (e) =>
                      '${localizedText(l, e.key.toString().replaceAll('_', ' '))} ${e.value}',
                )
                .join(', ');
      return l.supplementCoachFields(description, date());
    case 'add_completed_workout':
      return l.supplementCoachCompleted(
        text(a['duration_min']),
        type(),
        text(a['start_time']),
        date(),
      );
    case 'add_medication':
      final names = [
        l.wellnessMon,
        l.wellnessTue,
        l.wellnessWed,
        l.wellnessThu,
        l.wellnessFri,
        l.wellnessSat,
        l.wellnessSun,
      ];
      final raw = a['weekdays'];
      final days = CoachActions.medicationWeekdays(raw is List ? raw : null);
      final description = days.length == 7
          ? localizedText(l, 'every day')
          : days.map((d) => names[d - 1]).join(', ');
      return l.supplementCoachMedication(
        text(a['name']),
        text(a['time']),
        description,
      );
    case 'mark_medication':
      return l.supplementCoachDose(
        text(a['name']),
        date(),
        localizedText(l, text(a['state'])),
      );
    case 'set_step_goal':
      return l.supplementCoachStepGoal(text(a['goal']));
    default:
      return request.summary;
  }
}

String coachPresentationText(AppLocalizations? l, String text) {
  if (l == null || l.localeName == 'en') return text;
  final literal = localizedText(l, text);
  if (literal != text) return literal;
  final provider = RegExp(
    r'^Provider error \((.*?)\): (.*)$',
    dotAll: true,
  ).firstMatch(text);
  if (provider != null) {
    return l.supplementCoachProviderError(provider[1]!, provider[2]!);
  }
  final models = RegExp(
    r'^Models request failed \((.*?)\): (.*)$',
    dotAll: true,
  ).firstMatch(text);
  if (models != null) {
    return l.supplementCoachModelsError(models[1]!, models[2]!);
  }
  final size = RegExp(
    r'^That request grew to (\d+) KB, over the (\d+) KB safety limit for data leaving this device\. Start a new chat or ask a narrower question \(aggregate with AVG/MIN/MAX/COUNT instead of selecting every row\)\.$',
  ).firstMatch(text);
  if (size != null) return l.supplementCoachOversize(size[1]!, size[2]!);
  final rendering = RegExp(r'^Rendering (.*?)…$').firstMatch(text);
  if (rendering != null) {
    return l.supplementCoachRendering(localizedText(l, rendering[1]!));
  }
  return text;
}
