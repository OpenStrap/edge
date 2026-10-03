// The numeric journal vocabulary.
//
// The contract everything here defends: ABSENT AND ZERO ARE DIFFERENT. "No
// caffeine today" is a measurement; "I didn't fill this in" is not. A
// correlation that reads the second as the first invents a data point at the
// bottom of the dose range, which is where it does the most damage.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/journal_fields.dart';

void main() {
  group('the built-in table', () {
    test('every key is unique, lowercase, and stable-looking', () {
      final keys = kJournalFields.map((f) => f.key).toList();
      expect(keys.toSet().length, keys.length, reason: 'duplicate field key');
      for (final k in keys) {
        expect(k, k.toLowerCase());
        expect(k, isNot(startsWith('custom_')),
            reason: 'the custom_ prefix is reserved so a user field can never '
                'collide with a built-in one added later');
      }
    });

    test('the by-key index matches the table', () {
      expect(kJournalFieldsByKey.length, kJournalFields.length);
      for (final f in kJournalFields) {
        expect(kJournalFieldsByKey[f.key], same(f));
      }
    });

    test('every field can actually be filled in', () {
      // A step above the ceiling means the field can only ever hold 0.
      for (final f in kJournalFields) {
        expect(f.step, greaterThan(0), reason: '${f.key} cannot be stepped');
        expect(f.max, greaterThanOrEqualTo(f.step), reason: '${f.key} ceiling');
      }
    });

    test('ratings carry no unit and no time', () {
      for (final f in kJournalFields.where((f) => f.isRating)) {
        expect(f.unit, isEmpty);
        expect(f.hasTime, isFalse);
        expect(f.max, 5, reason: 'a ten-point self-report is not ten '
            'distinguishable states');
      }
    });

    test('caffeine asks when the last one was', () {
      // The field the timing support exists for: a 200 mg morning coffee and a
      // 200 mg evening one are the same dose and a completely different night.
      expect(kJournalFieldsByKey['caffeine_mg']!.hasTime, isTrue);
    });
  });

  group('journalFieldSpec', () {
    const custom = JournalFieldSpec(
      key: 'custom_magnesium',
      label: 'Magnesium',
      kind: JournalFieldKind.dose,
      unit: 'mg',
      max: 1000,
      step: 50,
      custom: true,
    );

    test('finds built-ins and customs', () {
      expect(journalFieldSpec('mood')?.label, 'Mood');
      expect(
        journalFieldSpec('custom_magnesium', custom: const [custom])?.label,
        'Magnesium',
      );
    });

    test('a built-in wins over a custom of the same key', () {
      // Only reachable if a future release adopts a name someone had already
      // invented — the shipped definition has to be the one that applies, or
      // the same key means two different things across two installs.
      const shadow = JournalFieldSpec(
        key: 'mood',
        label: 'Mood but in tens',
        kind: JournalFieldKind.rating,
        unit: '',
        max: 10,
        step: 1,
        custom: true,
      );
      expect(journalFieldSpec('mood', custom: const [shadow])?.max, 5);
    });

    test('returns null for a field with no definition left', () {
      // A custom field whose definition was deleted while its readings
      // remained. Callers must render those raw rather than invent a unit.
      expect(journalFieldSpec('custom_gone'), isNull);
    });
  });

  group('customJournalFieldKey', () {
    test('prefixes and slugs', () {
      expect(customJournalFieldKey('Magnesium'), 'custom_magnesium');
      expect(customJournalFieldKey('Screen time'), 'custom_screen_time');
      expect(customJournalFieldKey('  Vitamin  D3 '), 'custom_vitamin_d3');
    });

    test('the prefix is what stops a collision with a future built-in', () {
      // If `magnesium` ever ships as a built-in, it must not silently adopt
      // somebody's existing column and reinterpret its units.
      expect(
        customJournalFieldKey('Magnesium'),
        isNot(anyOf(kJournalFields.map((f) => f.key))),
      );
    });

    test('a name with nothing sluggable collapses, which callers must reject',
        () {
      // Every such name produces the same bare key, so the sheet refuses it
      // rather than letting two fields share storage.
      expect(customJournalFieldKey('???'), 'custom_');
      expect(customJournalFieldKey(''), 'custom_');
    });

    test('non-Latin names get their own keys', () {
      // zh and hi ship; an ASCII-only slug made every such name `custom_`.
      expect(customJournalFieldKey('冥想'), 'custom_冥想');
      expect(customJournalFieldKey('冥想'), isNot(customJournalFieldKey('散步')));
      expect(customJournalFieldKey('विटामिन डी'), 'custom_विटामिन_डी');
    });
  });

  group('JournalMetricValue', () {
    test('zero is a value, and is not equal to absence', () {
      const zero = JournalMetricValue(0);
      expect(zero.value, 0);
      expect(zero, isNot(equals(null)));
    });

    test('equality includes the time', () {
      expect(
        const JournalMetricValue(200, atMinuteOfDay: 480),
        const JournalMetricValue(200, atMinuteOfDay: 480),
      );
      expect(
        const JournalMetricValue(200, atMinuteOfDay: 480),
        isNot(const JournalMetricValue(200, atMinuteOfDay: 1200)),
      );
    });
  });

  group('formatting', () {
    test('a rating prints as a whole number', () {
      expect(kJournalFieldsByKey['mood']!.format(4), '4');
    });

    test('a dose drops a trailing zero but keeps a real fraction', () {
      final water = kJournalFieldsByKey['water_ml']!;
      expect(water.formatWithUnit(1500), '1500 ml');
      expect(water.format(2.5), '2.5');
    });

    test('minute of day reads as a clock time', () {
      expect(formatMinuteOfDay(0), '12:00 AM');
      expect(formatMinuteOfDay(7 * 60 + 5), '7:05 AM');
      expect(formatMinuteOfDay(12 * 60), '12:00 PM');
      expect(formatMinuteOfDay(20 * 60 + 30), '8:30 PM');
    });

    test('minute of day wraps rather than printing an impossible hour', () {
      expect(formatMinuteOfDay(24 * 60), '12:00 AM');
    });
  });

  // MT-03 — weight is stored as entered and DRAWN as a trend. Day-to-day scale
  // noise is water and glycogen at plus or minus 1-2 kg; a raw line makes that
  // read as change, on the most eating-disorder-adjacent surface in the app.
  group('weight trend', () {
    test('the field exists and is entered, not measured', () {
      final w = kJournalFieldsByKey['weight_kg']!;
      expect(w.unit, 'kg');
      expect(w.step, 0.1); // a scale reads tenths; whole kg would round it away
    });

    test('smooths scale noise instead of reporting it as movement', () {
      // Five days oscillating +/- 1 kg around 80 with no real change.
      final ewma = weightTrendEwma({
        '2026-01-01': 80.0,
        '2026-01-02': 81.0,
        '2026-01-03': 79.0,
        '2026-01-04': 81.0,
        '2026-01-05': 79.0,
      });
      // The raw series swings 2 kg on the last two days; the trend must not.
      expect((ewma['2026-01-05']! - ewma['2026-01-04']!).abs(), lessThan(0.3));
      expect(ewma['2026-01-05'], closeTo(80.0, 0.6));
    });

    test('a gap is a gap — no day without a reading gets a point', () {
      final ewma = weightTrendEwma({
        '2026-01-01': 80.0,
        '2026-02-01': 76.0,
      });
      expect(ewma.keys, ['2026-01-01', '2026-02-01']);
      // A month of decay means the later reading is essentially its own
      // starting point rather than being dragged toward a stale one.
      expect(ewma['2026-02-01'], closeTo(76.0, 0.2));
    });

    test('two readings a day apart barely move the trend', () {
      final ewma = weightTrendEwma({'2026-01-01': 80.0, '2026-01-02': 84.0});
      // ~9.4% of a 4 kg jump at a 7-day half-life.
      expect(ewma['2026-01-02'], closeTo(80.4, 0.1));
    });
  });
}
