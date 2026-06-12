// Background sync — runs the connect → drain → upload flow with NO UI, NO
// Provider, NO foreground service / sticky notification. "Comes, does its job,
// goes." Reused by the OS periodic scheduler (WorkManager on Android, BGTask on
// iOS via the workmanager plugin) and callable directly.
//
// Connectivity-agnostic by design: it does NOT assume the strap stays connected.
// Each run just connects-by-id if reachable, drains whatever the band buffered to
// flash (non-destructive cursor — catches up everything since last time), uploads,
// and disconnects. A missed window is harmless; the next run catches up.

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../ble/ble_engine.dart';
import '../data/db.dart';
import '../net/api_client.dart';
import 'config.dart';
import 'uploader.dart';

/// Unique name + tag for the periodic OS task.
const String _kPeriodicTask = 'openstrap.periodicSync';

/// One headless sync pass. Safe to call from a background isolate. Never throws —
/// returns true so the OS scheduler treats the run as handled (no thrash-retry).
Future<bool> runHeadlessSync() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final config = await BackendConfig.load();
    final session = await Session.load();
    final paired = await PairedDevice.load();
    if (!session.isValid || paired == null) {
      debugPrint('[bgsync] not signed in / not paired — nothing to do.');
      return true;
    }

    final api = ApiClient(config, session); // no onLoggedOut in headless mode
    final uploader = Uploader(api);

    // 1. Flush any backlog first — covers the case where a prior run captured
    //    records but the upload leg failed (offline, etc.).
    await uploader.uploadPending();
    await uploader.uploadEvents();

    // 2. Connect → drain → upload. No live streams (battery): in and out.
    final engine = BleEngine(
      onRecord: (sample, raw) => LocalDb.insertRecord(raw, sample),
      onState: (_) {},
      onEvent: (id, ts, hex) => LocalDb.insertEvent(id, ts, hex),
      log: (l) => debugPrint('[bgsync] $l'),
    );

    final connected = await engine.connectToRemoteId(paired.remoteId);
    if (!connected) {
      debugPrint('[bgsync] strap not reachable this cycle — will catch up next time.');
      return true;
    }
    try {
      await engine.runSync(timeout: const Duration(seconds: 120));
      await uploader.uploadPending();
      await uploader.uploadEvents();
    } finally {
      await engine.disconnect();
    }
    debugPrint('[bgsync] done.');
    return true;
  } catch (e) {
    debugPrint('[bgsync] error (ignored): $e');
    return true;
  }
}

/// WorkManager/BGTask entry point. MUST be a top-level function annotated for the
/// AOT compiler so the background isolate can find it.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) => runHeadlessSync());
}

/// Thin facade over the OS scheduler.
class BackgroundSync {
  /// Call once at app start (registers the isolate entry point).
  static Future<void> init() async {
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  }

  /// Schedule the periodic background sync. 15 min is the OS floor; the OS may run
  /// it less often (Doze / iOS throttling) — fine, since the drain catches up.
  /// Requires network; idempotent (keep existing if already scheduled).
  static Future<void> enable() async {
    await Workmanager().registerPeriodicTask(
      _kPeriodicTask,
      _kPeriodicTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.linear,
      backoffPolicyDelay: const Duration(minutes: 5),
    );
  }

  /// Stop background sync (on sign-out / unpair).
  static Future<void> disable() async {
    await Workmanager().cancelByUniqueName(_kPeriodicTask);
  }
}
