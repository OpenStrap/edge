// The Android background-survival rows in Settings.
//
// The battery-optimization exemption and the OEM autostart allowlist were
// wired all the way to native and reachable from nowhere: the ui rewrite
// deleted the only screen that asked, so Doze or an OEM task killer could stop
// the tracking service overnight and nothing in the app offered the fix.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SetRow;
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: child,
    );

void _tallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

const _keepAlive = 'Keep syncing in the background';
const _autostart = 'Allow auto-start';

SetRow _row(WidgetTester tester, String title) =>
    tester.widget<SetRow>(find.widgetWithText(SetRow, title));

void main() {
  testWidgets('no row where the OS has no exemption to ask for',
      (tester) async {
    _tallPhone(tester);
    await tester.pumpWidget(_wrap(const MoreSettingsView(version: '1')));
    expect(find.text(_keepAlive), findsNothing);
    expect(find.text(_autostart), findsNothing);
  });

  testWidgets('an unexempt app offers the exemption, and the tap asks for it',
      (tester) async {
    _tallPhone(tester);
    var asked = 0;
    await tester.pumpWidget(_wrap(MoreSettingsView(
      version: '1',
      backgroundExempt: false,
      onRequestBackgroundExempt: () => asked++,
    )));
    expect(_row(tester, _keepAlive).value, 'Allow');
    await tester.tap(find.text(_keepAlive));
    expect(asked, 1);
  });

  testWidgets('an exempt app says so and the row is no longer a button',
      (tester) async {
    _tallPhone(tester);
    var asked = 0;
    await tester.pumpWidget(_wrap(MoreSettingsView(
      version: '1',
      backgroundExempt: true,
      onRequestBackgroundExempt: () => asked++,
    )));
    final row = _row(tester, _keepAlive);
    expect(row.value, 'On');
    expect(row.onTap, isNull);
  });

  testWidgets('the autostart row appears only when the phone maker needs it',
      (tester) async {
    _tallPhone(tester);
    var opened = 0;
    await tester.pumpWidget(_wrap(MoreSettingsView(
      version: '1',
      backgroundExempt: true,
      showOemAutostart: true,
      onOpenOemAutostart: () => opened++,
    )));
    await tester.tap(find.text(_autostart));
    expect(opened, 1);

    await tester.pumpWidget(_wrap(const MoreSettingsView(
      version: '1',
      backgroundExempt: true,
    )));
    expect(find.text(_autostart), findsNothing);
  });
}
