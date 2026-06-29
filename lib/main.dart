import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'telemetry/telemetry_service.dart';
import 'ble/ios_ble_restore.dart';
import 'compute/background_derivation.dart';
import 'notify/notification_service.dart';
import 'coach/coach_config.dart';
import 'state/app_state.dart';
import 'state/prefs.dart';
import 'state/units_controller.dart';
import 'sync/headless_boot.dart';
import 'sync/ios_bg_task.dart';
import 'theme/theme_controller.dart';
import 'widget/widget_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Install crash/error hooks (FlutterError.onError + PlatformDispatcher.onError)
  // BEFORE anything else. Capture is always-on and LOCAL; nothing transmits until
  // the user opts in (TelemetryService.enabled). No custom zone — these two hooks
  // catch framework + uncaught async errors on their own, and a custom root zone
  // is a known source of release-startup fragility.
  TelemetryService.instance.installErrorHandlers();

  // iOS CoreBluetooth State Preservation & Restoration: opt the flutter_blue_plus
  // central (the one that actually subscribes to the band's HR/event characteristics)
  // into a restore identifier. Apple preserves a connection AND its characteristic
  // subscriptions ONLY for a central created with a restore id — without this, a
  // suspended app resumes with the peripheral still flagged "connected" but its GATT
  // notifications dead until a full reconnect+re-subscribe (the "connected, no events"
  // bug). MUST be set before any other FBP call. No-op on Android.
  try {
    await FlutterBluePlus.setOptions(restoreState: true);
  } catch (_) {/* older plugin / unsupported platform — ignore */}
  try {
    await FlutterBluePlus.setLogLevel(LogLevel.none, color: false);
  } catch (_) {/* older plugin / unsupported platform — ignore */}

  // Optional startup services. A failure in any one of these must NEVER block the
  // first frame — they are awaited before runApp, so an unguarded throw (e.g. the
  // flutter_local_notifications `invalid_icon` crash) leaves the app stuck on the
  // native launch screen (blank/icon). Guard each so the UI always boots.
  // iOS: registers the CoreBluetooth-restoration wake handler (no-op on Android).
  await _safeInit('IosBleRestore', IosBleRestore.init);
  // iOS: BGProcessingTask Dart handler (openstrap/bg_task channel). No-op on Android.
  await _safeInit('IosBgTask', IosBgTask.init);
  // Android: headless auto-connect after reboot (no-op if a view is attached or iOS).
  await _safeInit('HeadlessBoot', maybeHeadlessBoot);
  await _safeInit('WidgetService', WidgetService.init);
  await _safeInit('NotificationService', NotificationService.instance.init);
  // Schedule the heavy nightly derivation (Android WorkManager; iOS now also has a
  // BGProcessingTask via BackgroundTasks.swift — see background_derivation.dart).
  await _safeInit('BackgroundDerivation', BackgroundDerivation.init);
  // Cache SharedPreferences so UI screens can synchronously RESTORE saved
  // selections (tab, range toggles) in initState with no async flash.
  await _safeInit('Prefs', Prefs.ensureLoaded);

  // Resolve appearance (persisted choice + OS brightness) BEFORE the first frame
  // so login/signup already paint in the right mode (Ember on Paper / Char).
  // Fall back to a system-brightness controller if persistence fails.
  ThemeController theme;
  try {
    theme = await ThemeController.bootstrap();
  } catch (e, st) {
    debugPrint('[main] ThemeController.bootstrap failed, using default: $e\n$st');
    theme = ThemeController.seed(
      AppThemeChoice.system,
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
  }

  // Local display-units preference (metric/imperial). Best-effort; defaults to metric.
  UnitsController units;
  try {
    units = await UnitsController.bootstrap();
  } catch (e, st) {
    debugPrint('[main] UnitsController.bootstrap failed, using metric: $e\n$st');
    units = UnitsController.seed(UnitSystem.metric);
  }

  // Local BYOK AI-coach config (key in keychain). Best-effort load.
  final coachConfig = CoachConfig();
  try {
    await coachConfig.load();
  } catch (e, st) {
    debugPrint('[main] CoachConfig.load failed: $e\n$st');
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<UnitsController>.value(value: units),
        ChangeNotifierProvider<CoachConfig>.value(value: coachConfig),
      ],
      child: const OpenStrapApp(),
    ),
  );
}

/// Run an optional startup init, swallowing (but logging) any failure so it can
/// never prevent runApp from being reached.
Future<void> _safeInit(String label, Future<void> Function() init) async {
  try {
    await init();
  } catch (e, st) {
    debugPrint('[main] $label init failed (continuing without it): $e\n$st');
  }
}
