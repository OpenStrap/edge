// A read that throws on the Sleep tab used to look exactly like a day with no
// night: the first load fell through to "No night to show … wear the band
// overnight", and a failed day step left the previous night on screen under
// the new date, with its correction buttons still acting on that night. A
// failed read now ends in its own retryable card, and the same holds for the
// day timeline.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// Three days on disk, none with a night. Throws on insight and timeline
/// reads while [failures] is above zero.
class _FlakyRepo extends LocalRepository {
  _FlakyRepo(this.failures);
  int failures;

  void _maybeThrow() {
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
  Future<List<String>> availableDays() async =>
      ['2026-05-22', '2026-05-20', '2026-05-19'];

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async => {};

  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async {
    _maybeThrow();
    return {};
  }

  @override
  Future<Map<String, dynamic>> getInsights() async {
    _maybeThrow();
    return {};
  }

  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      {};

  @override
  Future<List<Map<String, dynamic>>> sleepWindows(
          {int days = 60, String? before}) async =>
      [];
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
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

  group('the Sleep screen', () {
    testWidgets('a failed first read is not "no night", and can be retried',
        (t) async {
      final repo = _FlakyRepo(1);
      await _pump(t, repo, const SleepDetail());

      expect(find.textContaining('could not be read'), findsOneWidget);
      expect(find.text('No night to show'), findsNothing);

      await t.tap(find.text('Try again'));
      await t.pump();
      await _settle(t);
      expect(find.textContaining('could not be read'), findsNothing);
      expect(find.text('No night to show'), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('a failed day step does not leave the old night on screen',
        (t) async {
      final repo = _FlakyRepo(0);
      await _pump(t, repo, const SleepDetail());
      expect(find.text('No night to show'), findsOneWidget);

      repo.failures = 1;
      t.widget<DayNav>(find.byType(DayNav)).onDay('2026-05-19');
      await t.pump();
      await _settle(t);

      expect(find.textContaining('could not be read'), findsOneWidget);
      expect(find.text('No night to show'), findsNothing);
      // The stepper stays so the day can be walked off.
      expect(find.byType(DayNav), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets(
        'a failed step back to the latest night names that night, '
        'with no plan under the error, and retries without the old night',
        (t) async {
      final repo = _FlakyRepo(0);
      await _pump(
          t,
          repo,
          const SleepDetail(
              day: '2026-05-19', todayFooter: [Text('TONIGHT PLAN')]));
      expect(t.widget<DayNav>(find.byType(DayNav)).day, '2026-05-19');
      expect(find.text('TONIGHT PLAN'), findsNothing);

      repo.failures = 1;
      t.widget<DayNav>(find.byType(DayNav)).onDay('2026-05-22');
      await t.pump();
      await _settle(t);

      expect(find.textContaining('could not be read'), findsOneWidget);
      expect(t.widget<DayNav>(find.byType(DayNav)).day, '2026-05-22');
      expect(find.text('TONIGHT PLAN'), findsNothing);

      // Hold the retry's read so the frame during it can be inspected.
      repo.failures = 0;
      await t.tap(find.text('Try again'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await _settle(t);
      expect(find.text('No night to show'), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('a retry that fails again keeps the day stepper', (t) async {
      final repo = _FlakyRepo(0);
      await _pump(t, repo, const SleepDetail(day: '2026-05-19'));

      repo.failures = 1;
      t.widget<DayNav>(find.byType(DayNav)).onDay('2026-05-20');
      await t.pump();
      await _settle(t);
      expect(find.textContaining('could not be read'), findsOneWidget);

      repo.failures = 1;
      await t.tap(find.text('Try again'));
      await t.pump();
      await _settle(t);
      expect(find.textContaining('could not be read'), findsOneWidget);
      expect(find.byType(DayNav), findsOneWidget);
      expect(t.widget<DayNav>(find.byType(DayNav)).day, '2026-05-20');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('the day timeline', () {
    // Only the failure is driven here: a successful timeline read also goes
    // to the journal, meal and medication tables, which this stub has none of.
    testWidgets('a failed read shows a retryable card, not an empty day',
        (t) async {
      final repo = _FlakyRepo(1);
      await _pump(t, repo, const DayTimelineScreen());

      expect(find.textContaining('could not be read'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
