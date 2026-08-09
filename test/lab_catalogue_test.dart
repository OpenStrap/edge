// The lab marker catalogue.
//
// Reference ranges are the part that can do harm here. A range that is wrong,
// or applied to the wrong person, turns a tracker into a source of false
// alarms — so these tests are mostly about the ranges being coherent, applied
// to the right sex, and absent rather than guessed when there isn't one.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/lab_catalogue.dart';

void main() {
  group('the catalogue', () {
    test('keys are unique, lowercase, and outside the custom namespace', () {
      final keys = kLabMarkers.map((m) => m.key).toList();
      expect(keys.toSet().length, keys.length, reason: 'duplicate marker key');
      for (final k in keys) {
        expect(k, k.toLowerCase());
        expect(k, isNot(startsWith('custom_')));
      }
    });

    test('the by-key index matches the list', () {
      expect(kLabMarkersByKey.length, kLabMarkers.length);
      for (final m in kLabMarkers) {
        expect(kLabMarkersByKey[m.key], same(m));
      }
    });

    test('every marker has a unit and a sane precision', () {
      for (final m in kLabMarkers) {
        expect(m.unit, isNotEmpty, reason: '${m.key} has no unit');
        expect(m.decimals, inInclusiveRange(0, 3));
      }
    });

    test('every range is ordered and non-degenerate', () {
      for (final m in kLabMarkers) {
        for (final r in m.ranges) {
          expect(r.low, lessThan(r.high),
              reason: '${m.key} has a range that excludes everything');
        }
      }
    });

    test('a marker never defines two ranges for the same sex', () {
      // Two competing intervals for one person is a silent coin flip over
      // which one the value is judged against.
      for (final m in kLabMarkers) {
        final scopes = m.ranges.map((r) => r.scope).toList();
        expect(scopes.toSet().length, scopes.length, reason: m.key);
      }
    });

    test('a sex-scoped marker covers both sexes, not just one', () {
      // Half a definition is worse than none: everyone of the uncovered sex
      // silently gets no verdict while everyone else gets one.
      for (final m in kLabMarkers) {
        final scoped = m.ranges.where((r) => r.scope != LabRefScope.any);
        if (scoped.isEmpty) continue;
        if (m.ranges.any((r) => r.scope == LabRefScope.any)) continue;
        expect(
          scoped.map((r) => r.scope).toSet(),
          {LabRefScope.male, LabRefScope.female},
          reason: '${m.key} defines a range for one sex only',
        );
      }
    });

    test('grouping covers every marker exactly once', () {
      final grouped = labMarkersByCategory().values
          .expand((e) => e)
          .map((m) => m.key)
          .toList();
      expect(grouped.toSet(), kLabMarkers.map((m) => m.key).toSet());
      expect(grouped.length, kLabMarkers.length);
    });
  });

  group('range selection', () {
    final ferritin = kLabMarkersByKey['ferritin']!;
    final hba1c = kLabMarkersByKey['hba1c']!;

    test('picks the interval for the reader’s sex', () {
      expect(ferritin.rangeFor('m')!.low, 30);
      expect(ferritin.rangeFor('f')!.low, 15);
      expect(ferritin.rangeFor('female')!.high, 200);
    });

    test('a sex-specific marker gives no verdict without a sex', () {
      // Guessing one would mark a large share of normal results as out of
      // range, which is the exact false alarm this feature must not create.
      expect(ferritin.rangeFor(null), isNull);
      expect(ferritin.inRange(20, sex: null), isNull);
    });

    test('an unscoped marker applies to everyone', () {
      expect(hba1c.rangeFor(null), isNotNull);
      expect(hba1c.inRange(5.2), isTrue);
      expect(hba1c.inRange(6.4), isFalse);
    });

    test('boundaries are inclusive', () {
      expect(hba1c.inRange(4.0), isTrue);
      expect(hba1c.inRange(5.6), isTrue);
      expect(hba1c.inRange(3.9), isFalse);
      expect(hba1c.inRange(5.7), isFalse);
    });

    test('no range at all means no opinion, not "fine"', () {
      const bare = LabMarker(
        key: 'bare',
        label: 'Bare',
        unit: 'x',
        category: LabCategory.blood,
      );
      expect(bare.inRange(999), isNull);
      expect(bare.rangeFor('m'), isNull);
    });

    test('a sex-specific range wins over a general one', () {
      const both = LabMarker(
        key: 'both',
        label: 'Both',
        unit: 'x',
        category: LabCategory.blood,
        ranges: [
          LabRefRange(low: 0, high: 100),
          LabRefRange(low: 50, high: 60, scope: LabRefScope.female),
        ],
      );
      expect(both.rangeFor('f')!.low, 50);
      expect(both.rangeFor('m')!.low, 0, reason: 'falls back to the general');
      expect(both.rangeFor(null)!.low, 0);
    });
  });

  group('lookup and custom keys', () {
    const custom = LabMarker(
      key: 'custom_lp_a',
      label: 'Lp(a)',
      unit: 'nmol/L',
      category: LabCategory.lipids,
      custom: true,
    );

    test('finds built-ins and customs', () {
      expect(labMarker('ferritin')?.label, 'Ferritin');
      expect(labMarker('custom_lp_a', custom: const [custom])?.label, 'Lp(a)');
      expect(labMarker('nope'), isNull);
    });

    test('a built-in wins over a same-keyed custom', () {
      const shadow = LabMarker(
        key: 'ferritin',
        label: 'Mine',
        unit: 'nmol/L',
        category: LabCategory.iron,
        custom: true,
      );
      expect(labMarker('ferritin', custom: const [shadow])?.unit, 'ng/mL');
    });

    test('custom keys are prefixed so a future built-in cannot adopt them', () {
      expect(customLabMarkerKey('Lp(a)'), 'custom_lp_a');
      expect(customLabMarkerKey('  Free  T3 '), 'custom_free_t3');
      expect(
        customLabMarkerKey('Ferritin'),
        isNot(anyOf(kLabMarkers.map((m) => m.key))),
      );
    });
  });

  test('formatting respects each marker’s precision', () {
    expect(kLabMarkersByKey['ferritin']!.formatWithUnit(42.4), '42 ng/mL');
    expect(kLabMarkersByKey['tsh']!.formatWithUnit(1.234), '1.23 mIU/L');
    // Dart rounds half away from zero, so 5.25 goes up.
    expect(kLabMarkersByKey['hba1c']!.formatWithUnit(5.25), '5.3 %');
    expect(kLabMarkersByKey['hba1c']!.formatWithUnit(5.24), '5.2 %');
  });
}
