// The sleep plan at the bottom of the Sleep tab is `WellnessScreen` in
// `sleepPlanOnly` mode, and its `_load` makes about ten reads (medication,
// breathing, insights, charts, journal). Any one of them throwing used to leave
// `_loading` set for good, so the section showed a spinner forever with no
// error and no way to retry. A read that throws now ends in a retryable card.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// Throws on the first [failures] insight reads, then answers with nothing.
class _FlakyRepo extends LocalRepository {
  _FlakyRepo(this.failures);
  int failures;

  @override
  Future<Map<String, dynamic>> getToday() async => const {};

  @override
  Future<Map<String, dynamic>> getDayStress(String date) async => const {};

  @override
  Future<Map<String, dynamic>> getInsights() async {
    if (failures > 0) {
      failures--;
      throw const FormatException('corrupt insights row');
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async => const {};

  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      const {'points': []};

  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(
          String date) async =>
      {};

  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => const [];
}

/// `_load` goes to sqflite on a real event loop, so real time has to pass
/// between pumps. Polls until the spinner is gone; false if it never goes.
Future<bool> _settle(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 16));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return true;
  }
  return false;
}

Future<void> _pump(WidgetTester t, LocalRepository repo) async {
  t.view.physicalSize = const Size(390 * 3, 844 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = repo;
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: ChangeNotifierProvider<AppState>.value(
      value: app,
      child: const Scaffold(
        body: SingleChildScrollView(
          child: WellnessScreen(sleepPlanOnly: true),
        ),
      ),
    ),
  ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a read that throws shows a retryable card, not a spinner',
      (t) async {
    final repo = _FlakyRepo(1);
    await _pump(t, repo);

    expect(await _settle(t), isTrue,
        reason: 'the sleep plan never left its spinner');
    expect(find.text('This could not be read'), findsOneWidget);

    await t.tap(find.text('Try again'));
    await t.pump();
    expect(await _settle(t), isTrue);
    expect(find.text('This could not be read'), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
