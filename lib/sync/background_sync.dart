// Headless LOCAL drain — runs the connect → drain → store-locally flow with NO UI,
// NO Provider, and (since the cloud excision) NO upload. "Comes, does its job, goes."
// Invoked by the iOS CoreBluetooth-restoration RECOVERY path (ios_ble_restore.dart)
// when the band reappears after the live connection dropped.
//
// There is NO OS periodic scheduler on Android (the old WorkManager tasks were
// removed — background_derivation.dart is a tombstone; main.dart still cancels
// their persisted registrations by name). iOS registers opportunistic BGTasks
// (ios_bg_task.dart) that are never guaranteed. Continuous capture is the
// kept-alive live connection in AppState. This is purely the relaunch-recovery
// fallback that pulls the band's offline flash backlog into the local SQLite
// store (lib/data/db.dart), the system of record. A missed run is harmless;
// the next reconnect catches up from the non-destructive cursor.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/adapters/_registry.dart' show kWhoopGen4;
import '../ble/adapters/host.dart' show BandHost;
import '../ble/adapters/whoop_gen4.dart' show WhoopFramedAdapter;
import '../ble/banglejs_link.dart';
import '../ble/ble_engine.dart';
import '../ble/casio_link.dart';
import '../ble/colmi_link.dart';
import '../ble/coros_link.dart';
import '../ble/dafit_link.dart';
import '../ble/garmin_link.dart';
import '../ble/id115_link.dart';
import '../ble/jyou_link.dart';
import '../ble/lefun_link.dart';
import '../ble/makibeshr3_link.dart';
import '../ble/miband_link.dart';
import '../ble/oura_link.dart';
import '../ble/o2ring_link.dart';
import '../ble/pebble_link.dart';
import '../ble/pinetime_link.dart';
import '../ble/qhybrid_link.dart';
import '../ble/ringconn_link.dart';
import '../ble/smaq2oss_link.dart';
import '../ble/tlw64_link.dart';
import '../ble/ultrahuman_link.dart';
import '../ble/watch9_link.dart';
import '../ble/wearfit_link.dart';
import '../ble/withings_steel_hr_link.dart';
import '../ble/xwatch_link.dart';
import '../ble/zetime_link.dart';
import '../compute/derivation_engine.dart';
import '../compute/profile.dart';
import '../data/db.dart';
import '../notify/notification_center.dart';
import '../notify/notification_event.dart';
import '../state/alarm_schedule.dart';
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
    // `bandHost` is `late final`: the closure below captures the variable,
    // not a value, so it is fine that it is only assigned after `engine`
    // (whose facade adapter needs `engine` itself) is constructed.
    late final BandHost bandHost;
    final engine = BleEngine(
      onRecord: (sample, raw) => LocalDb.insertRecord(raw, sample),
      onState: (_) {},
      // This path drains exactly the one paired band (PairedDevice.load()),
      // so kPrimaryDeviceId is the correct value here, not a placeholder.
      onEvent: (id, ts, hex) =>
          LocalDb.insertEvent(id, ts, hex, deviceId: LocalDb.kPrimaryDeviceId),
      log: (l) => debugPrint('[bgsync] $l'),
      onRecordsBatch: LocalDb.insertRecordsBatch,
      // Routed through BandHost (M1a) rather than calling
      // LocalDb.commitSyncBatch directly — same durable commit, same
      // arguments, one extra await frame, and the SAME failure contract:
      // `commitNativeBatch` rethrows so `DrainController.commit` still reads
      // durability from a throw and `TrimAckPolicy` still blocks the ACK.
      onCommitBatch: (raws, samples, trimTokenHex, {archives, deviceFamily}) =>
          bandHost.commitNativeBatch(raws, samples, trimTokenHex,
              archives: archives, deviceFamily: deviceFamily),
      onArchiveRecord: LocalDb.archiveRawRecord,
      cursorReader: (base) =>
          LocalDb.getCursorInt(LocalDb.cursorKeyFor(base, LocalDb.kPrimaryDeviceId)),
      // Mark this as the background drainer: if the foreground app engine already
      // owns the band (same process — iOS restore-wake OR Android headless boot /
      // foreground service), this engine YIELDS instead of opening a second drain
      // that would double-ACK the same offload and stall the trim cursor.
      isBackgroundDrainer: true,
    );
    bandHost = BandHost(
      adapter: WhoopFramedAdapter(engine, kWhoopGen4),
      deviceId: LocalDb.kPrimaryDeviceId,
      onLog: (msg) => debugPrint('[bgsync][COMMIT] $msg'),
    );

    // connect() subscribes → SET_CLOCK → INIT, so the historical offload is already
    // streaming when this returns. We then await it reaching HISTORY_COMPLETE.
    final connected = await engine.connectToRemoteId(paired.remoteId,
        generationHint: paired.generation);
    if (!connected) {
      debugPrint(
        '[bgsync] strap not reachable this cycle — will catch up next time.',
      );
      await checkSyncStaleness();
      return true;
    }
    // Pin the discovered generation onto the pairing record, exactly like the
    // foreground engine-state heal does — a headless-only phone would
    // otherwise re-probe the connect route on every wake forever.
    final gen = engine.state.generation;
    if ((gen == 'gen4' || gen == 'gen5') && gen != paired.generation) {
      await PairedDevice.save(paired.remoteId, paired.serial, generation: gen);
    }
    try {
      final plan = await HighFreqWakeWindow.planNow();
      await engine.applyHighFreqWakeWindow(
        enabled: plan.shouldEnable,
        targetWake: plan.targetWake,
        duration: HighFreqWakeWindow.lease,
        intervalSeconds: 61, // gen5 rejects <= 60

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
      // Feature 1's arming engine, headless half: "on every successful
      // connect AND after each headless sync". No AppState here, so the
      // schedule read and the `alarm_epoch` persistence go straight through
      // LocalDb/SharedPreferences — the same store the foreground path uses,
      // so whichever side runs next sees a consistent value.
      try {
        final schedule = fillDefaultAlarmSchedule([
          for (final r in await LocalDb.alarmScheduleRows())
            AlarmScheduleEntry.fromRow(r),
        ]);
        final prefs = await SharedPreferences.getInstance();
        final result = await armNextScheduledOccurrence(
          engine: engine,
          schedule: schedule,
          currentArmedEpoch: prefs.getInt('alarm_epoch'),
        );
        if (result.disabled) {
          await prefs.remove('alarm_epoch');
          await prefs.remove('alarm_epoch_confirmed');
        } else if (result.epoch != null) {
          final epoch = result.epoch!;
          // No live AppState here to catch a late ALARM_SET (event 56) the way
          // the foreground grace timer does, so wait for it inline — same
          // grace window as AlarmConfirmation's default (6s) — before this
          // headless connection closes. Not confirmed within that window still
          // persists the epoch (optimistic, matching the foreground write) but
          // as unconfirmed, so the 7pm safety check (AppState._alarmArmedTonight)
          // won't wrongly treat an un-latched headless arm as covering tonight.
          final armedAtMs = DateTime.now().millisecondsSinceEpoch;
          var confirmed = false;
          for (var i = 0; i < 6 && !confirmed; i++) {
            await Future.delayed(const Duration(milliseconds: 1000));
            confirmed = await LocalDb.alarmSetConfirmedSince(armedAtMs);
          }
          await prefs.setInt('alarm_epoch', epoch);
          await prefs.setBool('alarm_epoch_confirmed', confirmed);
        }
      } catch (e) {
        debugPrint('[bgsync] alarm re-arm skipped: $e');
      }
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
        background: true,
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
    // Piggyback paired sensors on the same OS wake window, after the band
    // work is fully done so neither can ever delay or interfere with WHOOP's
    // own timing. Both `sync()` calls already no-op when nothing is paired
    // and never throw, but this is the one shared headless entry point (every
    // wake source funnels through runHeadlessSync via HeadlessSyncGate) so a
    // failure in either must not be allowed to escape and mark the WHOOP
    // cycle as errored.
    try {
      await OuraLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] oura sync skipped: $e');
    }
    // Same piggyback, same reasoning: CorosLink.sync() no-ops when nothing is
    // paired and never throws, but this is the one shared headless entry
    // point, so a failure here must not escape either.
    try {
      await CorosLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] coros sync skipped: $e');
    }
    // Same piggyback, same reasoning: GarminLink.sync() no-ops when nothing
    // is paired and never throws, but this is the one shared headless entry
    // point, so a failure here must not escape either.
    try {
      await GarminLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] garmin sync skipped: $e');
    }
    // Same piggyback, same reasoning: UltrahumanLink.sync() no-ops when
    // nothing is paired and never throws, but this call must not be allowed
    // to escape and mark the WHOOP cycle as errored either way.
    try {
      await UltrahumanLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] ultrahuman sync skipped: $e');
    }
    // Same reasoning, same wake window: a paired Withings row otherwise never
    // gets a second connection past pairing, since nothing else calls this.
    try {
      await WithingsSteelHrLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] withings sync skipped: $e');
    }
    // Same reasoning, same slot, for a paired Mi Band: MiBand234Link.sync()
    // also no-ops when nothing is paired and never throws, but guard it
    // anyway so a surprise failure here still can't mark the WHOOP cycle
    // errored.
    try {
      await MiBand234Link.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] miband234 sync skipped: $e');
    }
    // Same piggyback, same reasoning: a bounded connect-drain window that
    // no-ops when nothing is paired and must never mark the WHOOP cycle
    // errored on its own failure.
    try {
      await PebbleLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] pebble sync skipped: $e');
    }
    // Same piggyback, same reasoning: MakibesHr3Link.sync() already no-ops
    // when nothing is paired and never throws, but a failure here still
    // must not escape and mark the WHOOP cycle as errored.
    try {
      await MakibesHr3Link.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] makibeshr3 sync skipped: $e');
    }
    // Same piggyback, same reasoning: Id115Link.sync() already no-ops when
    // nothing is paired and never throws, but a failure here still must not
    // escape and mark the WHOOP cycle as errored.
    try {
      await Id115Link.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] id115 sync skipped: $e');
    }
    // Same piggyback, same reasoning: Smaq2ossLink.sync() already no-ops
    // when nothing is paired and never throws, but a failure here still must
    // not escape and mark the WHOOP cycle as errored.
    try {
      await Smaq2ossLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] smaq2oss sync skipped: $e');
    }
    // Same piggyback, same reasoning: XWatchLink.sync() already no-ops when
    // nothing is paired and never throws, but a failure here still must not
    // escape and mark the WHOOP cycle as errored.
    try {
      await XWatchLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] xwatch sync skipped: $e');
    }
    // Same piggyback, same reasoning: Tlw64Link.sync() already no-ops when
    // nothing is paired and never throws, but a failure here still must not
    // escape and mark the WHOOP cycle as errored.
    try {
      await Tlw64Link.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] tlw64 sync skipped: $e');
    }
    // Same piggyback, same reasoning: DafitLink.sync() no-ops when nothing is
    // paired and never throws, but this is the one shared headless entry
    // point, so a failure here must not escape either.
    try {
      await DafitLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] dafit sync skipped: $e');
    }
    // Same reasoning as the Oura piggyback just above: no-ops when nothing is
    // paired, never allowed to mark the WHOOP cycle as errored.
    try {
      await O2RingLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] o2ring sync skipped: $e');
    }
    // Same piggyback, same reasoning, for the ZeTime: one-shot notify-class
    // link, no-ops when nothing is paired, must never mark the WHOOP cycle
    // errored.
    try {
      await ZeTimeLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] zetime sync skipped: $e');
    }
    // Same piggyback, same reasoning: WearFitLink.sync() no-ops when nothing
    // is paired and never throws, so a failure here must not escape and mark
    // the WHOOP cycle as errored either.
    try {
      await WearFitLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] wearfit sync skipped: $e');
    }
    // Same piggyback, same reasoning: RingConnLink.sync() no-ops when nothing
    // is paired and never throws, but this is still the one shared headless
    // entry point, so a failure here must not escape and mark the WHOOP
    // cycle as errored either.
    try {
      await RingConnLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] ringconn sync skipped: $e');
    }
    // Same piggyback, same reasoning: LefunLink.sync() no-ops when nothing is
    // paired and never throws, but this is still the one shared headless
    // entry point, so a failure here must not escape and mark the WHOOP
    // cycle as errored either.
    try {
      await LefunLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] lefun sync skipped: $e');
    }
    // Same piggyback, same reasoning: PineTimeLink.sync() no-ops when
    // nothing is paired and never throws, but the shared entry point must
    // never let it escape and mark the WHOOP cycle as errored.
    try {
      await PineTimeLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] pinetime sync skipped: $e');
    }
    // Same piggyback, same reasoning: QHybridLink.sync() no-ops when nothing
    // is paired and never throws, but this is the one shared headless entry
    // point, so a failure here must not escape either.
    try {
      await QHybridLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] qhybrid sync skipped: $e');
    }
    // Same piggyback, same reasoning: no-ops when unpaired, must never let a
    // failure here mark the WHOOP cycle as errored.
    try {
      await ColmiLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] colmi sync skipped: $e');
    }
    // Same piggyback, same reasoning: CasioLink.sync() already no-ops when
    // nothing is paired and never throws, but a failure here still must not
    // escape and mark the WHOOP cycle as errored.
    try {
      await CasioLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] casio sync skipped: $e');
    }
    // Same piggyback, same reasoning: JyouLink.sync() already no-ops when
    // nothing is paired and never throws, but a failure here still must not
    // escape and mark the WHOOP cycle as errored.
    try {
      await JyouLink.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] jyou sync skipped: $e');
    }
    // Same piggyback, same reasoning: Watch9Link.sync() already no-ops when
    // nothing is paired and never throws, but a failure here still must not
    // escape and mark the WHOOP cycle as errored.
    try {
      await Watch9Link.instance.sync();
    } catch (e) {
      debugPrint('[bgsync] watch9 sync skipped: $e');
    }
    // Same reasoning as the ring above: no-ops when unpaired, must never
    // escape and mark the WHOOP cycle as errored. Unlike Oura's cursor-drain
    // (which completes as soon as its own protocol says so), this pipe has no
    // end-of-history signal (see banglejs_link.dart) — every attempt is a
    // full ~20s connect-and-listen window, run sequentially AFTER the WHOOP
    // drain. The BLE-restore wake (ios_ble_restore.dart) can fire on every
    // WHOOP reconnect, so gate attempts behind a cooldown rather than paying
    // that window on every single wake regardless of how recently we tried.
    // ponytail: fixed cooldown, not adaptive to how often this watch
    // actually has something to say — revisit if real usage shows it's wrong.
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (shouldAttemptBangleJsSync(
          prefs.getInt(_kLastBangleJsAttemptMs), now)) {
        await prefs.setInt(_kLastBangleJsAttemptMs, now);
        await BangleJsLink.instance.sync();
      }
    } catch (e) {
      debugPrint('[bgsync] banglejs sync skipped: $e');
    }
  }
}

// ── staleness escalation (meta-layer over the whole reconnect/sync ladder) ──
// See sync_policy.dart's stalenessTierFor doc. Evaluated at the end of every
// headless cycle (success OR a failed connect attempt — both are meaningful
// signals here), independent of THIS cycle's outcome: it reads the durable
// `rec_ts_hw` cursor, which reflects the full sync history, not just this run.
const String _kLastStalenessNotifiedMs = 'last_staleness_notified_ms';

/// How often a headless wake is allowed to actually attempt a Bangle.js
/// connect-and-listen window (see the call site's doc, further down).
const String _kLastBangleJsAttemptMs = 'last_banglejs_sync_attempt_ms';
const Duration _kBangleJsSyncCooldown = Duration(minutes: 20);

/// True when a headless wake should actually pay for a Bangle.js
/// connect-and-listen window, given the last attempt's stored epoch-ms (or
/// null if never attempted) and now's epoch-ms. Pure so the cooldown math
/// is checkable without standing up the BLE stack.
@visibleForTesting
bool shouldAttemptBangleJsSync(int? lastAttemptMs, int nowMs) =>
    lastAttemptMs == null ||
    nowMs - lastAttemptMs >= _kBangleJsSyncCooldown.inMilliseconds;

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

    final hoursStale = (nowSec - recTsHw) ~/ 3600;
    final shown = await NotificationCenter.instance.emit(
      NotificationEvent(
        // Date-bucketed so a legitimate re-fire after the cooldown isn't
        // blocked by putNotification's INSERT-OR-IGNORE dedupe.
        dedupeKey: '${now.toIso8601String().substring(0, 10)}:sync_stale',
        category: NotifCategory.device,
        // Quiet hours DROP a normal-priority event; nothing queues it for the
        // morning. The 48-hour cooldown below is therefore only spent when the
        // event was actually presented.
        priority: NotifPriority.normal,
        title: "Your band hasn't synced in a while",
        body: 'No new data for about $hoursStale hours. Open OpenStrap to '
            'reconnect — background sync may have stalled.',
        date: now.toIso8601String().substring(0, 10),
        route: '/today',
      ),
      allowPermissionPrompt: allowPermissionPrompt,
    );
    if (!shown) {
      // The gate refused it (quiet hours on an overnight wake is the common
      // case). Burning the cooldown here silenced the backstop for another 48
      // hours over a notification nobody ever saw.
      debugPrint('[bgsync] staleness notification dropped by the gate.');
      return;
    }
    await prefs.setInt(_kLastStalenessNotifiedMs, now.millisecondsSinceEpoch);
    debugPrint(
      '[bgsync] staleness notification fired (hours_stale=$hoursStale).',
    );
  } catch (e) {
    debugPrint('[bgsync] staleness check skipped: $e');
  }
}
