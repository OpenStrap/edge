// Widget tests for onboarding and profile: the splash hands over once the
// app is ready, and an absent value is a StatusCard, never a bare dash.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/platform/app_icon.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/onboarding/pairing.dart';
import 'package:openstrap_edge/ui2/onboarding/profile_setup.dart';
import 'package:openstrap_edge/ui2/onboarding/splash.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// Fixed, so a test is never a function of the calendar or of a real band.
final _synced = DateTime(2026, 8, 22, 7, 12);

/// The alarm screen renders a relative day ("Tomorrow"), so both ends of that
/// comparison are pinned or the result is a function of when the suite runs.
final _alarmNow = DateTime(2026, 8, 21, 22, 40);
final _alarmAt = DateTime(2026, 8, 22, 6, 30); // Saturday → weekday index 5.

/// A representative weekly schedule: Saturday matches [_alarmAt] above (so
/// the armed-instant card and the schedule row agree, like a real one would),
/// Wednesday is a second enabled day, everything else is off.
final _alarmSchedule = fillDefaultAlarmSchedule(const [
  AlarmScheduleEntry(weekday: 5, hour: 6, minute: 30, enabled: true),
  AlarmScheduleEntry(weekday: 2, hour: 7, minute: 0, enabled: true),
]);

final _band = HealthSource(
  name: 'WHOOP 4.0',
  kind: 'WHOOP 4 · wrist optical',
  tier: SourceTier.wristOptical,
  icon: LucideIcons.watch,
  connected: true,
  batteryPct: 78,
  lastData: _synced,
  isBand: true,
);

const _phone = HealthSource(
  name: 'This phone',
  kind: 'Motion coprocessor',
  tier: SourceTier.phone,
  icon: LucideIcons.smartphone,
  connected: true,
);

Map<String, Widget> _cases() => {
      'welcome': WelcomeView(onNew: () {}, onImport: () {}),
      'welcome_import_lost': WelcomeView(
        onNew: () {},
        onImport: () {},
        outcome: const ImportOutcome(
            source: 'Raw sensor export',
            days: 412,
            lateRows: 1840,
            strandedDays: 3),
      ),
      'pairing_idle': PairingView(phase: PairPhase.idle, onPair: () {}, onSkip: () {}),
      'pairing_not_found':
          PairingView(phase: PairPhase.notFound, onPair: () {}, onSkip: () {}),
      'pairing_bond_refused': PairingView(
          phase: PairPhase.bondRefused,
          onPair: () {},
          onSkip: () {},
          detail: 'PlatformException(bond_failed, createBond returned false)'),
      'pairing_cancelled':
          PairingView(phase: PairPhase.cancelled, onPair: () {}, onSkip: () {}),
      'profile_setup': ProfileSetupView(onSave: (_) async {}),
      'profile_setup_filled': ProfileSetupView(
          initial: const {'sex': 'f', 'age': 34, 'weight_kg': 61.5},
          onSave: (_) async {}),
      'profile_home': const ProfileHomeView(
        stats: ProfileStats(
            name: 'Sahil', sources: 2, storageBytes: 1503238553),
      ),
      'profile_home_loading': const ProfileHomeView(),
      'my_devices': MyDevicesView(sources: [_band, _phone]),
      'my_devices_empty': const MyDevicesView(),
      'device_detail': DeviceDetailView(_band, onFind: () {}, onForget: () {}),
      'more_settings': const MoreSettingsView(
          units: 'Metric', appearance: 'Dark', phoneSteps: true),
      // The icon row appears only where the OS will actually change the icon,
      // so the default case above is drawn without it — this is the iOS one.
      'more_settings_icon': const MoreSettingsView(
          units: 'Metric',
          appearance: 'Dark',
          phoneSteps: true,
          appIcon: AppIconChoice.colourful),
      // The alarm's three confirmation states are the point of the screen: it
      // must not draw a confident tick over an alarm the band never
      // acknowledged.
      'alarm_none':
          AlarmScreenView(connected: true, schedule: _alarmSchedule),
      'alarm_confirmed': AlarmScreenView(
          armedAt: _alarmAt,
          now: _alarmNow,
          state: AlarmArmState.confirmed,
          connected: true,
          schedule: _alarmSchedule,
          onTest: () async {},
          onCancel: () async {}),
      'alarm_unconfirmed': AlarmScreenView(
          armedAt: _alarmAt,
          now: _alarmNow,
          state: AlarmArmState.unknown,
          connected: true,
          schedule: _alarmSchedule,
          onTest: () async {},
          onCancel: () async {}),
      'alarm_disconnected': AlarmScreenView(
          armedAt: _alarmAt,
          now: _alarmNow,
          state: AlarmArmState.unknown,
          schedule: _alarmSchedule),
      'notification_settings': const NotificationSettingsView(),
      'notification_settings_blocked': const NotificationSettingsView(
          granted: false,
          prefs: NotificationPrefs(
              deviceEnabled: false, quietStartMin: 23 * 60, quietEndMin: 6 * 60)),
      'edit_profile': EditProfileView(
        initial: const {
          'name': 'Sahil',
          'sex': 'm',
          'age': 34,
          'height_cm': 178.0,
          'weight_kg': 72.4,
        },
        onSave: (_) async {},
      ),
    };

final _shot = GlobalKey();

Widget _frame(Widget child, Brightness b, double scale) => MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: ChangeNotifierProvider<LocaleController>.value(
        value: LocaleController.seed(null),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(b),
          home: RepaintBoundary(key: _shot, child: child),
        ),
      ),
    );

/// The bundled type, so text measures as it does on a phone instead of as the
/// harness's block glyphs.
Future<void> _loadType() async {
  final files = Directory('assets/fonts/Manrope')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ttf'));
  for (final family in const ['Manrope', '.SF Pro Text']) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(f
          .readAsBytes()
          .then((b) => ByteData.sublistView(Uint8List.fromList(b))));
    }
    await loader.load();
  }
}


void main() {
  final cases = _cases();

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadType();
  });

  testWidgets('the splash uncovers the app once it is ready', (tester) async {
    await tester.pumpWidget(const MediaQuery(
      // Reduced motion: the cover has no fade to hide behind, so it must stop
      // existing rather than sit on top at opacity zero swallowing taps.
      data: MediaQueryData(disableAnimations: true),
      child: MaterialApp(
        home: BootSplash(ready: true, child: Text('the app')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('the app'), findsOneWidget);
    expect(find.byType(BootSplash), findsOneWidget);
  });

  testWidgets('an absent value is a StatusCard, never a bare dash',
      (tester) async {
    for (final entry in cases.entries) {
      await tester.pumpWidget(_frame(entry.value, Brightness.light, 1));
      await tester.pumpAndSettle();
      expect(find.text('—'), findsNothing, reason: entry.key);
    }
  });
}
