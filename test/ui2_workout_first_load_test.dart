// The Activity tab's first open, before its one long load has answered.
//
// The bug this pins: the builder drew the EMPTY dataset while the load was
// still running, so a user with sessions and a weight on file was told "No
// sessions recorded yet" on History and asked to add a weight on Activities,
// and a start tile tapped in that window opened setup with a null weight.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/screens/start_card.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// A repo whose first read never answers — the slow, sync-contended launch.
class _StalledRepo extends LocalRepository {
  final profile = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> getProfile() => profile.future;
}

/// A repo whose session-history read fails.
class _BrokenHistoryRepo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getProfile() async => {};
  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async =>
      throw const FormatException('database is locked');
}

Widget _app(AppState app) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<LocaleController>.value(
            value: LocaleController.seed(null),
          ),
        ],
        child: const Scaffold(body: WorkoutScreen()),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a load in flight is not drawn as an empty history',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _StalledRepo();

    await t.pumpWidget(_app(app));
    await t.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // No start tiles to tap with a weight that has not been read yet.
    expect(find.byType(StartCard), findsNothing);

    await t.tap(find.text('Activities'));
    await t.pump();
    expect(find.text('Calorie estimates need your weight'), findsNothing);

    await t.tap(find.text('History'));
    await t.pump();
    expect(find.text('No sessions recorded yet'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a failed history read is a retry card, not an empty history',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _BrokenHistoryRepo();

    await t.pumpWidget(_app(app));
    await t.pumpAndSettle();
    await t.tap(find.text('History'));
    await t.pumpAndSettle();
    expect(find.text('No sessions recorded yet'), findsNothing);
    expect(find.text('Activity could not be read'), findsOneWidget);
  });
}
