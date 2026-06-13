import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'ble/ios_ble_restore.dart';
import 'state/app_state.dart';
import 'widget/widget_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // iOS: register the CoreBluetooth-restoration wake handler. On a background
  // relaunch this runs too, so a band-triggered wake reaches runHeadlessSync.
  await IosBleRestore.init();
  await WidgetService.init();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const OpenStrapApp(),
    ),
  );
}
