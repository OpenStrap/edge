// Adding a custom journal field used to reload the whole form from storage,
// so a note typed (or tags ticked) before the tap was silently discarded.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/journal_compose.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Repo extends LocalRepository {
  final fields = <JournalFieldSpec>[];

  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => [...fields];
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async =>
      const {};
  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async =>
      const [];
  @override
  Future<void> postCustomJournalField(JournalFieldSpec spec) async =>
      fields.add(spec);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('adding a field keeps the unsaved note', (t) async {
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

    final note = find.byType(TextField).last;
    await t.ensureVisible(note);
    await t.enterText(note, 'slept badly');
    await t.pumpAndSettle();

    final add = find.text('Track something else');
    await t.ensureVisible(add.first);
    await t.tap(add.first);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, 'Magnesium');
    await t.tap(find.text('Start tracking it'));
    await t.pumpAndSettle();

    expect(repo.fields, hasLength(1));
    expect(find.text('slept badly'), findsOneWidget);
  });
}
