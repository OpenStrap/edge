// #625: the switch on Detected activities. Off by default; turning it on
// stores when it was turned on, turning it off clears that.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('off by default, a tap turns it on, another turns it off',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    await t.pumpWidget(
      const MaterialApp(home: Scaffold(body: NapAutoLogRow())),
    );
    expect(find.text('Off'), findsOneWidget);
    expect(Prefs.getInt(Prefs.napAutoLogSinceSec, 0), 0);

    final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await t.tap(find.text('Log clear naps automatically'));
    await t.pump();
    expect(find.text('On'), findsOneWidget);
    expect(
      Prefs.getInt(Prefs.napAutoLogSinceSec, 0),
      greaterThanOrEqualTo(before),
    );

    await t.tap(find.text('Log clear naps automatically'));
    await t.pump();
    expect(find.text('Off'), findsOneWidget);
    expect(Prefs.getInt(Prefs.napAutoLogSinceSec, 0), 0);
  });
}
