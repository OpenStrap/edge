// M6 -- LiveHrCard's device pill (spec-m6.md §11.5, §13.2 test 14).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart' show PairedDevice;
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  testWidgets(
      'a single streaming device renders the bare Pill, no Pressable above it',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.paired = PairedDevice('r1', 's1', generation: 'gen4');
    app.device.connection = 'connected';
    app.debugFeedEngineState(
      '',
      DeviceState()
        ..connection = 'connected'
        ..liveHr = 61
        ..liveHrAt = DateTime.now().millisecondsSinceEpoch,
    );

    await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: LiveHrCard()),
      ),
    ));
    await t.pumpAndSettle();

    expect(find.text('61'), findsOneWidget);
    expect(find.byType(Pill), findsOneWidget);
    // Below the multi-device gate the label is the const 'LIVE' Pill and
    // nothing wraps it with the device-switch semantics — the card's own
    // Surface has its own, unrelated Pressable elsewhere in the tree, so a
    // bare `findsNothing` on Pressable would be too broad; the switch
    // affordance's own semantic label is the specific, addressable marker.
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Tap to switch device')), findsNothing);
  });
}
