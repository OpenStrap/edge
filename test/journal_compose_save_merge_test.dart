// Saving the journal compose screen used to write back the snapshot it read
// when it opened. postJournalMetrics/postJournal REPLACE the day, so a glass of
// water or a moment tag logged from the strap while the screen was open was
// put back to the old value on Save.

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
  Map<String, JournalMetricValue> metrics = {
    'water_ml': const JournalMetricValue(500),
  };
  List<String> tags = ['gym'];

  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => const [];
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async =>
      {...metrics};
  @override
  Future<void> postJournalMetrics(
    String date,
    Map<String, JournalMetricValue> values,
  ) async =>
      metrics = {...values};
  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async =>
      [
        {'date': '2026-09-01', 'tags': [...tags], 'note': ''},
      ];
  @override
  Future<void> postJournal(String date, List<String> t, String note) async =>
      tags = [...t];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('save keeps a strap-logged glass and tag', (t) async {
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

    // The double-tap lands while the screen is open.
    repo.metrics['water_ml'] = const JournalMetricValue(750);
    repo.tags.add('moment 21:04');

    await t.tap(find.text('Save').first);
    await t.pumpAndSettle();

    expect(repo.metrics['water_ml']?.value, 750);
    expect(repo.tags, containsAll(['gym', 'moment 21:04']));
  });
}
