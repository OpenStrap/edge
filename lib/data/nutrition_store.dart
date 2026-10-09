// Nutrition — the log, the dictionary, and the day rollup.
//
// The primary logging unit is an EATING OCCASION, not a food. A one-tap "ate"
// with no macros at all is a complete, valid log: a trial comparing detailed
// against simplified logging found 49% of days logged versus 97%, with
// identical six-month weight loss. Macro detail is an opt-in tier and never
// the onboarding path, so every nutrient column is nullable and the rollup is
// built to report what it does not know rather than to zero-fill it.
//
// NULL IS NOT ZERO. A barcode that returns protein but no fibre writes
// `fibre_g = NULL`, and any total that summed a NULL reports itself partial.
// This is the app's founding rule made physical — see db.dart:2258.
//
// Pure rollup logic lives at the bottom as top-level functions so it is
// testable without a database.

import 'package:sqflite/sqflite.dart';

import 'day_label.dart';

// ══════════════════ SCHEMA ══════════════════

/// schemaVersion 35. Two tables: a per-entry log, and a dictionary so a
/// repeat entry costs one row instead of re-typing the macros.
Future<void> createNutritionTables(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS food_entry (
      id            TEXT PRIMARY KEY,
      date          TEXT NOT NULL,
      at_ts         INTEGER,
      meal          TEXT NOT NULL,
      food_key      TEXT,
      label         TEXT NOT NULL,
      quantity      REAL,
      unit          TEXT NOT NULL DEFAULT 'g',
      kcal          REAL,
      protein_g     REAL,
      carbs_g       REAL,
      fat_g         REAL,
      fibre_g       REAL,
      sugar_g       REAL,
      sat_fat_g     REAL,
      sodium_mg     REAL,
      iron_mg       REAL,
      calcium_mg    REAL,
      source        TEXT NOT NULL DEFAULT 'manual',
      confirmed     INTEGER NOT NULL DEFAULT 0,
      note          TEXT NOT NULL DEFAULT '',
      created_at    INTEGER NOT NULL,
      updated_at    INTEGER NOT NULL
    )
  ''');
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_food_entry_date ON food_entry(date, at_ts)',
  );
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_food_entry_food ON food_entry(food_key, date)',
  );
  await db.execute('''
    CREATE TABLE IF NOT EXISTS food_def (
      key            TEXT PRIMARY KEY,
      label          TEXT NOT NULL,
      brand          TEXT NOT NULL DEFAULT '',
      serving_g      REAL,
      serving_label  TEXT NOT NULL DEFAULT '',
      kcal_100       REAL,
      protein_g_100  REAL,
      carbs_g_100    REAL,
      fat_g_100      REAL,
      fibre_g_100    REAL,
      sugar_g_100    REAL,
      sat_fat_g_100  REAL,
      sodium_mg_100  REAL,
      iron_mg_100    REAL,
      calcium_mg_100 REAL,
      source         TEXT NOT NULL DEFAULT 'manual',
      created_at     INTEGER NOT NULL
    )
  ''');
}

// ══════════════════ MODEL ══════════════════

/// Where an entry's numbers came from. Rendered on every row, because a
/// manufacturer panel and a guess are not the same claim.
enum FoodSource {
  /// Typed by the user, or logged as a bare occasion with no numbers.
  manual,

  /// Read off a manufacturer or USDA panel. The only VERIFIED tier.
  verified,

  /// Filled from a barcode scanned against Open Food Facts, then edited by
  /// the user if they chose to.
  ///
  /// NOT [verified], and the difference is load-bearing. OFF is crowd-sourced:
  /// about 6% of its products carrying nutrition data hold a physically
  /// impossible value, ~20% among the most-scanned. [isVerified] gates search
  /// ranking, so calling this verified would promote exactly that data above
  /// numbers the user read off the pack themselves. It is input, never a
  /// measurement — their own terms say the data is not for medical use.
  barcode,

  /// Copied from an earlier entry of the same food.
  repeat,

  /// Identified from a photo. NEVER carries an energy total — see
  /// [FoodEntry.sanitised].
  photo,
}

FoodSource _sourceOf(String s) => switch (s) {
  'verified' => FoodSource.verified,
  'barcode' => FoodSource.barcode,
  'repeat' => FoodSource.repeat,
  'photo' => FoodSource.photo,
  _ => FoodSource.manual,
};

/// Whether a source counts as manufacturer/USDA-backed. Search ranks on this,
/// never on how often something was picked — popularity ranking quietly
/// promotes whichever wrong entry got tapped first.
bool isVerified(FoodSource s) => s == FoodSource.verified;

const kMeals = <String>['breakfast', 'lunch', 'dinner', 'snack'];

class FoodEntry {
  const FoodEntry({
    required this.id,
    required this.date,
    required this.meal,
    required this.label,
    this.atTs,
    this.foodKey,
    this.quantity,
    this.unit = 'g',
    this.kcal,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.fibreG,
    this.sugarG,
    this.satFatG,
    this.sodiumMg,
    this.ironMg,
    this.calciumMg,
    this.source = FoodSource.manual,
    this.confirmed = false,
    this.note = '',
  });

  final String id;

  /// Local day label, 'YYYY-MM-DD'.
  final String date;
  final String meal;
  final String label;

  /// Epoch SECONDS. Null means the time was not recorded, which costs the day
  /// its span check — see [dayLogState].
  final int? atTs;
  final String? foodKey;

  /// Null means the portion was never confirmed.
  final double? quantity;
  final String unit;

  final double? kcal,
      proteinG,
      carbsG,
      fatG,
      fibreG,
      sugarG,
      satFatG,
      sodiumMg,
      ironMg,
      calciumMg;

  final FoodSource source;
  final bool confirmed;
  final String note;

  /// A bare eating occasion: logged, but with no energy attached. Complete and
  /// valid as a log; it just cannot contribute to an energy average.
  bool get isBareOccasion => kcal == null;

  /// The write-time guard. A photo cannot produce a calorie total: AI photo
  /// estimation misses roughly a third of calories in controlled testing, and
  /// a number that wrong is worse than an honest absence. Until the user
  /// confirms a portion, a photo entry keeps its identified label and nothing
  /// else.
  FoodEntry get sanitised => (source == FoodSource.photo && !confirmed)
      ? FoodEntry(
          id: id,
          date: date,
          meal: meal,
          label: label,
          atTs: atTs,
          foodKey: foodKey,
          unit: unit,
          source: source,
          note: note,
        )
      : this;

  Map<String, Object?> toRow(int nowMs) => {
    'id': id,
    'date': date,
    'at_ts': atTs,
    'meal': meal,
    'food_key': foodKey,
    'label': label,
    'quantity': quantity,
    'unit': unit,
    'kcal': kcal,
    'protein_g': proteinG,
    'carbs_g': carbsG,
    'fat_g': fatG,
    'fibre_g': fibreG,
    'sugar_g': sugarG,
    'sat_fat_g': satFatG,
    'sodium_mg': sodiumMg,
    'iron_mg': ironMg,
    'calcium_mg': calciumMg,
    'source': source.name,
    'confirmed': confirmed ? 1 : 0,
    'note': note,
    'created_at': nowMs,
    'updated_at': nowMs,
  };

  static FoodEntry fromRow(Map<String, Object?> r) {
    double? d(String k) => (r[k] as num?)?.toDouble();
    return FoodEntry(
      id: r['id'] as String,
      date: r['date'] as String,
      meal: r['meal'] as String,
      label: r['label'] as String,
      atTs: (r['at_ts'] as num?)?.toInt(),
      foodKey: r['food_key'] as String?,
      quantity: d('quantity'),
      unit: (r['unit'] as String?) ?? 'g',
      kcal: d('kcal'),
      proteinG: d('protein_g'),
      carbsG: d('carbs_g'),
      fatG: d('fat_g'),
      fibreG: d('fibre_g'),
      sugarG: d('sugar_g'),
      satFatG: d('sat_fat_g'),
      sodiumMg: d('sodium_mg'),
      ironMg: d('iron_mg'),
      calciumMg: d('calcium_mg'),
      source: _sourceOf((r['source'] as String?) ?? 'manual'),
      confirmed: ((r['confirmed'] as num?)?.toInt() ?? 0) == 1,
      note: (r['note'] as String?) ?? '',
    );
  }
}

/// One nutrient summed across a day, carrying how much of the day it could
/// not see. [value] null means nothing in the day reported this nutrient at
/// all — categorically different from "the day totalled zero grams".
class NutrientTotal {
  const NutrientTotal(this.value, this.known, this.unknown);
  final double? value;
  final int known, unknown;

  /// Every entry reported it. Only a complete total may feed an average.
  bool get complete => known > 0 && unknown == 0;

  /// Some entries reported it and some did not, so the total is a FLOOR.
  bool get isFloor => known > 0 && unknown > 0;
}

NutrientTotal _sum(List<FoodEntry> es, double? Function(FoodEntry) pick) {
  var total = 0.0;
  var known = 0, unknown = 0;
  for (final e in es) {
    final v = pick(e);
    if (v == null) {
      unknown++;
    } else {
      total += v;
      known++;
    }
  }
  return NutrientTotal(known == 0 ? null : total, known, unknown);
}

/// How much of a day's eating we can honestly claim to have seen.
enum DayLogState {
  /// Nothing logged.
  none,

  /// Today, still in progress. Neither complete nor partial — a day cannot be
  /// judged incomplete while it is still happening.
  inProgress,

  /// Logged, but with a gap we can detect: an unknown energy value, or no
  /// occasion in the evening. EXCLUDED from every derived average, and the UI
  /// says so.
  partial,

  /// Every occasion carries energy and the day's span reaches the evening.
  complete,
}

/// The hour after which a finished day is taken to have been logged through to
/// the end. A calibration knob, not a physiological claim: shift-workers and
/// early eaters will trip it, which is exactly why the UI states the rule
/// rather than hiding it.
const int kEveningLogHour = 17;

/// One day, rolled up. Built by [rollupDay] — never by the UI.
class NutritionDay {
  const NutritionDay({
    required this.date,
    required this.entries,
    required this.state,
    required this.kcal,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.fibre,
  });

  final String date;
  final List<FoodEntry> entries;
  final DayLogState state;
  final NutrientTotal kcal, protein, carbs, fat, fibre;

  bool get logged => entries.isNotEmpty;

  /// Only a complete day may move an average. A partial day left in would
  /// drag every mean down by exactly the meals we failed to see.
  bool get countsTowardAverages => state == DayLogState.complete;

  List<FoodEntry> mealEntries(String meal) => [
    for (final e in entries)
      if (e.meal == meal) e,
  ];
}

/// Roll a day up. [today] is the local day label of the current day, so
/// "in progress" is decided by the caller's clock and never by a hidden one.
NutritionDay rollupDay(
  String date,
  List<FoodEntry> entries, {
  required String today,
}) {
  final kcal = _sum(entries, (e) => e.kcal);
  final state = dayLogState(date, entries, today: today, kcal: kcal);
  return NutritionDay(
    date: date,
    entries: entries,
    state: state,
    kcal: kcal,
    protein: _sum(entries, (e) => e.proteinG),
    carbs: _sum(entries, (e) => e.carbsG),
    fat: _sum(entries, (e) => e.fatG),
    fibre: _sum(entries, (e) => e.fibreG),
  );
}

/// Partial-day detection. Automatic and never a checkbox — a user who has to
/// tick "I didn't log everything" will not, and every average silently rots.
DayLogState dayLogState(
  String date,
  List<FoodEntry> entries, {
  required String today,
  NutrientTotal? kcal,
}) {
  if (entries.isEmpty) return DayLogState.none;
  if (date == today) return DayLogState.inProgress;
  final energy = kcal ?? _sum(entries, (e) => e.kcal);
  if (!energy.complete) return DayLogState.partial;
  final spanned = entries.any((e) {
    final ts = e.atTs;
    if (ts == null) return false;
    return DateTime.fromMillisecondsSinceEpoch(ts * 1000).hour >=
        kEveningLogHour;
  });
  return spanned ? DayLogState.complete : DayLogState.partial;
}

/// One nutrient averaged across a window, with what was left out of it.
/// [value] null is an absence with a reason attached, never a zero: either no
/// counted day reported the nutrient at all ([floorDays] 0), or every one that
/// did reported only a floor.
class NutrientMean {
  const NutrientMean(this.value, this.days, this.floorDays);

  /// The mean of [days] COMPLETE totals, or null when there were none.
  final double? value;

  /// How many counted days reported this nutrient on every occasion. This is
  /// the denominator the screen must name — it can be smaller than the number
  /// of counted days, which is the whole point.
  final int days;

  /// Counted days whose total was a floor, so excluded. Averaging a floor
  /// understates the mean by exactly the occasions we failed to see.
  final int floorDays;
}

/// A rolling window. Daily is the detail view; THIS is the hero — one day of
/// intake is noise, seven is a habit.
class NutritionWindow {
  const NutritionWindow(this.days);
  final List<NutritionDay> days;

  int get span => days.length;
  int get daysLogged => days.where((d) => d.logged).length;
  List<NutritionDay> get counted =>
      [for (final d in days) if (d.countsTowardAverages) d];

  /// Days that were logged but had to be excluded. Named on screen, because
  /// an average quietly computed over four of seven days is a lie of omission.
  int get daysExcluded =>
      days.where((d) => d.logged && !d.countsTowardAverages).length;

  /// One nutrient's mean over the counted days, gated PER NUTRIENT.
  ///
  /// [NutritionDay.countsTowardAverages] is an ENERGY rule: a day qualifies on
  /// complete kcal and an evening occasion, and says nothing about protein. So
  /// this used to admit any non-null total — including one that summed past
  /// occasions carrying no macro figure, i.e. a FLOOR — and print it as a mean
  /// with no marker. Only [NutrientTotal.complete] totals go in; the floors are
  /// counted so the screen can say why the number is missing or built on fewer
  /// days than the energy mean.
  NutrientMean _mean(NutrientTotal Function(NutritionDay) pick) {
    final vs = <double>[];
    var floorDays = 0;
    for (final d in counted) {
      final t = pick(d);
      if (t.complete) {
        vs.add(t.value!);
      } else if (t.isFloor) {
        floorDays++;
      }
    }
    return NutrientMean(
      vs.isEmpty ? null : vs.reduce((a, b) => a + b) / vs.length,
      vs.length,
      floorDays,
    );
  }

  /// Energy is unchanged by the per-nutrient gate — a counted day already has
  /// `kcal.complete` by definition of [DayLogState.complete] — but it goes
  /// through the same path so there is one mean, not two.
  NutrientMean get meanKcal => _mean((d) => d.kcal);
  NutrientMean get meanProtein => _mean((d) => d.protein);
  NutrientMean get meanCarbs => _mean((d) => d.carbs);
  NutrientMean get meanFat => _mean((d) => d.fat);
  NutrientMean get meanFibre => _mean((d) => d.fibre);
}

// ══════════════════ STORE ══════════════════

class NutritionDb {
  NutritionDb._();

  static String newId() => 'f${DateTime.now().microsecondsSinceEpoch}';

  /// Write one entry. [FoodEntry.sanitised] runs HERE rather than in the UI:
  /// a photo estimate must not be able to reach the table with a calorie
  /// total no matter which screen wrote it.
  static Future<void> put(Database db, FoodEntry e) async {
    await db.insert(
      'food_entry',
      e.sanitised.toRow(DateTime.now().millisecondsSinceEpoch),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Rewrite an existing entry in place: same id, same `created_at`, so it
  /// keeps its place in [recent] and a CSV export still shows when it was
  /// first logged. Totals and averages are rolled up from the table on every
  /// read, so an edit lands exactly as a delete-then-add would. Same
  /// [FoodEntry.sanitised] guard as [put].
  static Future<void> update(Database db, FoodEntry e) async {
    final row = e.sanitised.toRow(DateTime.now().millisecondsSinceEpoch)
      ..remove('created_at');
    await db.update('food_entry', row, where: 'id = ?', whereArgs: [e.id]);
  }

  static Future<void> delete(Database db, String id) =>
      db.delete('food_entry', where: 'id = ?', whereArgs: [id]);

  static Future<List<FoodEntry>> entriesForDay(Database db, String date) async {
    final rows = await db.query(
      'food_entry',
      where: 'date = ?',
      whereArgs: [date],
      orderBy: 'at_ts ASC, created_at ASC',
    );
    return [for (final r in rows) FoodEntry.fromRow(r)];
  }

  /// Every entry on or after [sinceDate], grouped by day label. Lexicographic
  /// range, matching every other day-keyed table.
  static Future<Map<String, List<FoodEntry>>> entriesSince(
    Database db,
    String sinceDate,
  ) async {
    final rows = await db.query(
      'food_entry',
      where: 'date >= ?',
      whereArgs: [sinceDate],
      orderBy: 'date ASC, at_ts ASC',
    );
    final out = <String, List<FoodEntry>>{};
    for (final r in rows) {
      final e = FoodEntry.fromRow(r);
      (out[e.date] ??= []).add(e);
    }
    return out;
  }

  /// The last distinct things eaten, newest first. This is what makes a repeat
  /// entry a two-second job, and it is why there is no need for a "favourites"
  /// concept on top.
  ///
  /// [query] narrows it to labels containing that text, over the WHOLE
  /// history rather than the last few — the search on the log sheet.
  static Future<List<FoodEntry>> recent(
    Database db, {
    int limit = 12,
    String query = '',
  }) async {
    final q = query.trim();
    final rows = await db.rawQuery(
      'SELECT * FROM food_entry WHERE id IN '
      '(SELECT MAX(id) FROM food_entry GROUP BY label) '
      "${q.isEmpty ? '' : r"AND label LIKE ? ESCAPE '\' "}"
      'ORDER BY created_at DESC LIMIT ?',
      [
        // `%` and `_` are literal text in a food name, not wildcards.
        if (q.isNotEmpty)
          '%${q.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}')}%',
        limit,
      ],
    );
    return [for (final r in rows) FoodEntry.fromRow(r)];
  }

  /// Search the dictionary, VERIFIED entries first. Ranking is provenance then
  /// alphabetical — never popularity.
  static Future<List<Map<String, Object?>>> searchFoods(
    Database db,
    String query, {
    int limit = 25,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    return db.rawQuery(
      "SELECT * FROM food_def WHERE label LIKE ? OR brand LIKE ? "
      "ORDER BY (source = 'verified') DESC, label ASC LIMIT ?",
      ['%$q%', '%$q%', limit],
    );
  }

  /// One dictionary entry by key. The key for a scanned product is its
  /// barcode, which makes this table the barcode cache — a second scan of the
  /// same packet is a local read and no network request at all.
  static Future<Map<String, Object?>?> foodDef(Database db, String key) async {
    final rows =
        await db.query('food_def', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> putFoodDef(
    Database db,
    Map<String, Object?> def,
  ) async {
    await db.insert('food_def', {
      ...def,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// The trailing [days] days ending today, oldest first, already rolled up.
  static Future<NutritionWindow> window(
    Database db, {
    int days = 7,
    DateTime? now,
  }) async {
    final end = now ?? DateTime.now();
    final today = dayLabelOf(end);
    final labels = [
      for (var i = days - 1; i >= 0; i--)
        dayLabelOf(DateTime(end.year, end.month, end.day - i)),
    ];
    final byDay = await entriesSince(db, labels.first);
    return NutritionWindow([
      for (final l in labels) rollupDay(l, byDay[l] ?? const [], today: today),
    ]);
  }
}
