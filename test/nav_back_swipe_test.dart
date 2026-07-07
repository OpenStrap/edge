// Regression tests for back navigation (the "swipe-back / back button dead"
// bug): themedRoute must stay a MaterialPageRoute so the iOS interactive
// edge-swipe-back gesture works, and AppScaffold's back button must pop a
// themedRoute-pushed screen. A raw PageRouteBuilder (the regression) has no
// back-gesture machinery, so the iOS swipe test below would fail against it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/theme_controller.dart';
import 'package:openstrap_edge/theme/theme_switcher.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/design/app_scaffold.dart';

Widget _app(GlobalKey<NavigatorState> nav) {
  AppColors.active = kLightPalette;
  return ChangeNotifierProvider<ThemeController>.value(
    value: ThemeController.seed(AppThemeChoice.light, Brightness.light),
    child: MaterialApp(
      navigatorKey: nav,
      theme: buildOpenStrapTheme(kLightPalette),
      home: const AppScaffold(title: 'Root', children: []),
    ),
  );
}

void main() {
  tearDown(() => AppColors.active = kLightPalette);

  test('themedRoute is a swipe-back-capable route (MaterialPageRoute)', () {
    // MaterialPageRoute resolves through the theme's pageTransitionsTheme,
    // which on iOS provides the Cupertino transition + edge-swipe-back.
    // PageRouteBuilder (the regression) would fail this.
    final route = themedRoute((_) => const SizedBox());
    expect(route, isA<MaterialPageRoute<dynamic>>());
    expect(route.fullscreenDialog, isFalse);
  });

  testWidgets(
    'iOS edge swipe-back pops a themedRoute-pushed screen',
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(nav));
      await t.pump();

      nav.currentState!.push(
        themedRoute((_) => const AppScaffold(title: 'Detail', children: [])),
      );
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Detail'), findsOneWidget);

      // The route must expose the interactive back gesture at all.
      final route =
          ModalRoute.of(t.element(find.text('Detail')))! as PageRoute;
      expect(route.popGestureEnabled, isTrue,
          reason: 'pushed route must support the iOS back-swipe gesture');

      // Drag from the left edge across more than half the (800 px) surface —
      // the Cupertino back gesture must claim it and complete the pop.
      final gesture = await t.startGesture(const Offset(5, 300));
      await gesture.moveBy(const Offset(50, 0));
      await t.pump();
      await gesture.moveBy(const Offset(450, 0));
      await t.pump();
      await gesture.up();
      await t.pumpAndSettle(const Duration(milliseconds: 100));

      expect(find.text('Detail'), findsNothing);
      expect(find.text('Root'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('back button pops a themedRoute-pushed screen', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(_app(nav));
    await t.pump();
    expect(find.byType(AppBackButton), findsNothing); // root can't pop

    nav.currentState!.push(
      themedRoute((_) => const AppScaffold(title: 'Detail', children: [])),
    );
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Detail'), findsOneWidget);
    expect(find.byType(AppBackButton), findsOneWidget);

    await t.tap(find.byType(AppBackButton));
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Detail'), findsNothing);
    expect(find.text('Root'), findsOneWidget);
  });
}
