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
import 'file_log.dart';
import 'uploader.dart';

/// Persistent, timestamped breadcrumb for the headless path. debugPrint is
/// invisible in the field (no UI, separate isolate), so every stage also goes to
/// the pullable log file — that's how we tell "task never fired" apart from
/// "task fired but BLE failed".
Future<void> _bg(String line) async {
  final ts = DateTime.now().toIso8601String();
  debugPrint('[bgsync] $line');
  await FileLog.write('$ts [bgsync] $line');
}

/// Unique name + tag for the periodic OS task.
const String _kPeriodicTask = 'openstrap.periodicSync';

/// One headless sync pass. Safe to call from a background isolate. Never throws —
/// returns true so the OS scheduler treats the run as handled (no thrash-retry).
Future<bool> runHeadlessSync() async {
  WidgetsFlutterBinding.ensureInitialized();
  // FIRST line — proves the OS actually woke the isolate. If this never appears
  // in the log, the task isn't firing (almost always battery/autostart on the
  // phone), not a code problem.
  await _bg('==== task fired ====');
  try {
    final config = await BackendConfig.load();
    final session = await Session.load();
    final paired = await PairedDevice.load();
    await _bg('config loaded · signedIn=${session.isValid} paired=${paired != null}');
    if (!session.isValid || paired == null) {
      await _bg('not signed in / not paired — nothing to do.');
      return true;
    }

    final api = ApiClient(config, session); // no onLoggedOut in headless mode
    final uploader = Uploader(api);

    // 1. Flush any backlog first — covers the case where a prior run captured
    //    records but the upload leg failed (offline, etc.).
    final backlog = await uploader.uploadPending();
    await uploader.uploadEvents();
    await _bg('flushed backlog: attempted=${backlog.attempted} '
        'accepted=${backlog.accepted}${backlog.error != null ? " err=${backlog.error}" : ""}');

    // 2. Connect → drain → upload. No live streams (battery): in and out.
    final engine = BleEngine(
      onRecord: (sample, raw) => LocalDb.insertRecord(raw, sample),
      onState: (_) {},
      onEvent: (id, ts, hex) => LocalDb.insertEvent(id, ts, hex),
      log: (l) => _bg('ble: $l'),
      onRecordsBatch: LocalDb.insertRecordsBatch,
    );

    await _bg('connecting to ${paired.remoteId} ...');
    final connected = await engine.connectToRemoteId(paired.remoteId);
    if (!connected) {
      await _bg('strap not reachable this cycle — will catch up next time.');
      return true;
    }
    await _bg('connected — draining');
    try {
      final report = await engine.runSync(timeout: const Duration(seconds: 120));
      final up = await uploader.uploadPending();
      await uploader.uploadEvents();
      await _bg('drained records=${report.records} batches=${report.batches} '
          'complete=${report.complete} · uploaded accepted=${up.accepted}/${up.attempted}');
    } finally {
      await engine.disconnect();
    }
    await _bg('==== done ====');
    return true;
  } catch (e, st) {
    // Log the failure loudly — this is where a missing plugin in the background
    // isolate (MissingPluginException) or a BLE error shows up.
    await _bg('ERROR: $e');
    await _bg('stack: $st');
    return true;
  }
}

/// WorkManager/BGTask entry point. MUST be a top-level function annotated for the
/// AOT compiler so the background isolate can find it.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    await _bg('executeTask($task)');
    return runHeadlessSync();
  });
}

/// Thin facade over the OS scheduler.
class BackgroundSync {
  /// Call once at app start (registers the isolate entry point).
  static Future<void> init() async {
    await Workmanager().initialize(callbackDispatcher);
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
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.linear,
      backoffPolicyDelay: const Duration(minutes: 5),
    );
  }

  /// Fire the headless path ONCE, right now, through the real OS scheduler — same
  /// background isolate and entry point the periodic task uses. This is the test
  /// button: if the periodic sync silently does nothing, run this and read the
  /// log. No constraints so it runs immediately even on a flaky network.
  static Future<void> runOnceNow() async {
    await _bg('runOnceNow() requested from UI');
    await Workmanager().registerOneOffTask(
      'openstrap.syncNow.${DateTime.now().millisecondsSinceEpoch}',
      _kPeriodicTask,
    );
  }

  /// Stop background sync (on sign-out / unpair).
  static Future<void> disable() async {
    await Workmanager().cancelByUniqueName(_kPeriodicTask);
  }
}
