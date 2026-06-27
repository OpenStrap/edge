// headless_boot.dart — Android post-reboot headless auto-connect.
//
// When Android boots the device, BootReceiver starts EdgeTrackingService, which
// causes EdgeApplication.onCreate to pre-warm the FlutterEngine. That engine runs
// main() with no Activity attached. We detect the headless (no-Activity) case here
// and, if a band is paired, start the foreground service + kick a headless sync so
// the band reconnects automatically without user interaction.
//
// Idempotency: EdgeTracking.start() is already idempotent (just sends "start" to
// the existing service). runHeadlessSync() uses a connect-by-id path; if the
// foreground AppState later attaches, it re-uses the same BleEngine and doesn't
// double-connect because BleEngine.connectToRemoteId is guarded by its own state
// machine. The headless sync runs once (await) and then sits idle; the real live
// connection is managed by AppState when the UI opens.
//
// NOT called on iOS — iOS background relaunch is handled by BleRestoreManager +
// IosBleRestore (CB state restoration wake). iOS does NOT have an Activity concept,
// so this Android-only path is guarded by Platform.isAndroid.

import 'dart:io';

import 'package:flutter/widgets.dart';

import '../sync/background_sync.dart';
import '../sync/edge_tracking.dart';
import '../sync/paired_device.dart';

/// Guards headless boot so we only run once per process lifetime. Prevents
/// re-entry if main() is somehow invoked twice on the same engine.
bool _booted = false;

/// Call from main() before runApp (but after WidgetsFlutterBinding.ensureInitialized).
/// On Android with no Activity, checks for a paired band and auto-connects headlessly.
///
/// Returns immediately if:
///   - not Android
///   - not a headless launch (UI is present)
///   - no paired device
///   - already ran
///
/// This is deliberately SYNCHRONOUS from the call-site perspective — the caller
/// awaits so startup init stays ordered, but the actual BLE work is fire-and-forget
/// after we start the service (connect happens asynchronously in the engine).
Future<void> maybeHeadlessBoot() async {
  if (!Platform.isAndroid) return;
  if (_booted) return;
  _booted = true;

  // Detect headless: are we running with no Activity attached to the engine?
  // When launched via BootReceiver the engine runs but the binding's window/view
  // is not ready. We use the heuristic that WidgetsBinding has no renderView / no
  // view attached yet. A simpler check: if there are no views, we are headless.
  final hasView = WidgetsBinding.instance.renderViews.isNotEmpty;
  if (hasView) {
    // A real Activity is attached — normal foreground launch, skip headless path.
    return;
  }

  final paired = await PairedDevice.load();
  if (paired == null) return; // nothing paired, nothing to do

  debugPrint('[headless-boot] no view — headless boot, starting EdgeTracking');
  // Ensure the foreground service is running (it was started by BootReceiver, but
  // calling start() again here is safe — EdgeTracking.start() is idempotent).
  await EdgeTracking.start();

  // Run a single headless drain pass (connect → flash offload → local store →
  // disconnect). This catches up the offline backlog accumulated while the phone
  // was powered off. Errors are swallowed inside runHeadlessSync.
  debugPrint('[headless-boot] starting headless sync for ${paired.remoteId}');
  runHeadlessSync().then((_) {
    debugPrint('[headless-boot] headless sync complete');
  });
}
