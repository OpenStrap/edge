import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/cloud/kcalculator_sync.dart';

void main() {
  group('normalizeUrl', () {
    test('trims the trailing slash and keeps https', () {
      expect(normalizeUrl(' https://abc.supabase.co/ '), 'https://abc.supabase.co');
    });
    test('rejects what is not an http(s) URL', () {
      expect(normalizeUrl('abc.supabase.co'), isNull);
      expect(normalizeUrl('ftp://x'), isNull);
    });
  });

  group('entryFromNutritionRow', () {
    test('one entry per day, unknown micros stay null', () {
      final e = entryFromNutritionRow({
        'date': '2026-11-18',
        'items': 4,
        'kcal': 2150.4,
        'protein_g': 160,
        'carbs_g': '210.5',
        'fat_g': 70,
        'fibre_g': 28,
        'sodium_mg': null,
        'micros_complete': false,
      })!;
      expect(e.id, 'kcalc-2026-11-18');
      expect(e.date, '2026-11-18');
      expect(e.kcal, 2150.4);
      expect(e.carbsG, 210.5);
      expect(e.fibreG, 28);
      expect(e.sodiumMg, isNull);
      expect(e.ironMg, isNull);
      expect(e.confirmed, isTrue);
      expect(e.note, contains('partiels'));
    });
    test('a day emptied in Kcalculator gives no entry (it gets deleted)', () {
      expect(entryFromNutritionRow({'date': '2026-11-17', 'items': 0, 'kcal': 0}), isNull);
    });
  });

  group('buildHealthRows', () {
    final now = DateTime.utc(2026, 11, 18, 12);
    test('one row per measured day, missing values null, steps rounded', () {
      final rows = buildHealthRows(
        days: ['2026-11-16', '2026-11-17', '2026-11-18'],
        series: {
          'calories_total': {'2026-11-17': 2712.46, '2026-11-18': 1500},
          'calories': {'2026-11-17': 640},
          'steps': {'2026-11-17': 9201.6},
          'rmssd': {'2026-11-18': 58.04},
        },
        weighing: (date: '2026-11-18', kg: 82.3),
        userId: 'u1',
        now: now,
      );
      expect(rows.map((r) => r['date']), ['2026-11-17', '2026-11-18']);
      final d17 = rows.first;
      expect(d17['user_id'], 'u1');
      expect(d17['total_kcal'], 2712.5);
      expect(d17['active_kcal'], 640.0);
      expect(d17['steps'], 9202);
      expect(d17['sleep_min'], isNull);
      expect(d17['weight_kg'], isNull);
      expect(rows.last['weight_kg'], 82.3);
      expect(rows.last['hrv_ms'], 58.0);
      // Every row has the same columns: a bulk upsert requires it.
      expect(rows.first.keys.toSet(), rows.last.keys.toSet());
    });
    test('nothing measured, nothing sent', () {
      expect(buildHealthRows(days: ['2026-11-18'], series: {}, weighing: null, now: now), isEmpty);
    });
  });
}
