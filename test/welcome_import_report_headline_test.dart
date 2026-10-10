import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';

Future<void> _pump(WidgetTester tester, ImportOutcome o) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ImportReport(o))),
    );

void main() {
  // A vendor export with only a workouts.csv selected lands 0 days, 0
  // journal rows and 0 lab rows — the headline used to fall all the way
  // through to "0 journal days written" (and, once labs existed, "0 lab
  // results written") for exactly this outcome.
  testWidgets('workouts-only outcome headlines the workout count, not a zero',
      (tester) async {
    await _pump(tester, const ImportOutcome(source: 'Vendor CSV export', workouts: 3));
    expect(find.textContaining('lab result'), findsNothing);
    expect(find.textContaining('journal'), findsNothing);
    expect(find.textContaining('3 workout'), findsOneWidget);
  });

  testWidgets('skipped-only outcome headlines the skip count, not a zero',
      (tester) async {
    await _pump(tester, const ImportOutcome(source: 'Vendor CSV export', skippedDays: 5));
    expect(find.textContaining('lab result'), findsNothing);
    expect(find.textContaining('already measured'), findsOneWidget);
  });

  testWidgets('lab-only outcome still headlines the lab count', (tester) async {
    await _pump(tester, const ImportOutcome(source: 'Lab results CSV', labRows: 2));
    expect(find.textContaining('2 lab results written'), findsOneWidget);
  });

  testWidgets('days beats every other counter for the headline', (tester) async {
    await _pump(
      tester,
      const ImportOutcome(
          source: 'OpenStrap backup', days: 10, workouts: 3, journalRows: 1, labRows: 1),
    );
    expect(find.textContaining('10 days imported'), findsOneWidget);
    // The others still show, just not as the headline — journal gets its own
    // "replaced" line rather than a second "written" one.
    expect(find.textContaining('3 workout'), findsOneWidget);
    expect(find.textContaining('1 lab result'), findsOneWidget);
    expect(find.textContaining('1 journal day replaced'), findsOneWidget);
  });

  testWidgets('archive buckets a backup could not merge are reported, not '
      'dropped silently', (tester) async {
    await _pump(
      tester,
      const ImportOutcome(
          source: 'OpenStrap backup', days: 4, archiveBucketsSkipped: 2),
    );
    expect(find.textContaining('Part of that file could not be used'),
        findsOneWidget);
    expect(find.textContaining('2 days of saved sensor history'),
        findsOneWidget);
    expect(find.text('Update the app'), findsOneWidget);
  });

  testWidgets('a re-import that lands nothing still reports the archive '
      'buckets it could not merge', (tester) async {
    // Every backed-up day already finalized here: 0 days imported.
    await _pump(
      tester,
      const ImportOutcome(source: 'OpenStrap backup', archiveBucketsSkipped: 1),
    );
    expect(find.textContaining('Nothing was imported'), findsOneWidget);
    expect(find.textContaining('1 day of saved sensor history'),
        findsOneWidget);
    expect(find.text('Update the app'), findsOneWidget);
    // Nothing else landed, so nothing may claim it did.
    expect(find.textContaining('Everything else'), findsNothing);
  });

  test('the skipped-archive line never claims the rest imported, and every '
      'language has the archive strings', () {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final n in [1, 2]) {
      expect(en.welcomeArchiveSkipped(n), isNot(contains('Everything else')));
    }
    for (final code in ['de', 'es', 'fr', 'hi', 'zh']) {
      final l = lookupAppLocalizations(Locale(code));
      expect(l.actionUpdateApp, isNot(en.actionUpdateApp), reason: code);
      expect(l.welcomeArchiveSkipped(2), isNot(en.welcomeArchiveSkipped(2)),
          reason: code);
      expect(l.welcomeArchiveSkipped(2), contains('2'), reason: code);
      expect(l.welcomeArchiveRestored(3), isNot(en.welcomeArchiveRestored(3)),
          reason: code);
      expect(l.welcomeArchiveRestored(3), contains('3'), reason: code);
    }
  });

  testWidgets('a restore that only adds raw history is not "nothing imported"',
      (tester) async {
    await _pump(
      tester,
      const ImportOutcome(source: 'OpenStrap backup', archiveBucketsRestored: 3),
    );
    expect(find.textContaining('Nothing was imported'), findsNothing);
    expect(find.textContaining('restored or extended for 3 days'),
        findsOneWidget);
  });
}
