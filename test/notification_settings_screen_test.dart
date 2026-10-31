// The notifications screen's "Turn them on" fix after a denial.
//
// Once the OS holds a denial, the permission request returns false without
// showing anything, so the button used to do nothing at all. And the screen
// read the grant once in initState, so a user who then found the switch in OS
// Settings by hand came back to a card still saying notifications were off.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _offTitle = 'Notifications are off at the system level';

Widget _app() => ChangeNotifierProvider<LocaleController>.value(
      value: LocaleController.seed(null),
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const NotificationSettings(),
      ),
    );

void main() {
  final svc = NotificationService.instance;
  var osEnabled = false;
  var opened = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    osEnabled = false;
    opened = 0;
    svc.invalidatePermissionCache();
    svc.debugProbePermission = () async => osEnabled;
    // A stored denial: the request comes back no without any dialog.
    svc.debugRequestPermission = () async => osEnabled;
    svc.debugOpenSettings = () async => opened++;
  });

  tearDown(() {
    svc.invalidatePermissionCache();
    svc.debugProbePermission = null;
    svc.debugRequestPermission = null;
    svc.debugOpenSettings = null;
  });

  testWidgets('a refused request opens the system settings page',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.text(_offTitle), findsOneWidget);

    await tester.tap(find.text('Turn them on'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('a grant does not open settings', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    osEnabled = true;
    await tester.tap(find.text('Turn them on'));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.text(_offTitle), findsNothing);
  });

  testWidgets('enabling in OS Settings clears the card on return',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.text(_offTitle), findsOneWidget);

    osEnabled = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(_offTitle), findsNothing);
  });
}
