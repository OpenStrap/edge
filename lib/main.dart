import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'ble/ios_ble_restore.dart';
import 'notify/notification_service.dart';
import 'state/app_state.dart';
import 'theme/theme_controller.dart';
import 'widget/widget_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Optional startup services. A failure in any one of these must NEVER block the
  // first frame — they are awaited before runApp, so an unguarded throw (e.g. the
  // flutter_local_notifications `invalid_icon` crash) leaves the app stuck on the
  // native launch screen (blank/icon). Guard each so the UI always boots.
  // iOS: registers the CoreBluetooth-restoration wake handler (no-op on Android).
  await _safeInit('IosBleRestore', IosBleRestore.init);
  await _safeInit('WidgetService', WidgetService.init);
  await _safeInit('NotificationService', NotificationService.instance.init);

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

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        ChangeNotifierProvider<ThemeController>.value(value: theme),
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
