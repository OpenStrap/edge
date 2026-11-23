// "Skip for now" at onboarding opens the app with no band paired. Home's
// first-run card still offered "Sync the band": the sync returned at once,
// the tap grace held "Connecting to your band" up for 20 s over nothing, and
// nothing on Home pointed at pairing. With no band, the card offers pairing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/compute/inputs/canonical.dart'
    show kActiveWearableCursor, wearableEnabledCursor;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/sync/paired_device.dart' show PairedDevice;
import 'package:openstrap_edge/ui2/profile/devices.dart' show RePair;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget _host(AppState? app) {
  final probe = Builder(
    builder: (c) =>
        Scaffold(body: noBandCard(c, null) ?? const Text('no card')),
  );
  final home = MaterialApp(theme: buildTheme(Brightness.light), home: probe);
  return app == null
      ? home
      : ChangeNotifierProvider<AppState>.value(value: app, child: home);
}

void main() {
  testWidgets('no band paired: Home offers pairing, not a sync', (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);

    await t.pumpWidget(_host(app));

    expect(find.text('No band is paired'), findsOneWidget);
    expect(find.text('Pair a band'), findsOneWidget);
    expect(find.text('Sync your device'), findsNothing);

    await t.tap(find.text('Pair a band'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(RePair), findsOneWidget);
  });

  testWidgets('a paired band gets no pairing card', (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.paired = PairedDevice('AA:BB:CC:DD:EE:FF', 'SER1');

    await t.pumpWidget(_host(app));

    expect(find.text('No band is paired'), findsNothing);
    expect(find.text('no card'), findsOneWidget);
  });

  // A wearable-only install measures: its flag-on active wearable is a
  // source, so Home does not claim nothing is measured. Flag off, it is not
  // (rule R6), and the card stays.
  testWidgets('a flag-on wearable alone is a source; flag off it is not',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await t.runAsync(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await LocalDb.close();
      LocalDb.dbName = 'ui2_home_wearable_source_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      await LocalDb.upsertDevice(
          id: 'helio-1', adapterId: 'helio_strap', label: 'Helio');
      await LocalDb.setCursor(kActiveWearableCursor, 'helio-1');
      await app.refreshWearableSource();
    });
    expect(app.hasSource, isFalse, reason: 'flag off: not a source');
    app.initialized = true;
    expect(app.route, isIn([AppRoute.welcome, AppRoute.pairing]),
        reason: 'nothing measures yet: onboarding still asks for a device');
    await t.pumpWidget(_host(app));
    expect(find.text('No band is paired'), findsOneWidget);

    await t.runAsync(() async {
      await LocalDb.setCursor(wearableEnabledCursor('helio_strap'), '1');
      await app.refreshWearableSource();
    });
    expect(app.hasSource, isTrue);
    expect(app.isPaired, isFalse, reason: 'still no band');
    expect(app.route, AppRoute.profile,
        reason: 'past pairing on the wearable alone, on to profile setup');
    await t.pumpWidget(_host(app));
    await t.pump();
    expect(find.text('No band is paired'), findsNothing);
    await t.runAsync(LocalDb.close);
  });

  testWidgets('no AppState above (goldens) gets no pairing card', (t) async {
    await t.pumpWidget(_host(null));
    expect(find.text('no card'), findsOneWidget);
  });
}
