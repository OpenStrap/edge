// "Skip for now" at onboarding opens the app with no band paired. Home's
// first-run card still offered "Sync the band": the sync returned at once,
// the tap grace held "Connecting to your band" up for 20 s over nothing, and
// nothing on Home pointed at pairing. With no band, the card offers pairing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/state/app_state.dart';
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
    expect(find.text('Sync the band'), findsNothing);

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

  testWidgets('no AppState above (goldens) gets no pairing card', (t) async {
    await t.pumpWidget(_host(null));
    expect(find.text('no card'), findsOneWidget);
  });
}
