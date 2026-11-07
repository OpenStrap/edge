// Where the metric-detail "Journal marks" come from.
//
// The pure half ([journalAnnotations]) runs already-read rows through the day
// timeline's own join ([dayMoments]), so a mark is named exactly as the day
// page names it. The IO half ([loadAnnotations]) only reads rows. A source that
// returned nothing contributes nothing, and a meal or journal field with no
// clock time is not a mark: nothing is placed at a time it does not have.
//
// Sources: workouts, timed meals and timed journal fields. Naps are not read
// here: a detected nap lives inside a derived day, and a range read of those
// would cost one day-result decode per day of the window.

import 'package:flutter/foundation.dart';

import '../../data/day_label.dart';
import '../../data/db.dart';
import '../../data/journal_fields.dart';
import '../../data/nutrition_store.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'day_timeline.dart';

/// The annotations of the local days [from]..[to] inclusive from already-read
/// rows. Domain: epoch seconds. Pure.
List<ChartAnnotation> journalAnnotations({
  required String from,
  required String to,
  List<Map<String, dynamic>> sessions = const [],
  Map<String, List<FoodEntry>> mealsByDay = const {},
  Map<String, Map<String, JournalMetricValue>> journalByDay = const {},
  List<JournalFieldSpec> fields = kJournalFields,
  AppLocalizations? l,
}) {
  String dayOfTs(num ts) =>
      dayLabelOf(DateTime.fromMillisecondsSinceEpoch(ts.toInt() * 1000));
  bool inRange(String d) => d.compareTo(from) >= 0 && d.compareTo(to) <= 0;
  final days = <String>{
    ...mealsByDay.keys,
    ...journalByDay.keys,
    for (final s in sessions)
      if (s['start_ts'] case final num ts) dayOfTs(ts),
  }.where(inRange).toList()
    ..sort();

  final out = <ChartAnnotation>[];
  for (final day in days) {
    final start = localDayStartSec(day);
    if (start == null) continue;
    final moments = dayMoments(
      timeline: {
        'day_start': start,
        'sessions': [
          for (final s in sessions)
            if (s['start_ts'] case final num ts when dayOfTs(ts) == day) s,
        ],
      },
      meals: [for (final m in mealsByDay[day] ?? const <FoodEntry>[]) m.sanitised],
      journal: journalByDay[day] ?? const {},
      fields: fields,
      l: l,
    );
    // Two moments can share a second, and ids repeat across days: day, kind and
    // time, plus an index when they still collide.
    final used = <String, int>{};
    for (final m in moments) {
      final kind = m.annotationKind;
      if (kind == null) continue;
      final base = '$day/${kind.name}:${m.at}';
      final n = used[base] = (used[base] ?? -1) + 1;
      final end = m.until;
      out.add(ChartAnnotation(
        id: n == 0 ? base : '$base#$n',
        kind: kind,
        at: m.at.toDouble(),
        until: end != null && end > m.at ? end.toDouble() : null,
        label: m.title,
      ));
    }
  }
  return out;
}

/// The real reader. Never throws: a store that cannot be read leaves the chart
/// without marks, which is a smaller claim, not a wrong one.
Future<List<ChartAnnotation>> loadAnnotations(String from, String to,
    {AppLocalizations? l}) async {
  try {
    final lo = localDayStartSec(from), hi = localDayEndSec(to);
    if (lo == null || hi == null) return const [];
    final db = await LocalDb.instance;
    final sessions = await LocalDb.sessionsInRange(lo, hi - 1);
    final meals = await NutritionDb.entriesSince(db, from);
    final journal = await LocalDb.journalMetricsByDay(sinceDaysEpoch: from);
    final defs = await LocalDb.journalFieldDefs();
    return journalAnnotations(
      from: from,
      to: to,
      sessions: sessions,
      mealsByDay: meals,
      journalByDay: journal,
      fields: [...kJournalFields, ...defs],
      l: l,
    );
  } catch (e) {
    debugPrint('journal annotations: $e');
    return const [];
  }
}
