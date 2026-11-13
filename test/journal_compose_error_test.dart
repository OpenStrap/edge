// A database error during the journal's load or save used to escape
// unhandled: the form stayed on its spinner, or Save stayed on "Saving" with
// no message, and backing out lost the note.

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
  bool failLoad = false;
  bool failJournalWrite = false;
  Map<String, JournalMetricValue> metrics = {};
  List<String> tags = [];
  String note = '';
  int journalWrites = 0;

  @override
  Future<List<JournalFieldSpec>> getJournalFields() async {
    if (failLoad) throw Exception('database is locked');
    return const [];
  }

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
        {'date': '2026-09-01', 'tags': [...tags], 'note': note},
      ];
  @override
  Future<void> postJournal(String date, List<String> t, String n) async {
    if (failJournalWrite) throw Exception('database is locked');
    journalWrites++;
    tags = [...t];
    note = n;
  }
}

Future<void> _pump(WidgetTester t, _Repo repo) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final app = AppState.forTesting();
  app.repo = repo;
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: ChangeNotifierProvider<AppState>.value(
      value: app,
      child: const Scaffold(body: JournalCompose(date: '2026-09-01')),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a failed save says so, re-enables Save and keeps the note',
      (t) async {
    final repo = _Repo()..failJournalWrite = true;
    await _pump(t, repo);

    await t.enterText(find.byType(TextField).last, 'long day');
    await t.tap(find.text('Save').first);
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(find.text('Saving'), findsNothing);
    expect(find.text('Save'), findsWidgets);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(JournalCompose), findsOneWidget);
    expect(find.text('long day'), findsOneWidget);

    // The retry lands the note.
    repo.failJournalWrite = false;
    await t.tap(find.text('Save').first);
    await t.pumpAndSettle();
    expect(repo.journalWrites, 1);
    expect(repo.note, 'long day');
  });

  testWidgets('a failed load offers a retry instead of spinning', (t) async {
    final repo = _Repo()..failLoad = true;
    await _pump(t, repo);

    expect(t.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Try again'), findsOneWidget);

    repo.failLoad = false;
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Save'), findsWidgets);
  });
}
