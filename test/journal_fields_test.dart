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
}
