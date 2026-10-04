// One failed save of a custom journal field used to leave the add button
// latched off for the rest of the session: the failure branch returned
// without clearing the in-flight flag, so "check storage and retry" could not
// be retried until the screen was rebuilt.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/journal_compose.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// postCustomJournalField is left to the base class, which throws.
class _Repo extends LocalRepository {
  int saves = 0;

  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => const [];
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async =>
      const {};
  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async =>
      const [];
  @override
  Future<void> postCustomJournalField(JournalFieldSpec spec) async {
    saves++;
    throw StateError('journal field already exists');
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a failed custom-field save can be retried', (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    final app = AppState.forTesting();
    final repo = _Repo();
    app.repo = repo;
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: JournalCompose(date: '2026-09-01')),
      ),
    ));
    await t.pumpAndSettle();

    for (var attempt = 1; attempt <= 2; attempt++) {
      final add = find.text('Track something else');
      await t.ensureVisible(add.first);
      await t.tap(add.first);
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).last, 'Magnesium');
      await t.tap(find.text('Start tracking it'));
      await t.pumpAndSettle();
      expect(repo.saves, attempt, reason: 'attempt $attempt reached the repo');
      ScaffoldMessenger.of(t.element(find.byType(JournalCompose)))
          .removeCurrentSnackBar();
      await t.pumpAndSettle();
    }
  });
}
