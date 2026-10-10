// The four-tab layout: what moved where, and the pieces that came with it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_analytics/onehz.dart'
    show quietHrrMinDays, readinessCompositeMinBaseline;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/onboarding/profile_setup.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart'
    show firstWeekCard;
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

Widget _app(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: child),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Sleep tab is the Sleep screen with a tab header',
      (t) async {
    await t.pumpWidget(_app(const SleepDetail(
      embedded: true,
      data: SleepData(),
      footer: [Text('plan below the night')],
    )));
    await t.pump();
    expect(find.byType(ProfileAvatar), findsOneWidget);
    expect(find.text('plan below the night'), findsOneWidget);
    // A tab has no way back; the pushed screen keeps its arrow.
    expect(find.byIcon(LucideIcons.chevronLeft), findsNothing);

    await t.pumpWidget(_app(const SleepDetail(data: SleepData())));
    await t.pump();
    expect(find.byIcon(LucideIcons.chevronLeft), findsOneWidget);
    expect(find.byType(ProfileAvatar), findsNothing);
  });

  testWidgets('the first-weeks card names the gates the pipeline uses',
      (t) async {
    await t.pumpWidget(_app(Builder(
        builder: (c) => firstWeekCard(c, days: 2, strainScored: false))));
    // Strain needs this many earlier days with a resting level; recovery
    // this many earlier nights. The card is one past each.
    expect(find.text('Strain: from day ${quietHrrMinDays + 1}'),
        findsOneWidget);
    expect(
        find.text('Recovery: from night ${readinessCompositeMinBaseline + 1}, '
            'once it knows your normal'),
        findsOneWidget);
    expect(find.text('2 days recorded so far'), findsOneWidget);
  });

  testWidgets('onboarding offers cycle tracking, on for a female profile',
      (t) async {
    t.view.physicalSize = const Size(390 * 3, 1600 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    bool? saved;
    await t.pumpWidget(_app(ProfileSetupView(
      onSave: (_) async {},
      onCycleTracking: (on) async => saved = on,
    )));
    final toggle = find.byType(SwitchListTile);
    expect(toggle, findsOneWidget);
    expect(t.widget<SwitchListTile>(toggle).value, isFalse);

    await t.tap(find.text('Female'));
    await t.pump();
    expect(t.widget<SwitchListTile>(toggle).value, isTrue);

    await t.tap(find.text('Continue'));
    await t.pump();
    expect(saved, isTrue);
  });

  test('cycle tracking defaults on for a female profile, and a choice wins',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    expect(app.cycleTrackingEnabled, isFalse);
    app.user = {'sex': 'f'};
    expect(app.cycleTrackingEnabled, isTrue);
    await app.setCycleTrackingEnabled(false);
    expect(app.cycleTrackingEnabled, isFalse);
  });

  testWidgets('a provider-free avatar still clears the tap floor', (t) async {
    await t.pumpWidget(_app(const Center(child: ProfileAvatar())));
    final size = t.getSize(find.byType(Pressable));
    expect(size.width, greaterThanOrEqualTo(S.tap));
    expect(size.height, greaterThanOrEqualTo(S.tap));
    expect(find.bySemanticsLabel('Profile and settings'), findsOneWidget);
  });

  test('the four-tab index is stored under its own key', () {
    expect(Prefs.shellTabV2, isNot(Prefs.shellTab));
  });

  testWidgets('the avatar shows an initial when a name is known', (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.user = {'name': 'sam'};
    await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: app, child: _app(const Center(child: ProfileAvatar()))));
    expect(find.text('S'), findsOneWidget);
  });
}
