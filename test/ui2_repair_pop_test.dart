// RePair closes itself once a band pairs, and only itself (plus the pairing
// screen pushed on top of it). `isPaired` stays true through every notify the
// connect and handshake fire afterwards; a pop per rebuild used to walk on
// down past Devices to the shell.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart' show PairedDevice;
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  testWidgets('a re-pair lands back on Devices, not the shell', (tester) async {
    final app = AppState();
    addTearDown(app.dispose);
    final nav = GlobalKey<NavigatorState>();

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        navigatorKey: nav,
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: Text('shell')),
      ),
    ));
    Widget page(String s) => Scaffold(body: Text(s));
    nav.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => page('profile')));
    nav.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => page('devices')));
    nav.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => const RePair()));
    nav.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => page('pairing')));
    await tester.pumpAndSettle();
    expect(find.text('pairing'), findsOneWidget);

    app.paired = PairedDevice('AA:BB:CC:DD:EE:FF', 'SER1');
    // The pair, then the connect/handshake notifies that keep landing while
    // the routes animate out.
    for (var i = 0; i < 6; i++) {
      app.notifyListeners();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    expect(find.text('devices'), findsOneWidget);
    expect(find.text('pairing'), findsNothing);
    expect(find.byType(RePair), findsNothing);
  });
}
