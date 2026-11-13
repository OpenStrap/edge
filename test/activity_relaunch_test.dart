// #650: on Android the Flutter engine outlives the Activity, so a screen left
// open (Settings, a detail page) was still on top when the app was opened
// again from the launcher. `MainActivity` sends `relaunched` on
// `openstrap/activity` for exactly that case; the Dart side closes the pushed
// screens and leaves the tab underneath alone, as an iOS cold start would.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/platform/activity_relaunch.dart';

void main() {
  final navKey = GlobalKey<NavigatorState>();
  NavigatorState? nav() => navKey.currentState;

  Future<void> fromNative(WidgetTester tester, String method) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      ActivityRelaunch.channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  Future<void> openTwoScreens(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Text('tab'),
    ));
    for (final name in ['settings', 'detail']) {
      navKey.currentState!
          .push(MaterialPageRoute<void>(builder: (_) => Text(name)));
      await tester.pumpAndSettle();
    }
    expect(find.text('detail'), findsOneWidget);
  }

  tearDown(() => ActivityRelaunch.stop(nav));

  testWidgets('relaunched closes every pushed screen, back to the tab',
      (tester) async {
    await openTwoScreens(tester);
    ActivityRelaunch.listen(nav);

    await fromNative(tester, 'relaunched');

    expect(find.text('tab'), findsOneWidget);
    expect(find.text('settings'), findsNothing);
    expect(find.text('detail'), findsNothing);
  });

  testWidgets('a screen that refuses to close stays; the one above it goes',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Text('tab'),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const PopScope(canPop: false, child: Text('capture')),
    ));
    await tester.pumpAndSettle();
    navKey.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => const Text('help')));
    await tester.pumpAndSettle();
    ActivityRelaunch.listen(nav);

    await fromNative(tester, 'relaunched');

    expect(find.text('help'), findsNothing);
    expect(find.text('capture'), findsOneWidget);
  });

  testWidgets('any other call leaves the screens alone', (tester) async {
    await openTwoScreens(tester);
    ActivityRelaunch.listen(nav);

    await fromNative(tester, 'something_else');

    expect(find.text('detail'), findsOneWidget);
  });

  testWidgets('a disposed owner (null navigator) is a no-op, not a crash',
      (tester) async {
    await openTwoScreens(tester);
    NavigatorState? gone() => null;
    ActivityRelaunch.listen(gone);

    await fromNative(tester, 'relaunched');

    expect(find.text('detail'), findsOneWidget);
    ActivityRelaunch.stop(gone);
  });

  testWidgets("a replaced owner's stop does not silence its successor",
      (tester) async {
    await openTwoScreens(tester);
    NavigatorState? old() => null;
    ActivityRelaunch.listen(old);
    ActivityRelaunch.listen(nav); // successor's initState
    ActivityRelaunch.stop(old); // predecessor's later dispose

    await fromNative(tester, 'relaunched');

    expect(find.text('tab'), findsOneWidget);
  });
}
