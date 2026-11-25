// A wearable-only install has no band: the band's own rows (its alarm, the
// zone-alert buzz, double-tap, step calibration) would open screens that can
// only say "the band is not connected". With a band they show as before.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Future<void> _pump(WidgetTester t, {required bool hasBand}) async {
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: MoreSettingsView(
        units: 'Metric', appearance: 'Dark', phoneSteps: true, hasBand: hasBand),
  ));
  await t.pump();
}

void main() {
  testWidgets('no band: none of the band-only rows', (t) async {
    await _pump(t, hasBand: false);
    for (final row in ['Alarm', 'HR zone alert', 'Double-tap', 'Step calibration']) {
      expect(find.text(row, skipOffstage: false), findsNothing, reason: row);
    }
  });

  testWidgets('a band: the band rows are there', (t) async {
    await _pump(t, hasBand: true);
    for (final row in ['Alarm', 'HR zone alert', 'Double-tap', 'Step calibration']) {
      expect(find.text(row, skipOffstage: false), findsOneWidget, reason: row);
    }
  });
}
