// The beta "use this device" switch on a paired device's page, off a real
// database: the title per category, the confirm sheet before a wearable
// scores (cancel, confirm, the active wearable switched off), the off path,
// and that the developer toggles flip the same flag the switch shows.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _garmin = 'garmin-1', _oura = 'oura-1', _strap = 'strap-1';
const _scale = 'scale-1', _thermo = 'thermo-1', _coros = 'coros-1';
const _whoop = 'whoop-2';

/// Lets the database work a build or a tap starts finish: real time for the
/// I/O, a fake-time pump for what it hands back (and the sheet's motion),
/// until a toggle's re-derive is done.
Future<void> _settle(WidgetTester t, [Widget? w]) async {
  if (w != null) await t.pumpWidget(w);
  for (var i = 0; i < 200 && (i < 10 || WearableDisplay.instance.busy); i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _page(WidgetTester t, String id, String adapter) => _settle(
    t,
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
          body: SingleChildScrollView(
              child: DeviceUseSwitch(deviceId: id, adapterId: adapter))),
    ));

bool _on(WidgetTester t) => t.widget<Switch>(find.byType(Switch)).value;

Future<void> _flip(WidgetTester t) async {
  await t.tap(find.byType(Switch));
  await _settle(t);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Prefs.setBool(Prefs.devMode, false);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'device_use_switch_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    for (final (id, adapter, label) in [
      (_garmin, 'garmin', 'Garmin watch'),
      (_oura, 'oura', 'Oura ring'),
      (_strap, 'ble_hrs', 'Chest strap'),
      (_scale, 'miscale2', 'Mi Smart Scale 2'),
      (_thermo, 'thermometer', 'Thermometer'),
      (_coros, 'coros', 'Coros watch'),
      (_whoop, 'gen4', 'WHOOP 4.0'),
    ]) {
      await LocalDb.upsertDevice(id: id, adapterId: adapter, label: label);
    }
    // Real-zone first read, so a page's own read is a quick one.
    await WearableDisplay.instance.loadDevices();
  });

  tearDownAll(() async => LocalDb.close());

  testWidgets('a wearable: switch, beta chip, note and what it unlocks',
      (t) async {
    await _page(t, _garmin, 'garmin');
    expect(find.text('Use this device for scores'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(
        find.text("Experimental. Scores from this device haven't been "
            'checked on real hardware yet.'),
        findsOneWidget);
    expect(find.text('What this wearable unlocks'), findsOneWidget,
        reason: 'shown outside developer mode under the switch');
    expect(_on(t), isFalse);
  });

  testWidgets('cancel leaves it off; confirm makes it the scoring wearable '
      'and says the active one is switched off', (t) async {
    await t.runAsync(() => useDevice(_oura, 'oura', true));
    await _page(t, _garmin, 'garmin');

    await _flip(t);
    expect(find.text('Use Garmin watch for scores?'), findsOneWidget);
    expect(find.textContaining('Oura ring will be switched off'),
        findsOneWidget);
    await t.tap(find.text('Not now'));
    await _settle(t);
    expect(find.text('Use Garmin watch for scores?'), findsNothing);
    expect(_on(t), isFalse);
    expect(await t.runAsync(activeWearableId), _oura);
    expect(await t.runAsync(() => wearableEnabled('garmin')), isFalse);

    await _flip(t);
    await t.tap(find.text('Use it'));
    await _settle(t);
    expect(_on(t), isTrue);
    expect(await t.runAsync(activeWearableId), _garmin);
    expect(await t.runAsync(() => wearableEnabled('garmin')), isTrue);
    expect(await t.runAsync(activeWearable), (_garmin, 'garmin'),
        reason: 'one wearable scores at a time');
  });

  testWidgets('the old wearable reads off; off needs no confirm', (t) async {
    await _page(t, _oura, 'oura');
    expect(_on(t), isFalse, reason: 'Garmin took over in the last test');

    await _page(t, _garmin, 'garmin');
    expect(_on(t), isTrue);
    await _flip(t);
    expect(find.text('Use it'), findsNothing);
    expect(_on(t), isFalse);
    expect(await t.runAsync(() => wearableEnabled('garmin')), isFalse);
    expect(await t.runAsync(activeWearable), isNull,
        reason: 'flag off: the device contributes nothing (R6)');
  });

  testWidgets('a workout sensor and a scale flip their flag directly',
      (t) async {
    await _page(t, _strap, 'ble_hrs');
    expect(find.text('Use during workouts'), findsOneWidget);
    expect(find.text('What this wearable unlocks'), findsNothing);
    await _flip(t);
    expect(find.text('Use it'), findsNothing);
    expect(_on(t), isTrue);
    expect(await t.runAsync(() => wearableEnabled('ble_hrs')), isTrue);
    await _flip(t);
    expect(await t.runAsync(() => wearableEnabled('ble_hrs')), isFalse);

    await _page(t, _scale, 'miscale2');
    expect(find.text('Use readings (weight) in your numbers'), findsOneWidget);
    await _flip(t);
    expect(await t.runAsync(() => wearableEnabled('miscale2')), isTrue);
    await _flip(t);
    expect(await t.runAsync(() => wearableEnabled('miscale2')), isFalse);
  });

  testWidgets('no switch for a thermometer, a Coros watch or a WHOOP band',
      (t) async {
    for (final (id, adapter) in [
      (_thermo, 'thermometer'),
      (_coros, 'coros'),
      (_whoop, 'gen4'),
    ]) {
      await _page(t, id, adapter);
      expect(find.byType(Switch), findsNothing, reason: adapter);
      expect(find.text('Beta'), findsNothing, reason: adapter);
    }
  });

  testWidgets('a developer toggle moves the switch, and busy shows progress',
      (t) async {
    await _page(t, _garmin, 'garmin');
    expect(_on(t), isFalse);
    await t.runAsync(() => WearableDisplay.instance
        .toggleDevice(_garmin, 'garmin', false, false));
    await _settle(t);
    expect(_on(t), isTrue);
    await t.runAsync(() => WearableDisplay.instance
        .toggleDevice(_garmin, 'garmin', true, true));
    await _settle(t);
    expect(_on(t), isFalse);

    WearableDisplay.instance.busy = true;
    addTearDown(() => WearableDisplay.instance.busy = false);
    await t.runAsync(WearableDisplay.instance.loadDevices);
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Updating your days…'), findsOneWidget);
  });
}
