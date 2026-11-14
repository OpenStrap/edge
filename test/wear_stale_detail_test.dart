// #450: wear time froze for the rest of the day.
//
// Wear is computed in the derive's second half. When that half fails, the
// engine keeps the headline and carries the previous row's wear forward, so
// the figure stops moving while everything around it says "today". The row
// now records the edge the carried detail was computed at
// (`wear_edge_sec`), and the wear read hands it to the screen, which says
// "not updated since" instead of passing a frozen morning off as current.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/activity/day_strain.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// Just the Vitals reads, with a fixed wear payload.
class _Repo extends LocalRepository {
  _Repo(this.wear);
  final Map<String, dynamic> wear;
  static const day = '2026-07-14';

  @override
  Future<Map<String, dynamic>> getToday() async => const {
    'status': {'today_day': day},
  };
  @override
  Future<List<String>> availableDays() async => const [day];
  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) async => {
    'date': date,
  };
  @override
  Future<Map<String, dynamic>> getDayLungs(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getDayWear(String date) async => wear;
  @override
  Future<Map<String, dynamic>> getDayHrv(String date) async => const {};
}

Future<void> _vitals(WidgetTester t, Map<String, dynamic> wear) async {
  t.view.physicalSize = const Size(800 * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  final app = AppState.forTesting()..repo = _Repo(wear);
  addTearDown(app.dispose);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const Scaffold(body: HealthScreen()),
      ),
    ),
  );
  for (var i = 0; i < 20; i++) {
    await t.pump();
  }
  await t.tap(find.text('Vitals'));
  for (var i = 0; i < 20; i++) {
    await t.pump();
  }
}

void main() {
  const day = '2026-07-14';
  final edge = DateTime(2026, 7, 14, 11, 5).millisecondsSinceEpoch ~/ 1000;
  late LocalRepositoryImpl repo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = 'wear_stale_detail_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    repo = LocalRepositoryImpl(getProfileMap: () => {});
  });
  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  Future<void> store({int? wearEdge}) => LocalDb.putDayResult(
    dayId: day,
    algoVersion: kAlgoVersion,
    payloadJson: jsonEncode({
      'scalars': {'rhr': 53},
      'wear': {'worn_min': 300, 'coverage_pct': 45, 'segments': []},
      'data_edge_sec': edge + 4 * 3600,
      'wear_edge_sec': ?wearEdge,
    }),
    windowJson: '{}',
    partial: wearEdge != null,
  );

  test('carried wear says how old it is', () async {
    await store(wearEdge: edge);
    final w = await repo.getDayWear(day);
    expect(w['worn_min'], 300);
    expect(w['as_of'], edge);
  });

  test('wear from a complete derive carries no age', () async {
    await store();
    final w = await repo.getDayWear(day);
    expect(w['worn_min'], 300);
    expect(w.containsKey('as_of'), isFalse);
  });

  group('the Wear time row', () {
    testWidgets('says when a carried figure was last updated', (t) async {
      await _vitals(t, {'worn_min': 300, 'coverage_pct': 45, 'as_of': edge});
      expect(find.text('Wear time'), findsOneWidget);
      expect(
        find.textContaining('not updated since ${clockOfTs(edge)}'),
        findsOneWidget,
      );
      expect(
        find.textContaining('45%'),
        findsOneWidget,
        reason: 'the coverage stays beside the age',
      );
    });

    testWidgets('names the day when the edge fell on another one', (t) async {
      final nextDay =
          DateTime(2026, 7, 15, 2, 30).millisecondsSinceEpoch ~/ 1000;
      await _vitals(t, {'worn_min': 300, 'coverage_pct': 45, 'as_of': nextDay});
      final line = find.textContaining('not updated since');
      expect(line, findsOneWidget);
      expect(
        (t.widget<Text>(line)).data,
        contains('${prettyDay('2026-07-15')} ${clockOfTs(nextDay)}'),
        reason: 'a bare 2:30 under the 14th would read as that day',
      );
    });

    testWidgets('a complete figure says nothing about age', (t) async {
      await _vitals(t, {'worn_min': 300, 'coverage_pct': 45});
      expect(find.text('Wear time'), findsOneWidget);
      expect(find.textContaining('not updated since'), findsNothing);
    });
  });

  group('Day Strain', () {
    Future<void> show(WidgetTester t, DayStrainData d, double scale) async {
      t.view.physicalSize = const Size(390 * 3, 2200 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final curve = List<double?>.filled(1440, null);
      for (var m = 7 * 60; m < 11 * 60; m++) {
        curve[m] = (m - 7 * 60) / 60;
      }
      await t.pumpWidget(
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: DayStrainDetail(
              data: DayStrainData(
                day: DateTime(2026, 7, 14),
                curve: curve,
                strain: 9.2,
                wornMin: d.wornMin,
                coveragePct: d.coveragePct,
                wearAsOf: d.wearAsOf,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
    }

    testWidgets('a carried wear figure says where it stops', (t) async {
      await show(
        t,
        DayStrainData(wornMin: 300, coveragePct: 90, wearAsOf: edge),
        1,
      );
      expect(find.text('Worn as of ${clockOfTs(edge)}'), findsOneWidget);
      expect(find.text('Worn'), findsNothing);
      // The pump is the overflow assertion at the largest iOS text size.
      await show(
        t,
        DayStrainData(wornMin: 300, coveragePct: 90, wearAsOf: edge),
        3.1,
      );
      expect(t.takeException(), isNull);
    });

    testWidgets('names the day when the edge fell on another one', (t) async {
      // The screen shows 14 July; the carried wear was computed on the 15th.
      final nextDay =
          DateTime(2026, 7, 15, 2, 30).millisecondsSinceEpoch ~/ 1000;
      await show(
        t,
        DayStrainData(wornMin: 300, coveragePct: 90, wearAsOf: nextDay),
        1,
      );
      expect(
        find.text('Worn as of ${prettyDay('2026-07-15')} ${clockOfTs(nextDay)}'),
        findsOneWidget,
      );
    });

    testWidgets('a current one is plain "Worn"', (t) async {
      await show(t, const DayStrainData(wornMin: 300, coveragePct: 90), 1);
      expect(find.text('Worn'), findsOneWidget);
      expect(find.textContaining('Worn as of'), findsNothing);
    });
  });
}
