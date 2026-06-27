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

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/ble_engine.dart';
import '../compute/derivation_engine.dart';
import '../compute/profile.dart';
import '../data/db.dart';
import 'paired_device.dart';

/// Load the local profile (no Provider in the headless isolate).
Future<Profile> _loadProfile() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('local_profile_json');
    if (raw == null) return const Profile();
    return Profile.fromMap((jsonDecode(raw) as Map).cast<String, dynamic>());
  } catch (_) {
    return const Profile();
  }
}

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
      onCommitBatch: (raws, samples, trimTokenHex) =>
          LocalDb.commitSyncBatch(raws, samples, trimToken: trimTokenHex),
      cursorReader: LocalDb.getCursorInt,
    );

    // connect() subscribes → SET_CLOCK → INIT, so the historical offload is already
    // streaming when this returns. We then await it reaching HISTORY_COMPLETE.
    final connected = await engine.connectToRemoteId(paired.remoteId);
    if (!connected) {
      debugPrint('[bgsync] strap not reachable this cycle — will catch up next time.');
      return true;
    }
    try {
      // Await the full backlog (default timeout): a phone-free run/sleep can leave a
      // large offline backlog on the band's flash. We never abort — if iOS cuts the
      // background window short, the offload persists what it got (flush-before-ACK)
      // and the next wake resumes from the (now-advanced) cursor. No live streams
      // (battery): connect → listen → store → ACK → derive → disconnect.
      await engine.runSync();
    } finally {
      await engine.disconnect();
    }
    // Within the SAME background wake slot: capture raw AND derive the fresh
    // window (bounded LIGHT pass — newest affected day only — so we stay inside
    // the short iOS execution budget). Best-effort; if the slot ends first, the
    // light pass on the next drain or the foreground finalize catches up.
    try {
      await DerivationEngine(log: (l) => debugPrint('[bgsync-derive] $l'))
          .run(await _loadProfile());
    } catch (e) {
      debugPrint('[bgsync] derive skipped: $e');
    }
    debugPrint('[bgsync] done (local drain + light derive).');
    return true;
  } catch (e) {
    debugPrint('[bgsync] error (ignored): $e');
    return true;
  }
}
