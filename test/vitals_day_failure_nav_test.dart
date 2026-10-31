// Picking a Vitals day drops the old day's readings. A day whose read keeps
// failing must still leave the day stepper on screen, or there is no way off
// it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _days = ['2026-05-22', '2026-05-20', '2026-05-19'];

class _FailingDayRepo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() async => {
        'status': {'today_day': '2026-05-22'},
      };

  @override
  Future<List<String>> availableDays() async => _days;

  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async =>
      throw const FormatException('database is locked');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a picked day that keeps failing keeps the day stepper',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.repo = _FailingDayRepo();

    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(
          body: HealthScreen(
            data: HealthData(daysWithData: 3),
            vitals: VitalsData(day: '2026-05-22', days: _days),
            tab: 3,
          ),
        ),
      ),
    ));
    await t.pump();
    expect(find.byType(DayNav), findsOneWidget);

    t.widget<DayNav>(find.byType(DayNav)).onDay('2026-05-19');
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('Could not read'), findsOneWidget);
    expect(find.byType(DayNav), findsOneWidget);
    expect(t.widget<DayNav>(find.byType(DayNav)).day, '2026-05-19');
  });
}
