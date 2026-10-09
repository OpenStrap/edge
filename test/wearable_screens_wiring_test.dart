// The active wearable's card where people see it: Home and Health, on the
// real screens, off a real database. Pins the placement (the card is there,
// and not when a screen is handed its data), that Home's card follows the
// day switcher, that a day the WHOOP band covers never wears the wearable's
// name, and that a developer toggle redraws the card without a derive.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _band = 'miband-wiring';
final String _today = todayLabel();
final String _yesterday =
    dayLabelOf(DateTime.now().subtract(const Duration(days: 1)));

/// Home's own numbers off a stub; the wearable card reads the database.
class _Repo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() async => {
        'daily': {
          'readiness': {'value': 70, 'confidence': .8, 'tier': 'HIGH'},
        },
        'status': {'today_day': _today},
      };
  @override
  Future<Map<String, dynamic>> getInsights() async => const {};
  @override
  Future<Map<String, dynamic>> getProfile() async => const {'name': 'Alex'};
  @override
  Future<List<String>> availableDays() async => [_today, _yesterday];
  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async =>
      {'readiness': 42};
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async => const {};
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async =>
      const {'has_sleep': false};
}

Future<void> _day(String date, String family, double rhr) =>
    LocalDb.putDayResult(
      dayId: date,
      algoVersion: 109,
      payloadJson: jsonEncode({
        'device_family': family,
        'scalars': {'rhr': rhr, 'strain': 12.3},
      }),
      windowJson: '{}',
      deviceFamily: family,
    );

/// The resting-HR cell the card is drawing, or null for no card.
Object? _rhr(WidgetTester t) {
  final cells = t.widgetList<WearableCell>(find.byType(WearableCell));
  for (final w in cells) {
    if (w.row == 'resting_hr') return w.cell['value'];
  }
  return null;
}

/// Builds in the real zone, so the database reads a build starts finish.
Future<void> _settle(WidgetTester t, [Widget? w]) async {
  await t.runAsync(() async {
    if (w != null) await t.pumpWidget(w);
    for (var i = 0; i < 3; i++) {
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  });
  await t.pump();
}

Future<void> _pumpHome(WidgetTester t, {bool handed = false}) async {
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = _Repo();
  await _settle(t, MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<ThemeController>.value(
          value:
              ThemeController.seed(AppThemeChoice.light, Brightness.light)),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
          body: handed
              ? const HomeScreen(hour: 9, data: HomeData())
              : const HomeScreen(hour: 9)),
    ),
  ));
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'wearable_screens_wiring_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(
        id: _band,
        adapterId: 'miband234',
        remoteId: 'AA:BB:CC:00:00:09',
        label: 'miband234');
    await LocalDb.setCursor(kActiveWearableCursor, _band);
    await LocalDb.setCursor(wearableEnabledCursor('miband234'), '1');
    await _day(_today, 'miband234', 58);
    await _day(_yesterday, 'miband234', 61);
  });

  tearDownAll(() async => LocalDb.close());

  testWidgets("Home draws the wearable's card and follows the day switcher",
      (t) async {
    await _pumpHome(t);
    expect(find.byType(WearableCells), findsOneWidget);
    expect(t.widget<WearableCells>(find.byType(WearableCells)).date, isNull);
    expect(_rhr(t), 58);

    await t.tap(find.bySemanticsLabel('Previous day'));
    await _settle(t);
    expect(t.widget<WearableCells>(find.byType(WearableCells)).date,
        _yesterday);
    expect(_rhr(t), 61, reason: "re-read for the switched day");
  });

  testWidgets('Home handed its data draws no wearable card', (t) async {
    await _pumpHome(t, handed: true);
    expect(find.byType(WearableCells), findsNothing);
  });

  testWidgets("Health draws the wearable's heart rows", (t) async {
    await _settle(
        t,
        MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: HealthScreen())));
    expect(find.byType(WearableCells), findsOneWidget);
    expect(
        [for (final w in t.widgetList<WearableCell>(find.byType(WearableCell)))
          w.row],
        kHealthWearableRows);
    expect(_rhr(t), 58);
  });

  testWidgets('Health handed its data draws no wearable card', (t) async {
    await _settle(
        t,
        MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: HealthScreen(data: HealthData()))));
    expect(find.byType(WearableCells), findsNothing);
  });

  testWidgets("a band-covered day never wears the wearable's name",
      (t) async {
    await t.runAsync(() => _day(_today, 'gen5', 47));
    addTearDown(() => t.runAsync(() => _day(_today, 'miband234', 58)));
    expect(await t.runAsync(() => dayCells(_today)), isNull);
    await _pumpHome(t);
    expect(find.byType(WearableCell), findsNothing);
    expect(find.textContaining('From your Mi Band'), findsNothing);
  });

  test("a band day the derive has not reached never wears the wearable's "
      'name either', () async {
    final date =
        dayLabelOf(DateTime.now().subtract(const Duration(days: 3)));
    expect(await LocalDb.dayResult(date), isNull);
    expect(await dayCells(date), isNotNull, reason: "the wearable's day");
    final t = localDayStartSec(date)! + 12 * 3600;
    final db = await LocalDb.instance;
    await db.insert('decoded_onehz', {
      'device_id': LocalDb.kPrimaryDeviceId,
      'ts_ms': t * 1000,
      'rec_ts': t,
      'counter': 1,
      'hr': 60,
      'device_family': 'gen5',
    });
    try {
      expect(await dayCells(date), isNull);
    } finally {
      await db.delete('decoded_onehz', where: 'rec_ts = ?', whereArgs: [t]);
    }
  });

  testWidgets('a developer toggle redraws the card without a derive',
      (t) async {
    await _settle(
        t,
        MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(
            body: SingleChildScrollView(
                child: WearableCells(kHomeWearableRows)))));
    expect(find.byType(WearableCell), findsWidgets);

    // Off: no day of the band's is its own, so nothing re-derives and no
    // revision ticks; the toggle's notification alone must clear the card.
    await t.runAsync(() async {
      await WearableDisplay.instance.loadDevices();
      await WearableDisplay.instance.toggleDevice(
          _band, 'miband234', true, true);
    });
    await _settle(t);
    expect(find.byType(WearableCell), findsNothing);

    await t.runAsync(() => WearableDisplay.instance
        .toggleDevice(_band, 'miband234', false, true));
    await _settle(t);
    expect(find.byType(WearableCell), findsWidgets);
  });
}
