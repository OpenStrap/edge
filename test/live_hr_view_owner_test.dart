// The two screens that show the live BPM own the realtime-HR stream while
// mounted and release it on dispose (discussion #287): the resting-HR detail
// screen's live card host and the band's device page.
//
// No database is opened here on purpose: both screens tolerate a missing one
// (the live resting-HR screen has no repo to load from under a test AppState;
// the device page's battery reads are best-effort), and a real sqflite open
// under the widget test's fake clock leaves the close hanging in teardown.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  Widget host(AppState app, Widget child) => MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ChangeNotifierProvider<AppState>.value(
          value: app,
          child: Scaffold(body: child),
        ),
      );

  Future<void> pumpOut(WidgetTester t, AppState app) async {
    await t.pumpWidget(host(app, const SizedBox()));
    await t.pump();
  }

  testWidgets('the live resting-HR screen owns HR while mounted', (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await t.pumpWidget(host(app, const MetricDetail('resting_hr')));
    await t.pump();
    expect(app.debugLiveOwners.visibleLiveHrView, isTrue);
    await pumpOut(t, app);
    expect(app.debugLiveOwners.visibleLiveHrView, isFalse);
  });

  testWidgets('another metric\'s screen owns nothing', (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await t.pumpWidget(host(app, const MetricDetail('hrv')));
    await t.pump();
    expect(app.debugLiveOwners.visibleLiveHrView, isFalse);
    await pumpOut(t, app);
  });

  testWidgets('the band device page owns HR while mounted; a sensor page does not',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 2400 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    const band = HealthSource(
      name: 'WHOOP',
      kind: 'band',
      tier: null,
      icon: Icons.watch,
      isBand: true,
    );
    await t.pumpWidget(host(app, const DeviceDetail(band)));
    await t.pump();
    expect(app.debugLiveOwners.visibleLiveHrView, isTrue);
    await pumpOut(t, app);
    expect(app.debugLiveOwners.visibleLiveHrView, isFalse);

    const sensor = HealthSource(
      name: 'Chest strap',
      kind: 'sensor',
      tier: null,
      icon: Icons.favorite,
    );
    await t.pumpWidget(host(app, const DeviceDetail(sensor)));
    await t.pump();
    expect(app.debugLiveOwners.visibleLiveHrView, isFalse);
    await pumpOut(t, app);
  });
}
