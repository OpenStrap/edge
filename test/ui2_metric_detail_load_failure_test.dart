// A read that throws on a metric's detail screen used to look exactly like a
// day that produced nothing: the first load fell through to "Nothing recorded
// today" / "Wear the band..." with no way to try again. Every sibling screen
// (Sleep, Day timeline, Wellness, Naps) already ends a failed read in its own
// retryable card; MetricDetail is the shared screen every metric opens into,
// and it was the one path left.
//
// The failure card must NOT reuse the empty state's copy: telling someone with
// data on disk to wear the band is the false-absence bug AGENTS §4.1 names.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Throws on the first [failures] chart reads, then serves an empty chart (a
/// real day with no value for this metric).
class _FlakyRepo extends LocalRepository {
  _FlakyRepo(this.failures);
  int failures;

  /// Reads actually issued. The retry test asserts this grew: a retry that only
  /// cleared the error state would otherwise pass on the same assertions.
  int reads = 0;

  void _maybeThrow() {
    reads++;
    if (failures > 0) {
      failures--;
      throw const FormatException('database is locked');
    }
  }

  @override
  Future<Map<String, dynamic>> getToday() async => {
        'status': {'today_day': '2026-05-22'},
      };

  @override
  Future<List<String>> availableDays() async => const [];

  @override
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    Set<String> signals = const {},
  }) async {
    _maybeThrow();
    return {};
  }

  @override
  Future<Map<String, dynamic>> getInsights() async => {};

  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) async =>
      {};
}

Future<void> _settle(WidgetTester t) async {
  // A time budget, not a poll count: one poll costs 40-100 ms of real time and
  // more under a full parallel run, while the first database open runs.
  for (final sw = Stopwatch()..start();
      sw.elapsed < const Duration(seconds: 10);) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 16));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
  }
}

Future<void> _pump(WidgetTester t, LocalRepository repo, Widget screen) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = repo;
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: ChangeNotifierProvider<AppState>.value(value: app, child: screen),
  ));
  await _settle(t);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a failed read is not "nothing recorded today", and can be retried',
      (t) async {
    final repo = _FlakyRepo(1);
    await _pump(t, repo, const MetricDetail('hrv'));

    expect(find.textContaining('could not be read'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Nothing recorded today'), findsNothing);
    expect(find.textContaining('Wear the band'), findsNothing);
    expect(repo.reads, 1);

    await t.tap(find.text('Try again'));
    await t.pump();
    await _settle(t);

    // The retry read succeeds and the real empty state is back.
    expect(repo.reads, 2, reason: 'Try again must re-run the read');
    expect(find.textContaining('could not be read'), findsNothing);
    expect(find.text('Nothing recorded today'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('a retry that fails again keeps the failure card', (t) async {
    final repo = _FlakyRepo(2);
    await _pump(t, repo, const MetricDetail('hrv'));
    expect(find.textContaining('could not be read'), findsOneWidget);

    await t.tap(find.text('Try again'));
    await t.pump();
    await _settle(t);

    expect(repo.reads, 2);
    expect(find.textContaining('could not be read'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Nothing recorded today'), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
