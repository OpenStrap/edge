// CoachActions — what the coach's tools actually do.
//
// The engine owns the loop, the schema and the confirmation gate; this file
// owns the stores. It is separate for two reasons: `coach_engine.dart` was
// already the longest file in `lib/coach`, and a tool body that talks to a
// table is the part worth testing without a provider.
//
// Two rules every function here keeps:
//
//   • IT WRITES, OR IT THROWS. Nothing returns a cheerful string on a path that
//     stored nothing — that was the `set_step_goal` bug (P2), and a tool that
//     lies to the model lies to the user twice: once in the answer, once in the
//     summary it just confirmed.
//   • THE MODEL IS AN UNTRUSTED CALLER. Dates, meals, times and dose windows are
//     validated here rather than at the schema, because an OpenAI-compatible
//     provider will send you `"meal": "brunch"` and `"date": "yesterday"`.
//
// Reads live here too (nutrition, medication) because neither is in the coach's
// SQL views: `run_sql` reaches derived health views ONLY, and widening that
// allow-list to reach food and dose tables would trade a hard structural
// boundary for a soft one. A narrow typed read tool costs nothing and keeps
// `coach_db`'s btree gate exactly as it is.

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../data/day_label.dart';
import '../data/journal_fields.dart';
import '../data/local_repository.dart';
import '../data/med_store.dart';
import '../data/nutrition_store.dart';
import '../health/health_export.dart';

/// Raised when the model's arguments cannot be honoured. The message goes back
/// into the transcript so the model can correct itself rather than retrying the
/// same call.
class CoachActionError implements Exception {
  final String message;
  CoachActionError(this.message);
  @override
  String toString() => message;
}

class CoachActions {
  CoachActions._();

  // ── argument coercion ──────────────────────────────────────────────────────

  static String str(Object? v) => v == null ? '' : v.toString().trim();

  static double? num_(Object? v) {
    if (v == null) return null;
    if (v is num) return v.isFinite ? v.toDouble() : null;
    return double.tryParse(v.toString().trim());
  }

  /// A local day label, defaulting to today. Rejects anything that is not
  /// `YYYY-MM-DD` — a relative word ("yesterday") stored verbatim would key a
  /// row nothing can ever read back. Also rejects a calendar-invalid date
  /// (e.g. "2026-02-30"): `DateTime` silently normalizes out-of-range
  /// components instead of throwing, so `epochOf` would land on a different
  /// real day than the string stored here.
  static String day(Object? v, {DateTime? now}) {
    final s = str(v);
    if (s.isEmpty) return todayLabel(now ?? DateTime.now());
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
    if (m == null) {
      throw CoachActionError(
        'Date "$s" is not a day. Use YYYY-MM-DD (today is '
        '${todayLabel(now ?? DateTime.now())}).',
      );
    }
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final da = int.parse(m.group(3)!);
    final d = DateTime(y, mo, da);
    if (d.year != y || d.month != mo || d.day != da) {
      throw CoachActionError('Date "$s" is not a real calendar day.');
    }
    return s;
  }

  /// `HH:MM` on a 24-hour clock → minutes from midnight.
  static int minuteOfDay(Object? v) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(str(v));
    if (m == null) {
      throw CoachActionError('Time "${str(v)}" is not HH:MM on a 24-h clock.');
    }
    final h = int.parse(m.group(1)!), mi = int.parse(m.group(2)!);
    if (h > 23 || mi > 59) {
      throw CoachActionError('Time "${str(v)}" is not a real time of day.');
    }
    return h * 60 + mi;
  }

  /// Local wall-clock date + time → epoch SECONDS, through `DateTime` so a DST
  /// boundary lands where the user's clock says it does.
  static int epochOf(String date, int minute) {
    final p = date.split('-');
    final d = DateTime(
      int.parse(p[0]),
      int.parse(p[1]),
      int.parse(p[2]),
      minute ~/ 60,
      minute % 60,
    );
    return d.millisecondsSinceEpoch ~/ 1000;
  }

  // ── nutrition ──────────────────────────────────────────────────────────────

  /// One day of food: every entry, plus the totals the app itself computes.
  ///
  /// The totals come from `rollupDay`, not from summing here, so the coach sees
  /// the same number the Nutrition screen shows — including its FLOOR flag, the
  /// one thing a naive sum destroys (a day with one unlabelled item has a total
  /// that is a lower bound, not a total).
  static Future<String> nutritionDay(Database db, Object? date) async {
    final d = day(date);
    final entries = await NutritionDb.entriesForDay(db, d);
    final roll = rollupDay(d, entries, today: todayLabel());
    Map<String, Object?> total(NutrientTotal t) => {
      'value': t.value,
      if (t.isFloor) 'is_floor': true,
      if (t.unknown > 0) 'entries_missing_it': t.unknown,
    };
    return jsonEncode({
      'date': d,
      'logged': roll.logged,
      'entries': [
        for (final e in entries)
          {
            'meal': e.meal,
            'label': e.label,
            if (e.quantity != null) 'quantity': e.quantity,
            if (e.quantity != null) 'unit': e.unit,
            'kcal': e.kcal,
            'protein_g': e.proteinG,
            'carbs_g': e.carbsG,
            'fat_g': e.fatG,
            'fibre_g': e.fibreG,
            if (e.note.isNotEmpty) 'note': e.note,
          },
      ],
      'totals': {
        'kcal': total(roll.kcal),
        'protein_g': total(roll.protein),
        'carbs_g': total(roll.carbs),
        'fat_g': total(roll.fat),
        'fibre_g': total(roll.fibre),
      },
    });
  }

  /// Log one thing eaten. Every nutrient is optional: an eating occasion with
  /// no numbers is a complete, valid log, and inventing a calorie figure to
  /// fill the column is the one thing this must never do.
  static Future<String> logFood(Database db, Map<String, dynamic> a) async {
    final d = day(a['date']);
    final label = str(a['label']);
    if (label.isEmpty) throw CoachActionError('A food needs a name.');
    final meal = str(a['meal']).toLowerCase();
    if (!kMeals.contains(meal)) {
      throw CoachActionError(
        'Meal "$meal" is not one of ${kMeals.join(', ')}.',
      );
    }
    final at = str(a['time']).isEmpty ? null : minuteOfDay(a['time']);
    final e = FoodEntry(
      id: NutritionDb.newId(),
      date: d,
      meal: meal,
      label: label,
      atTs: at == null ? null : epochOf(d, at),
      quantity: num_(a['quantity']),
      unit: str(a['unit']).isEmpty ? 'g' : str(a['unit']),
      kcal: num_(a['kcal']),
      proteinG: num_(a['protein_g']),
      carbsG: num_(a['carbs_g']),
      fatG: num_(a['fat_g']),
      fibreG: num_(a['fibre_g']),
      sugarG: num_(a['sugar_g']),
      satFatG: num_(a['sat_fat_g']),
      sodiumMg: num_(a['sodium_mg']),
      ironMg: num_(a['iron_mg']),
      calciumMg: num_(a['calcium_mg']),
      // `manual` and confirmed: the user approved this exact entry at the
      // confirmation gate, which is what `confirmed` records. It is NOT
      // `verified` — that word means a manufacturer or USDA record, and a
      // number the model recalled is not one.
      source: FoodSource.manual,
      confirmed: true,
      note: str(a['note']),
    );
    await NutritionDb.put(db, e);
    return jsonEncode({
      'saved': true,
      'date': d,
      'meal': meal,
      'label': label,
      'kcal': e.kcal,
    });
  }

  // ── journal numbers (water, mood, and the rest) ────────────────────────────

  /// Write one or more numeric journal fields for a day.
  ///
  /// `postJournalMetrics` replaces the WHOLE day — "the map IS the day, not a
  /// patch on it" — so the stored day is read first and merged. Without that,
  /// logging water at lunch would silently erase the morning's mood.
  ///
  /// Water is loggable here and is scored NOWHERE. There is no hydration score
  /// in this app and there is not going to be one.
  static Future<String> logJournalFields(
    LocalRepository repo,
    Map<String, dynamic> a,
  ) async {
    final d = day(a['date']);
    final raw = a['fields'];
    if (raw is! Map || raw.isEmpty) {
      throw CoachActionError('No fields given.');
    }
    final known = {for (final f in await repo.getJournalFields()) f.key: f};
    final at = str(a['time']).isEmpty ? null : minuteOfDay(a['time']);
    final merged = {...await repo.getJournalMetrics(d)};
    final written = <String>[];
    for (final e in raw.entries) {
      final key = str(e.key);
      final spec = known[key];
      if (spec == null) {
        throw CoachActionError(
          'There is no journal field "$key". Known fields: '
          '${known.keys.join(', ')}.',
        );
      }
      final v = num_(e.value);
      if (v == null) {
        throw CoachActionError('Field "$key" needs a number.');
      }
      merged[key] = JournalMetricValue(
        v,
        atMinuteOfDay: spec.hasTime ? at : null,
      );
      written.add(key);
    }
    await repo.postJournalMetrics(d, merged);
    return jsonEncode({'saved': true, 'date': d, 'fields': written});
  }

  // ── workouts ───────────────────────────────────────────────────────────────

  /// Log a workout that ALREADY HAPPENED.
  ///
  /// The only workout tools before this were start/end, which cannot express
  /// "I ran this morning" — the model had to either refuse or start a live
  /// session at the wrong time. The window is scored from the 1 Hz substrate by
  /// the repository; a window with no substrate behind it is still saved, just
  /// unscored, and the result says which.
  static Future<String> addCompletedWorkout(
    LocalRepository repo,
    Map<String, dynamic> a,
  ) async {
    final d = day(a['date']);
    final start = minuteOfDay(a['start_time']);
    final mins = num_(a['duration_min'])?.round();
    if (mins == null || mins <= 0) {
      throw CoachActionError('A completed workout needs a duration in minutes.');
    }
    final type = str(a['type']).isEmpty ? 'other' : str(a['type']).toLowerCase();
    final startTs = epochOf(d, start);
    try {
      final r = await repo.logManualWorkout(
        startTs: startTs,
        endTs: startTs + mins * 60,
        type: type,
      );
      // Every other write path exports; without this a workout logged through
      // the coach reached the health store only if the next day-result pass
      // happened to sweep it up (#130). The seam checks `healthSyncEnabled`
      // itself, so this is a no-op with the switch off, and it never throws.
      await HealthExporter.exportWorkoutId(r['workout_id'] as String?);
      return jsonEncode({'saved': true, 'date': d, 'type': type, ...r});
    } catch (e) {
      // The repo rejects overlaps, futures and absurd durations. Hand the
      // reason back verbatim so the model corrects the window instead of
      // telling the user it worked.
      throw CoachActionError('That window was rejected: $e');
    }
  }

  // ── medication ─────────────────────────────────────────────────────────────

  /// Every scheduled medication, with today's doses and their state.
  static Future<String> medications(Database db, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    final d = todayLabel(at);
    final defs = await MedDb.defs(db);
    final slots = slotsForDay(defs, d, await MedDb.dosesForDay(db, d), now: at);
    return jsonEncode({
      'date': d,
      'medications': [
        for (final def in defs)
          {
            'name': def.label,
            'dose': def.doseLabel,
            'schedule': [
              for (final s in def.schedule)
                {
                  'time':
                      '${(s.minuteOfDay ~/ 60).toString().padLeft(2, '0')}:'
                      '${(s.minuteOfDay % 60).toString().padLeft(2, '0')}',
                  'weekdays': s.days.isEmpty ? [1, 2, 3, 4, 5, 6, 7] : s.days,
                },
            ],
          },
      ],
      'today': [
        for (final s in slots)
          {'name': s.def.label, 'time': s.timeLabel, 'state': s.state.name},
      ],
    });
  }

  /// Add (or replace) a medication schedule.
  ///
  /// [weekdays] are `DateTime.weekday` values, 1 = Monday. They are REQUIRED in
  /// spirit and default to every day only because that is what most schedules
  /// are — the user can change them on the Wellness screen, which is the
  /// precondition this tool waited on: an AI that writes a schedule the person
  /// cannot correct is worse than no tool at all.
  static Future<String> addMedication(
    Database db,
    Map<String, dynamic> a,
  ) async {
    final name = str(a['name']);
    if (name.isEmpty) throw CoachActionError('A medication needs a name.');
    final minute = minuteOfDay(a['time']);
    final days = <int>{
      for (final d in (a['weekdays'] as List? ?? const []))
        if (num_(d) != null) num_(d)!.round(),
    }..removeWhere((d) => d < 1 || d > 7);
    final dose = num_(a['dose_value']);
    final key = MedDb.keyFor(name);
    // ADD, not replace. `putDef` writes the whole row, so building a fresh
    // MedDef here meant a second "add paracetamol at 22:00" silently deleted
    // the 08:00 and 14:00 doses already on it — and blanked the dose, unit,
    // kind and note whenever the model did not resend them. An assistant that
    // destroys a medication schedule as a side effect of adding to it is worse
    // than one with no tool at all.
    final existing = (await MedDb.defs(db, activeOnly: false))
        .where((d) => d.key == key)
        .firstOrNull;
    final slot = MedSchedule(
      minute,
      days.isEmpty ? const [1, 2, 3, 4, 5, 6, 7] : (days.toList()..sort()),
    );
    // Same time of day twice is one entry, with the newer day-set winning —
    // that is how a person edits which days a dose falls on.
    final schedule = [
      ...?existing?.schedule.where((e) => e.minuteOfDay != minute),
      slot,
    ]..sort((x, y) => x.minuteOfDay.compareTo(y.minuteOfDay));
    await MedDb.putDef(
      db,
      MedDef(
        key: key,
        label: name,
        doseValue: dose ?? existing?.doseValue,
        doseUnit: str(a['dose_unit']).isEmpty
            ? (existing?.doseUnit ?? '')
            : str(a['dose_unit']),
        kind: str(a['kind']).isEmpty
            ? (existing?.kind ?? 'medication')
            : (str(a['kind']) == 'supplement' ? 'supplement' : 'medication'),
        schedule: schedule,
        note: existing?.note ?? '',
        active: existing?.active ?? true,
        createdAt: existing?.createdAt,
      ),
    );
    return jsonEncode({
      'saved': true,
      'name': name,
      'weekdays': days.isEmpty ? [1, 2, 3, 4, 5, 6, 7] : (days.toList()..sort()),
    });
  }

  /// Record what happened to one scheduled dose.
  ///
  /// `skipped` and `not_taken` are different facts and both are storable — the
  /// distinction the store was built for and the UI could not enter until now.
  static Future<String> markMedication(
    Database db,
    Map<String, dynamic> a,
  ) async {
    final name = str(a['name']);
    final defs = await MedDb.defs(db);
    MedDef? def;
    for (final x in defs) {
      if (x.label.toLowerCase() == name.toLowerCase()) def = x;
    }
    if (def == null) {
      throw CoachActionError(
        'No medication called "$name". Known: '
        '${defs.map((d) => d.label).join(', ')}.',
      );
    }
    final d = day(a['date']);
    final slot = str(a['time']).isEmpty
        ? (def.schedule.isEmpty ? null : def.schedule.first.minuteOfDay)
        : minuteOfDay(a['time']);
    if (slot == null) {
      throw CoachActionError('"$name" has no scheduled time to mark.');
    }
    final state = str(a['state']).toLowerCase();
    if (!const ['taken', 'skipped', 'not_taken'].contains(state)) {
      throw CoachActionError('State must be taken, skipped or not_taken.');
    }
    await MedDb.mark(
      db,
      medKey: def.key,
      date: d,
      slotMin: slot,
      taken: state == 'taken',
      skipped: state == 'skipped',
    );
    return jsonEncode({
      'saved': true,
      'name': def.label,
      'date': d,
      'state': state,
    });
  }
}
