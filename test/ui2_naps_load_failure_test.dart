// The Naps screen makes three reads (available days, the day's naps, the
// nap edits) and used to await them with no error handling. A read that
// threw — a busy or locked database is enough — left it on its spinner for
// good, with no message and no way to retry. It now ends in a retryable card.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// Throws on the first [failures] nap reads, then answers with a judged day
/// that had no naps.
class _FlakyRepo extends LocalRepository {
  _FlakyRepo(this.failures);
  int failures;

  @override
  Future<List<String>> availableDays() async => const ['2026-10-01'];

  @override
  Future<Map<String, dynamic>> getDayNaps(String date) async {
    if (failures > 0) {
      failures--;
      throw StateError('database is locked');
    }
    return const {'naps': [], 'nap_min': 0};
  }
}

/// `_load` reaches sqflite on a real event loop, so real time has to pass
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
      child: const NapsScreen(day: '2026-10-01'),
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
        reason: 'the Naps screen never left its spinner');
    expect(find.text('This could not be read'), findsOneWidget);

    await t.tap(find.text('Try again'));
    await t.pump();
    expect(await _settle(t), isTrue);
    expect(find.text('This could not be read'), findsNothing);
    expect(find.text('No naps on this day'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
