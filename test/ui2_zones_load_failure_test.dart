// A read that throws on the Zones screen used to look exactly like a person
// with no zones: `_d` stayed null, build used the empty placeholder, and the
// empty card's own copy decided the AGE was missing. So a failed read told
// someone who had already set their age to go and set it — the same false
// advice this file's `_zones` comment says was fixed once for the no-age case.
//
// A failed read now ends in its own retryable card, the same one Sleep, the
// day timeline, Wellness and Naps use.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/activity/zones.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Throws on the first [failures] zone reads, then serves an empty payload
/// (a real read that found nothing).
class _FlakyRepo extends LocalRepository {
  _FlakyRepo(this.failures);
  int failures;

  @override
  Future<Map<String, dynamic>> getZones() async {
    if (failures > 0) {
      failures--;
      throw const FormatException('database is locked');
    }
    return {};
  }
}

Future<void> _settle(WidgetTester t) async {
  for (final sw = Stopwatch()..start();
      sw.elapsed < const Duration(seconds: 10);) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 16));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
  }
}

Future<void> _pump(WidgetTester t, LocalRepository repo) async {
  t.view.physicalSize = const Size(390 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = repo;
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: ChangeNotifierProvider<AppState>.value(
        value: app, child: const ZonesDetail()),
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

  testWidgets('a failed read is not "No zones yet", and never invents a missing age',
      (t) async {
    final repo = _FlakyRepo(1);
    await _pump(t, repo);

    expect(find.textContaining('could not be read'), findsOneWidget);
    // Zones is not a day: the body must not claim a stored DAY failed.
    expect(find.textContaining('Reading your stored data failed'), findsOneWidget);
    expect(find.textContaining('stored day'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('No zones yet'), findsNothing);
    expect(find.text('Add your age in Profile'), findsNothing);
    expect(t.takeException(), isNull);

    await t.tap(find.text('Try again'));
    await t.pump();
    await _settle(t);

    // The retry succeeds: the real empty state (and only then its age advice)
    // is what renders.
    expect(find.textContaining('could not be read'), findsNothing);
    expect(find.text('No zones yet'), findsOneWidget);
    expect(find.text('Add your age in Profile'), findsOneWidget);
    expect(t.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
