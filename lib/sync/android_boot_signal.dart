import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native boot signal for Android headless launches.
///
/// Native only returns true when:
/// - BootReceiver previously marked a pending headless boot
/// - no `MainActivity` is currently attached
///
/// That closes the "first foreground open after reboot" hole where a pending
/// boot flag could otherwise be consumed by a normal UI launch.
class AndroidBootSignal {
  AndroidBootSignal._();

  static const MethodChannel _ch = MethodChannel('openstrap/edge_tracking');

  static Future<bool> consumePendingHeadlessBoot() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('consumeHeadlessBootPending') ??
          false;
    } catch (e) {
      debugPrint('[android-boot-signal] consume failed: $e');
      return false;
    }
  }
}
