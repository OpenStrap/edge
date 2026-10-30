// The weekly energy balance subtracted today's running burn from a mean of
// whole days eaten, so a maintenance week read as a large surplus every
// morning. These pin that both sides now come from the same whole days.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/nutrition_store.dart';

FoodEntry _entry(String date, double? kcal, int hour) {
  final p = date.split('-').map(int.parse).toList();
  return FoodEntry(
    id: '$date-$hour',
    date: date,
    meal: hour < 11 ? 'breakfast' : 'dinner',
    label: 'Something',
    atTs: DateTime(p[0], p[1], p[2], hour).millisecondsSinceEpoch ~/ 1000,
    kcal: kcal,
  );
}

/// A complete day: two occasions, the second in the evening.
NutritionDay _complete(String date, double kcal, String today) => rollupDay(
      date,
      [_entry(date, kcal / 2, 8), _entry(date, kcal / 2, 20)],
      today: today,
    );

void main() {
  const today = '2026-08-15';

  test('today\'s running burn never enters the weekly balance', () {
    final w = NutritionWindow([
      _complete('2026-08-13', 2300, today),
      _complete('2026-08-14', 2300, today),
      // Today is in progress, with breakfast logged and 621 kcal burned by
      // 08:00. The old card subtracted exactly this figure.
      rollupDay(today, [_entry(today, 500, 8)], today: today),
    ]);
    final b = weeklyEnergyBalance(w, {
      '2026-08-13': 2350,
      '2026-08-14': 2250,
      today: 621,
    }, _worn(['2026-08-13', '2026-08-14', today]))!;
    expect(b.days, 2);
    expect(b.eaten, 2300);
    expect(b.burned, 2300);
    expect(b.balance, 0);
  });

  test('a counted day with no derived burn drops out of BOTH sides', () {
    final w = NutritionWindow([
      _complete('2026-08-12', 3000, today),
      _complete('2026-08-13', 2000, today),
    ]);
    final b = weeklyEnergyBalance(
        w, {'2026-08-13': 2200}, _worn(['2026-08-12', '2026-08-13']))!;
    expect(b.days, 1);
    expect(b.eaten, 2000);
    expect(b.burned, 2200);
    expect(b.balance, -200);
  });

  test('no day with both figures is an absence, not a zero balance', () {
    final w = NutritionWindow([
      _complete('2026-08-14', 2300, today),
      rollupDay(today, [_entry(today, 500, 8)], today: today),
    ]);
    expect(weeklyEnergyBalance(w, {today: 621}, _worn([today])), isNull);
    expect(weeklyEnergyBalance(w, const {}, const {}), isNull);
  });

  test('a day the band was off for hours drops out of both sides', () {
    final w = NutritionWindow([
      _complete('2026-08-13', 2300, today),
      _complete('2026-08-14', 2300, today),
    ]);
    // 14th: worn 12 h, so its burn holds half a basal day.
    final b = weeklyEnergyBalance(
      w,
      {'2026-08-13': 2300, '2026-08-14': 1400},
      {'2026-08-13': 1440, '2026-08-14': 720},
    )!;
    expect(b.days, 1);
    expect(b.balance, 0);
    // No wear figure at all is not a whole day either.
    expect(weeklyEnergyBalance(w, {'2026-08-14': 1400}, const {}), isNull);
  });
}

Map<String, double> _worn(List<String> days) => {for (final d in days) d: 1440};
