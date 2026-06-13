// Headless sync — runs the connect → drain → upload flow with NO UI, NO Provider.
// "Comes, does its job, goes." Invoked by the iOS CoreBluetooth-restoration RECOVERY
// path (ios_ble_restore.dart) when the band reappears after the live connection dropped.
//
// There is NO OS periodic scheduler anymore (no WorkManager 15-min task, no BGTask):
// continuous sync is the kept-alive live connection + the persistent flusher in
// AppState. This is purely the relaunch-recovery fallback.
//
// Connectivity-agnostic by design: it does NOT assume the strap stays connected.
// It connects-by-id if reachable, drains whatever the band buffered to flash
// (non-destructive cursor — catches up everything since last time), uploads, and
// disconnects. A missed run is harmless; the next reconnect catches up.

import 'package:flutter/widgets.dart';

import '../ble/ble_engine.dart';
import '../data/db.dart';
import '../net/api_client.dart';
import 'config.dart';
import 'uploader.dart';

/// One headless sync pass. Safe to call from a background isolate. Never throws.
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
      onRecordsBatch: LocalDb.insertRecordsBatch,
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
