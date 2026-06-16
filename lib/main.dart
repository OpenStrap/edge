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
  // iOS: register the CoreBluetooth-restoration wake handler. On a background
  // relaunch this runs too, so a band-triggered wake reaches runHeadlessSync.
  await IosBleRestore.init();
  await WidgetService.init();
  await NotificationService.instance.init(); // sets up the notif plugin + channel

  // Resolve appearance (persisted choice + OS brightness) BEFORE the first frame
  // so login/signup already paint in the right mode (Ember on Paper / Char).
  final theme = await ThemeController.bootstrap();
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
