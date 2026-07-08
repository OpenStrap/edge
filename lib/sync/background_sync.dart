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
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import 'band_ownership.dart';
import 'high_freq_wake_window.dart';
import 'paired_device.dart';
import 'sync_policy.dart';

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
Future<bool> runHeadlessSync({BandLease? lease}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final ownedLease = lease ?? BandOwnership.tryAcquireHeadless();
  if (ownedLease == null) {
    debugPrint(
      '[bgsync] skipped — foreground or another headless session owns the band '
      '(${BandOwnership.debugState}).',
    );
    return true;
  }
  debugPrint(
    '[bgsync] acquired headless lease=${ownedLease.token} '
    '(${BandOwnership.debugState})',
  );
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
      onCommitBatch: (raws, samples, trimTokenHex, {archives}) =>
          LocalDb.commitSyncBatch(raws, samples,
              trimToken: trimTokenHex,
              archives: archives,
              onCheckpoint: (msg) => debugPrint('[bgsync][COMMIT] $msg')),
      onArchiveRecord: LocalDb.archiveRawRecord,
      cursorReader: LocalDb.getCursorInt,
      // Mark this as the background drainer: if the foreground app engine already
      // owns the band (same process — iOS restore-wake OR Android headless boot /
      // foreground service), this engine YIELDS instead of opening a second drain
      // that would double-ACK the same offload and stall the trim cursor.
      isBackgroundDrainer: true,
    );

    // connect() subscribes → SET_CLOCK → INIT, so the historical offload is already
    // streaming when this returns. We then await it reaching HISTORY_COMPLETE.
    final connected = await engine.connectToRemoteId(paired.remoteId);
    if (!connected) {
      debugPrint(
        '[bgsync] strap not reachable this cycle — will catch up next time.',
      );
      await checkSyncStaleness();
      return true;
    }
    try {
      final plan = await HighFreqWakeWindow.planNow();
      await engine.applyHighFreqWakeWindow(
        enabled: plan.shouldEnable,
        targetWake: plan.targetWake,
        duration: HighFreqWakeWindow.lease,
        intervalSeconds: 60,
        reason: plan.source,
      );
      debugPrint(
        '[bgsync] HighFreq wake window: source=${plan.source} '
        'samples=${plan.sampleCount} enabled=${plan.shouldEnable} '
        'target=${plan.targetWake?.toIso8601String()}',
      );
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
      await DerivationEngine(
        log: (l) => debugPrint('[bgsync-derive] $l'),
      ).run(await _loadProfile());
    } catch (e) {
      debugPrint('[bgsync] derive skipped: $e');
    }
    debugPrint('[bgsync] done (local drain + light derive).');
    await checkSyncStaleness();
    return true;
  } catch (e) {
    debugPrint('[bgsync] error (ignored): $e');
    return true;
  } finally {
    debugPrint(
      '[bgsync] releasing headless lease=${ownedLease.token} '
      '(${BandOwnership.debugState})',
    );
    BandOwnership.release(ownedLease);
  }
}

// ── staleness escalation (meta-layer over the whole reconnect/sync ladder) ──
// See sync_policy.dart's stalenessTierFor doc. Evaluated at the end of every
// headless cycle (success OR a failed connect attempt — both are meaningful
// signals here), independent of THIS cycle's outcome: it reads the durable
// `rec_ts_hw` cursor, which reflects the full sync history, not just this run.
const String _kLastStalenessNotifiedMs = 'last_staleness_notified_ms';

/// [allowPermissionPrompt] defaults to `false` because this function's
/// PRIMARY callers (below, inside [runHeadlessSync]) run headless — see
/// NotificationCenter.emit's doc on why a background context must never
/// trigger the OS's interactive authorization prompt. app_state.dart's
/// foreground call (via runCadenceChecks, a genuinely contextual moment)
/// passes `true` explicitly.
Future<void> checkSyncStaleness({bool allowPermissionPrompt = false}) async {
  try {
    final recTsHw = await LocalDb.getCursorInt('rec_ts_hw');
    // Never synced at all (e.g. freshly paired, first drain still pending) —
    // nothing to escalate; that's a distinct, already-visible onboarding
    // state, not silent staleness.
    if (recTsHw == null || recTsHw <= 0) return;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tier = stalenessTierFor(nowSec - recTsHw);
    if (tier != StalenessTier.notify) return;

    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(_kLastStalenessNotifiedMs);
    final lastAt =
        lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs);
    final now = DateTime.now();
    if (!shouldRenotifyStaleness(lastAt, now)) return;

    await prefs.setInt(_kLastStalenessNotifiedMs, now.millisecondsSinceEpoch);
    final hoursStale = (nowSec - recTsHw) ~/ 3600;
    await NotificationCenter.instance.emit(
      NotificationEvent(
        // Date-bucketed so a legitimate re-fire after the cooldown isn't
        // blocked by putNotification's INSERT-OR-IGNORE dedupe.
        dedupeKey: '${now.toIso8601String().substring(0, 10)}:sync_stale',
        category: NotifCategory.device,
        priority: NotifPriority.normal, // respects quiet hours — not urgent
        title: "Your band hasn't synced in a while",
        body: 'No new data for about $hoursStale hours. Open OpenStrap to '
            'reconnect — background sync may have stalled.',
        date: now.toIso8601String().substring(0, 10),
        route: '/today',
      ),
      allowPermissionPrompt: allowPermissionPrompt,
    );
    debugPrint(
      '[bgsync] staleness notification fired (hours_stale=$hoursStale).',
    );
  } catch (e) {
    debugPrint('[bgsync] staleness check skipped: $e');
  }
}
