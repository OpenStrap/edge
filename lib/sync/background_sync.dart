// Headless LOCAL drain — runs the connect → drain → store-locally flow with NO UI,
// NO Provider, and (since the cloud excision) NO upload. "Comes, does its job, goes."
// Invoked by the iOS CoreBluetooth-restoration RECOVERY path (ios_ble_restore.dart)
// when the band reappears after the live connection dropped.
//
// There is NO OS periodic scheduler (no WorkManager task, no BGTask): continuous
// capture is the kept-alive live connection in AppState. This is purely the
// relaunch-recovery fallback that pulls the band's offline flash backlog into the
// local SQLite store (lib/data/db.dart), the system of record. A missed run is
// harmless; the next reconnect catches up from the non-destructive cursor.

import 'package:flutter/widgets.dart';

import '../ble/ble_engine.dart';
import '../data/db.dart';
import 'paired_device.dart';

/// One headless LOCAL drain pass. Safe to call from a background isolate. Never
/// throws. Connects-by-id if reachable, drains whatever the band buffered to
/// flash into local storage (non-destructive cursor — catches up everything since
/// last time), and disconnects. No network.
Future<bool> runHeadlessSync() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final paired = await PairedDevice.load();
    if (paired == null) {
      debugPrint('[bgsync] not paired — nothing to do.');
      return true;
    }

    // Connect → drain → store. No live streams (battery): in and out.
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
      // Full drain (default timeout): a phone-free run/sleep can leave a large
      // offline backlog on the band's flash. If iOS cuts the background window
      // short, the drain persists what it got (flush-before-ACK) and the next wake
      // resumes from the cursor — so a longer budget only helps, never hurts.
      await engine.runSync();
    } finally {
      await engine.disconnect();
    }
    debugPrint('[bgsync] done (local drain only).');
    return true;
  } catch (e) {
    debugPrint('[bgsync] error (ignored): $e');
    return true;
  }
}
