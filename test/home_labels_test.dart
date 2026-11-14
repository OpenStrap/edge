// RED (Home + labels, phase 0). WHY: three label fixes that ship with the Home
// upgrade, each pinned where it can be checked without a screen.
//
//  1. NEW COPY, ALL LOCALES. The sleep ring's wording ("92% of 8h 00m
//     (default)", compact forms) and the why panels add message keys. Every locale file (glob, so a newly added locale is
//     covered; today de en es fr hi ru th zh) must carry each one with the
//     SAME placeholders as English, a real ICU plural where English has one,
//     and a translation (not English pasted in). Checklist "Copy and UI":
//     meaning, not words, in every locale. Thai has no fork translation: it
//     must be written for this PR.
//  2. PLAINER HOME COPY. Eleven existing Home strings lose their jargon (a
//     "{z}x your normal night-to-night swing" multiple, "cross-day insights",
//     "Nothing recorded says why"). The illness texts lose their {z}
//     placeholder in EVERY locale, or the generated API and the locale files
//     disagree.
//  3. GRAPH LABEL DATA. The relative axis label of a stored point reads "1 day
//     ago" (not "1 days ago"; "1 night ago" for nights), counted against the
//     injectable clock so the label does not depend on when the test runs.
//
// Getter-based checks go through `dynamic` so a missing getter is a test
// FAILURE with a message rather than a compile error in the red phase.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';

/// The keys this PR adds (sleep ring wording + why panels).
const _newKeys = [
  'homeSleepPctOf',
  'homeSleepPctOfDefault',
  'homeSleepPctCompact',
  'homeSleepPctDefaultCompact',
  'homeSleepPctDefaultTight',
  'homeWhyRecoveryTitle',
  'homeWhyRecoveryPlain',
  'homeWhySleepTitle',
  'homeWhySleepBody',
  'homeWhySleepDetail',
  'homeWhyStrainTitle',
  'homeWhyStrainBody',
];

/// Existing keys whose English is made plainer.
const _plainerKeys = [
  'homeCoachSetUpChip',
  'homeDbRebuiltTitle',
  'homeGapNoReason',
  'homeIllnessBodyAbove',
  'homeIllnessBodyBelow',
  'homeIllnessBodyNoZ',
  'homeInsightsRebuildingAlgoVersion',
  'homeInsightsRebuildingTitle',
  'homeNothingTodayBody',
  'homeReadinessNoReason',
  'homeWorkoutHoldBody',
];

Map<String, dynamic> _arb(File f) =>
    jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;

Set<String> _placeholders(String s) {
  // Names inside {...}, ignoring the ICU plural/select heads and branch text.
  final out = <String>{};
  for (final m in RegExp(r'\{(\w+)(?=[},])').allMatches(s)) {
    final n = m.group(1)!;
    if (const {'one', 'other', 'few', 'many', 'two', 'zero'}.contains(n)) {
      continue;
    }
    out.add(n);
  }
  return out;
}

T _get<T>(String what, T Function() f) {
  try {
    return f();
  } on NoSuchMethodError {
    fail('$what is not generated yet (missing arb key)');
  }
}

void main() {
  final files = Directory('lib/l10n')
      .listSync()
      .whereType<File>()
      .where((f) => RegExp(r'app_[a-zA-Z_]+\.arb$').hasMatch(f.path))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final en = _arb(File('lib/l10n/app_en.arb'));

  group('1. new keys exist in every locale', () {
    test('WHY: the glob finds all eight locales', () {
      final names = files.map((f) => f.uri.pathSegments.last).toSet();
      expect(
          names,
          containsAll([
            'app_de.arb',
            'app_en.arb',
            'app_es.arb',
            'app_fr.arb',
            'app_hi.arb',
            'app_ru.arb',
            'app_th.arb',
            'app_zh.arb',
          ]));
    });

    test('WHY: English documents every new key with a description', () {
      for (final k in _newKeys) {
        expect(en[k], isA<String>(), reason: '$k missing in app_en.arb');
        expect((en['@$k'] as Map?)?['description'], isA<String>(),
            reason: '@$k needs a description for translators');
      }
    });

    for (final f in files) {
      final name = f.uri.pathSegments.last;
      test('WHY: $name carries every new key, same placeholders, translated',
          () {
        final j = _arb(f);
        final missing = <String>[];
        for (final k in _newKeys) {
          final v = j[k];
          if (v is! String || v.trim().isEmpty) {
            missing.add(k);
            continue;
          }
          final ref = en[k];
          if (ref is! String) continue; // reported by the English test
          expect(_placeholders(v), _placeholders(ref),
              reason: '$k placeholders in $name');
          if (name != 'app_en.arb') {
            expect(v, isNot(ref), reason: '$k is still English in $name');
          }
        }
        expect(missing, isEmpty, reason: 'missing or empty in $name');
      });
    }
  });

  group('1b. the English wording', () {
    final l = lookupAppLocalizations(const Locale('en'));
    test('WHY: percentages say when the target is the default', () {
      final d = _get('homeSleepPctOfDefault',
          () => (l as dynamic).homeSleepPctOfDefault(92, '8h 00m'));
      expect(d, '92% of 8h 00m (default)');
      final n =
          _get('homeSleepPctOf', () => (l as dynamic).homeSleepPctOf(96, '7h 42m'));
      expect(n, '96% of 7h 42m');
    });
  });

  group('2. plainer Home copy', () {
    final l = lookupAppLocalizations(const Locale('en'));

    test('WHY: the English strings are the plain ones', () {
      expect(l.homeCoachSetUpChip, 'Set up the coach');
      expect(l.homeDbRebuiltTitle, 'Your database was rebuilt');
      expect(l.homeGapNoReason, 'No reason recorded.');
      expect(l.homeReadinessNoReason, 'No reason recorded.');
      expect(l.homeInsightsRebuildingTitle, 'Updating your trends');
      expect(l.homeInsightsRebuildingAlgoVersion,
          'Updating after the latest app update.');
      expect(l.homeWorkoutHoldBody, 'Today fills in when you finish the workout.');
      expect(l.homeNothingTodayBody('Saturday'), 'Last scored night: Saturday.');
      expect(l.homeIllnessBodyNoZ,
          'Your resting heart rate has been above your usual over recent nights. A pattern, not a cause.');
    });

    test(
        'WHY: the illness texts no longer print a z multiple, so the getters '
        'take no argument', () {
      final above = _get('homeIllnessBodyAbove',
          () => (l as dynamic).homeIllnessBodyAbove as Object);
      final below = _get('homeIllnessBodyBelow',
          () => (l as dynamic).homeIllnessBodyBelow as Object);
      expect(above, isA<String>(),
          reason: 'still a method that wants {z}: the placeholder must go');
      expect(below, isA<String>());
      expect(above, 'Recent nights put your resting heart rate above your usual. '
          'That night was above it too. A pattern, not a cause.');
    });

    for (final f in files) {
      final name = f.uri.pathSegments.last;
      test('WHY: $name drops the {z} placeholder and the x-multiple', () {
        final j = _arb(f);
        for (final k in ['homeIllnessBodyAbove', 'homeIllnessBodyBelow']) {
          expect(j[k], isA<String>(), reason: '$k in $name');
          expect(_placeholders(j[k] as String), isEmpty,
              reason: '$k in $name still has a placeholder');
          expect(j[k], isNot(contains('×')), reason: '$k in $name');
          expect((j['@$k'] as Map?)?['placeholders'], isNull,
              reason: '@$k in $name still declares placeholders');
        }
      });
    }

    test('WHY: every locale keeps the same placeholders as English on all '
        'eleven plainer keys', () {
      for (final f in files) {
        final j = _arb(f);
        for (final k in _plainerKeys) {
          expect(j[k], isA<String>(),
              reason: '$k is missing in ${f.uri.pathSegments.last}');
          expect(_placeholders(j[k] as String), _placeholders(en[k] as String),
              reason: '$k in ${f.uri.pathSegments.last}');
        }
      }
    });
  });

  group('3. graph label data', () {
    // Local noon of a calendar day, the way metric_series stamps points.
    int noon(int day) =>
        DateTime(2026, 10, day, 12).millisecondsSinceEpoch ~/ 1000;
    final today = DateTime(2026, 10, 10, 15);

    test('WHY: one day back reads "1 day ago", not "1 days ago"', () {
      withClock(Clock.fixed(today), () {
        expect(axisDay(noon(9)), '1 day ago');
        expect(axisDay(noon(8)), '2 days ago');
        expect(axisDay(noon(10)), 'Today');
      });
    });

    test('WHY: the unit word agrees too ("1 night ago")', () {
      withClock(Clock.fixed(today), () {
        expect(axisDay(noon(9), unitWord: 'nights'), '1 night ago');
        expect(axisDay(noon(7), unitWord: 'nights'), '3 nights ago');
      });
    });

    test(
        'WHY: the label counts against the injected clock, so it does not '
        'change with the day the test runs', () {
      withClock(Clock.fixed(today), () {
        expect(daysBehind(noon(7)), 3);
        expect(daysBehind(noon(10)), 0);
        expect(axisDay(noon(10), todayWord: 'Last night'), 'Last night');
      });
      withClock(Clock.fixed(DateTime(2026, 10, 12, 0, 5)), () {
        // Five minutes after midnight, two days on: still a whole-day count.
        expect(daysBehind(noon(10)), 2);
        expect(axisDay(noon(10)), '2 days ago');
      });
    });

    test('WHY: no point, no label', () {
      withClock(Clock.fixed(today), () {
        expect(axisDay(null), '');
        expect(daysBehind(null), isNull);
      });
    });
  });
}
