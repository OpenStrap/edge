// device_alerts.dart — turns the band's battery/charging state into OS alerts.
//
// Fed the latest DeviceState on every BLE update (AppState._onEngineState), but
// it is EDGE-TRIGGERED and de-duped, so it fires at most once per real event —
// never on every tick:
//   • Low battery (below the user's threshold — default 15% — not charging):
//     once per drain. Re-arms only after the battery recovers past
//     threshold+10 (hysteresis) or goes back on the charger.
//   • Charging started: once per plug-in, gated by [ChargeAlertPolicy].
//
// THE EDGE STATE IS PERSISTED (issue #179). It used to live only in RAM, which
// is wrong on Android specifically: EdgeApplication pre-warms a Dart engine on
// every process create, and KeepAliveWorker + the START_STICKY foreground
// service mean the process is recreated routinely. Each restart reset
// `_wasCharging` to null and re-armed the low-battery hysteresis, so the next
// replayed chargingOn from the strap's flash backlog buzzed all over again —
// the "repeated 'band is on the charger'" report. Anything that must fire "once
// per real event" cannot key off in-memory state alone here.
//
// Presentation goes through NotificationCenter — the single emitter — NOT
// straight to the plugin. It used to call NotificationService.showDevice, which
// wrote to the plugin directly and so consulted neither the user's quiet hours
// nor their category switch: putting the strap on the charger at 23:30 buzzed
// the phone at Importance.high. It also passed no payload, so the tap did
// nothing. Both are properties of the shared gate, which is why the fix is to
// use it rather than to re-implement it here.
//
// These two alerts keep FIXED OS ids (see NotificationEvent.osId) because this
// file also has to CANCEL the "Charging" card when the puck comes off.

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/day_label.dart';
import 'charge_alert_policy.dart';
import 'notification_center.dart';
import 'notification_event.dart';
import 'notification_prefs.dart';
import 'notification_service.dart';
import 'tap_router.dart';

/// Narrow presentation seam. [NotificationCenter] is a singleton and
/// [NotificationService] has a private constructor, so the alert logic would
/// otherwise only be exercisable against the real platform plugin.
abstract class DeviceAlertSink {
  /// True only if the alert was actually presented. False means the shared
  /// gate dropped it (quiet hours, category off, no permission) — it is NOT
  /// queued for later, so a caller holding a once-per-drain latch must not
  /// spend that latch on a false.
  Future<bool> show(NotificationEvent e);
  Future<void> cancel(int id);
}

class _NotificationCenterSink implements DeviceAlertSink {
  const _NotificationCenterSink();

  @override
  Future<bool> show(NotificationEvent e) {
    // Band alerts fire from the BLE state pipeline, which runs headless on both
    // platforms — never prompt for permission from there.
    return NotificationCenter.instance.emit(e, allowPermissionPrompt: false);
  }

  @override
  Future<void> cancel(int id) => NotificationService.instance.cancel(id);
}

/// Narrow persistence seam for the alert edge state (see the header note on why
/// it must outlive the process).
abstract class DeviceAlertStore {
  Future<int?> readInt(String key);
  Future<void> writeInt(String key, int value);
}

class _PrefsDeviceAlertStore implements DeviceAlertStore {
  const _PrefsDeviceAlertStore();

  @override
  Future<int?> readInt(String key) async {
    try {
      return (await SharedPreferences.getInstance()).getInt(key);
    } catch (_) {
      return null; // a notification must never take down the state update
    }
  }

  @override
  Future<void> writeInt(String key, int value) async {
    try {
      await (await SharedPreferences.getInstance()).setInt(key, value);
    } catch (_) {}
  }
}

class DeviceAlerts {
  /// The default low-battery threshold. The live value is the user's
  /// [NotificationPrefs.batteryAlertPct], read back from the persisted store
  /// in [_restore] (same key the settings screen writes) — this constant is
  /// only what a store with nothing in it degrades to.
  static const int _defaultLowPct = NotificationPrefs.batteryPctDefault;

  /// How far above the threshold the battery must climb before a low alert
  /// re-arms (hysteresis so we don't re-fire around the threshold).
  static const int _rearmGapPct = 10;

  static const String _kLastChargeTs = 'device_alerts.last_charge_event_ts';
  static const String _kLastChargeWall = 'device_alerts.last_charge_wall_sec';

  /// Local day (yyyymmdd) a Charging card was last SHOWN. Charging was the
  /// loudest alert by volume, so it is shown at most once per local day; a
  /// later session that day is still tracked (identity, cooldown), just not
  /// shown.
  static const String _kChargeShownDay = 'device_alerts.charge_shown_day';

  /// Note the asymmetry if the store is ever unavailable: the charging alert
  /// still has the recency window as a second line of defence, but a battery
  /// percentage carries no timestamp, so low-battery has only this key. With a
  /// dead store it degrades to the pre-#179 behaviour (re-armed per process),
  /// which is the right way to fail — there is no way to remember a latch
  /// without somewhere to remember it.
  static const String _kLowArmed = 'device_alerts.low_armed';

  @visibleForTesting
  static const String debugLastChargeTsKey = _kLastChargeTs;
  @visibleForTesting
  static const String debugLastChargeWallKey = _kLastChargeWall;
  @visibleForTesting
  static const String debugChargeShownDayKey = _kChargeShownDay;
  int? _chargeShownDay;

  static int _localDay(int sec) {
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    return d.year * 10000 + d.month * 100 + d.day;
  }

  bool _lowArmed = true; // may we raise a low-battery alert?
  bool? _wasCharging; // previous charging state (null = not seen yet)
  bool _cancelledForOff = false; // already cleared the card for this off-state
  int? _lastAnnouncedEventTs; // strap ts of the last announced charge session
  int? _lastAnnouncedWallSec; // wall time of that announcement

  /// The live low-battery threshold, in percent. Set in [_restore] from the
  /// user's pref (NotificationPrefs.batteryPctPrefKey); until that read lands,
  /// [_defaultLowPct]. An int from prefs, held as double because the battery
  /// percentage arriving off the strap is one.
  double _lowPct = _defaultLowPct.toDouble();

  final DeviceAlertSink _notes;
  final DeviceAlertStore _store;

  /// Guards the restore so a burst of BLE updates arriving before the first
  /// read completes can't each decide independently to announce. Every entry
  /// into [onDeviceState]'s async body awaits it.
  Future<void>? _restored;

  /// Serializes the async bodies. Without it, two updates in the same event-loop
  /// turn both pass the checks before either has written back its state — which
  /// is exactly the double-notification this file exists to prevent, just at a
  /// smaller time scale.
  Future<void> _queue = Future<void>.value();

  DeviceAlerts({DeviceAlertSink? sink, DeviceAlertStore? store})
      : _notes = sink ?? const _NotificationCenterSink(),
        _store = store ?? const _PrefsDeviceAlertStore();

  /// Completes when all queued alert work has settled. Tests only.
  @visibleForTesting
  Future<void> get settled => _queue;

  /// Never completes with an error. [_restored] is memoised, so a failed restore
  /// would otherwise be re-awaited — and re-thrown — by every later update,
  /// silently killing ALL alerts for the life of the process. Falling back to
  /// defaults costs at most one duplicate announcement.
  Future<void> _restore() async {
    try {
      final eventTs = await _store.readInt(_kLastChargeTs);
      final wallSec = await _store.readInt(_kLastChargeWall);
      final armed = await _store.readInt(_kLowArmed);
      _chargeShownDay = await _store.readInt(_kChargeShownDay);
      // Assigned together so the identity pair is never half-applied by a read
      // that throws part-way. (With the read order above the dangerous
      // half — wall set, event ts null, which would disable the identity check
      // — is already unreachable; keeping the invariant local means it stays
      // unreachable if someone reorders the reads.)
      // 0 is the "cleared" sentinel written by an untimed announcement.
      _lastAnnouncedEventTs = (eventTs != null && eventTs > 0) ? eventTs : null;
      _lastAnnouncedWallSec = wallSec;
      if (armed != null) _lowArmed = armed != 0;
      // The user's threshold. Same key NotificationPrefs writes; clamped to
      // the same bounds, so a hand-edited or stale value can't push the alert
      // out of its sane range.
      final pct = await _store.readInt(NotificationPrefs.batteryPctPrefKey);
      if (pct != null) {
        _lowPct = pct
            .clamp(NotificationPrefs.batteryPctMin, NotificationPrefs.batteryPctMax)
            .toDouble();
      }
    } catch (_) {
      _lastAnnouncedEventTs = null;
      _lastAnnouncedWallSec = null;
    }
  }

  /// Re-read the user's threshold from the persisted store. Called when
  /// NotificationPrefs change (the settings screen saves first) — [_restore]
  /// is memoised, so without this a threshold change would not apply until
  /// the next process create. Rides the same serialized queue as
  /// [onDeviceState] so the mutation can't interleave an in-flight decision.
  void refreshThreshold() {
    _queue = _queue.then((_) async {
      final pct = await _store.readInt(NotificationPrefs.batteryPctPrefKey);
      if (pct != null) {
        _lowPct = pct
            .clamp(
                NotificationPrefs.batteryPctMin, NotificationPrefs.batteryPctMax)
            .toDouble();
      }
    }).catchError((_) {
      // A stale threshold for one drain beats breaking the state pipeline.
    });
  }

  /// Call with the latest device state. Cheap and safe to call on every update.
  ///
  /// [chargingTs] is the strap timestamp of the event that last set [charging]
  /// (see DeviceState.chargingTs) — the signal that separates a live plug-in
  /// from a replayed one.
  void onDeviceState({double? batteryPct, bool? charging, int? chargingTs}) {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _queue = _queue.then((_) async {
      _restored ??= _restore();
      await _restored;
      await _apply(
        batteryPct: batteryPct,
        charging: charging,
        chargingTs: chargingTs,
        nowSec: nowSec,
      );
    }).catchError((_) {
      // An alert is a nicety; it must never break the state pipeline, and a
      // throw must not poison the queue for every later update.
    });
  }

  Future<void> _apply({
    required double? batteryPct,
    required bool? charging,
    required int? chargingTs,
    required int nowSec,
  }) async {
    // ── DECIDE ────────────────────────────────────────────────────────────────
    // Every latch is committed BEFORE the first await. AGENTS.md §4.3 ("sticky
    // boolean latches never reset on the failure path") is the exact hazard: a
    // flag written after an await is a flag a throwing sink or store leaves
    // un-written, and onDeviceState's catchError makes that silent — the alert
    // then re-fires on the very next update, which is the bug this file exists
    // to prevent. Nothing below reads the results of the I/O, so deciding first
    // costs nothing.

    // Charger removed → clear the "Charging" card. It is a STATE claim, so
    // leaving it in the tray after the puck comes off is wrong on its own; it
    // also re-arms `onlyAlertOnce`, which only suppresses re-alerting while a
    // notification with that id is still showing.
    //
    // A STALE chargingOff must not clear it: the strap replays old events, so a
    // chargingOff from a previous session can arrive while the band is genuinely
    // on the charger right now, and cancelling then would hide a card that is
    // telling the truth.
    //
    // The "already cancelled" latch is separate from [_wasCharging] on purpose.
    // Keying the cancel off the charging TRANSITION looks equivalent and isn't:
    // a stale chargingOff still has to update _wasCharging (it is the latest
    // known state), which consumes the transition, and the real removal that
    // follows would then find nothing to act on and leave the card stranded.
    final cancelChargingCard = charging == false &&
        !_cancelledForOff &&
        !ChargeAlertPolicy.isStale(chargingTs, wallNowSec: nowSec);
    if (cancelChargingCard) _cancelledForOff = true;
    // Any chargingOn — even one too stale to announce — means a card may exist
    // again, so the next removal must be free to clear it.
    if (charging == true) _cancelledForOff = false;

    final announce = charging == true &&
        ChargeAlertPolicy.evaluate(
              eventTsEpoch: chargingTs,
              wallNowSec: nowSec,
              wasCharging: _wasCharging,
              lastAnnouncedEventTs: _lastAnnouncedEventTs,
              lastAnnouncedWallSec: _lastAnnouncedWallSec,
            ) ==
            ChargeAlertVerdict.announce;

    int? persistEventTs;
    if (announce) {
      _lastAnnouncedWallSec = nowSec;
      if (ChargeAlertPolicy.timestampUsable(chargingTs, wallNowSec: nowSec)) {
        _lastAnnouncedEventTs = chargingTs;
        persistEventTs = chargingTs;
      } else {
        // Announced without a usable clock, so we have no identity for THIS
        // session. Leaving the previous high-water in place would let it judge a
        // session it knows nothing about: the next usable timestamp that happens
        // to fall at or below it gets suppressed, and the user silently loses a
        // real "on the charger" confirmation. Clear it (0 = none; every real
        // strap timestamp is far above it) so only the wall-clock cooldown
        // guards this path — which is exactly what the untimed branch of
        // ChargeAlertPolicy assumes.
        _lastAnnouncedEventTs = null;
        persistEventTs = 0;
      }
    }
    // Tracks the LATEST KNOWN charging state, including from events too stale to
    // announce — otherwise a stale on/off pair would leave us believing we are
    // still charging and swallow the next genuine plug-in as `alreadyCharging`.
    if (charging != null) _wasCharging = charging;

    // Low-battery hysteresis, same precedence as before: a real plug-in re-arms
    // the next drain, so does a battery that recovered past the ceiling.
    final rearmPct = _lowPct + _rearmGapPct;
    var lowArmed = _lowArmed;
    if (announce) lowArmed = true;
    if (batteryPct != null && batteryPct >= rearmPct) lowArmed = true;
    final fireLow = batteryPct != null &&
        charging != true &&
        batteryPct < _lowPct &&
        lowArmed;
    if (fireLow) lowArmed = false;
    final armedBefore = _lowArmed;
    _lowArmed = lowArmed;

    // ── ACT ───────────────────────────────────────────────────────────────────
    // Each step is isolated, because presentation and persistence must not be
    // able to take each other down. Sequencing them plainly forces a choice
    // between two bad failure modes: show-then-persist means a throwing plugin
    // skips the write, so the session re-announces after a restart; persist-
    // then-show means a throwing store swallows the alert entirely. Neither is
    // acceptable, and neither step reads the other's result — so all of them are
    // attempted independently.
    if (cancelChargingCard) {
      await _io(() => _notes.cancel(NotificationService.idCharging));
    }
    final today = _localDay(nowSec);
    final showCharging = announce && _chargeShownDay != today;
    final shownBefore = _chargeShownDay;
    if (showCharging) _chargeShownDay = today;
    if (announce) {
      if (showCharging) {
        // A card the shared gate dropped (quiet hours, category off) does not
        // spend today's one: put the latch back. A throw keeps it, since
        // whether a card appeared is then unknown.
        final dropped = await _showWasDropped(() => _notes.show(_event(
            osId: NotificationService.idCharging,
            // The strap event's own timestamp IS the identity of this charge
            // session (that is what ChargeAlertPolicy arbitrates on), so a
            // genuine second plug-in the same day is a genuinely new key while
            // a re-announcement of the same one is not. Date-prefixed so
            // FiredKeyStore's retention sweep can reach it.
            kind: 'band_charging:${chargingTs ?? nowSec}',
            title: 'Charging',
          )));
        if (dropped) {
          _chargeShownDay = shownBefore;
        } else {
          await _io(() => _store.writeInt(_kChargeShownDay, today));
        }
      }
      await _io(() => _store.writeInt(_kLastChargeWall, nowSec));
      if (persistEventTs != null) {
        await _io(() => _store.writeInt(_kLastChargeTs, persistEventTs!));
      }
      // A real plug-in clears any stale low alert.
      await _io(() => _notes.cancel(NotificationService.idLowBattery));
    }
    if (fireLow) {
      final dropped = await _showWasDropped(() => _notes.show(_event(
            osId: NotificationService.idLowBattery,
            // One drain per key: the hysteresis above already means a re-arm
            // needs the battery to climb past 25% or go on the charger, so the
            // percentage is a stable identity for THIS drain.
            kind: 'band_low:${batteryPct.round()}',
            title: 'Low battery',
            body: 'Your band is at ${batteryPct.round()}%. Charge it soon.',
          )));
      if (dropped) {
        // The shared gate refused it — quiet hours, the device category off, no
        // OS permission. `emit` DROPS; it does not defer, so nothing will ever
        // present this alert later. Spending the once-per-drain latch on it
        // means the user is never told the band is flat for the rest of this
        // drain (re-arming needs 25% or a charger), so put the latch back and
        // let the next state update try again.
        lowArmed = true;
        _lowArmed = true;
      }
    }
    if (lowArmed != armedBefore) {
      await _io(() => _store.writeInt(_kLowArmed, lowArmed ? 1 : 0));
    }
  }

  /// One band alert, in the currency the shared emitter speaks.
  ///
  /// `route: '/profile'` — the band's battery, charge state and last-sync time
  /// live on the source detail screen under Profile, which is the only place in
  /// the app that can answer "how flat is it?".
  static NotificationEvent _event({
    required int osId,
    required String kind,
    required String title,
    String body = '',
  }) {
    final day = todayLabel();
    return NotificationEvent(
      dedupeKey: '$day:$kind',
      category: NotifCategory.device,
      // Normal priority is subject to quiet hours, and quiet hours DROP —
      // there is no queue and no deferral anywhere in NotificationCenter. The
      // fireLow path re-arms its latch on a drop for exactly that reason.
      priority: NotifPriority.normal,
      title: title,
      body: body,
      date: day,
      route: kRouteProfile,
      osId: osId,
    );
  }

  /// Run one presentation/persistence step, absorbing its failure. See the ACT
  /// block above for why these are isolated rather than sequenced.
  Future<void> _io(Future<void> Function() step) async {
    try {
      await step();
    } catch (_) {}
  }

  /// Present one alert; true when the shared gate DROPPED it (never shown,
  /// never queued) so a latch must not be spent on it.
  ///
  /// A THROWING sink deliberately reports false — "spend the latch". That is
  /// the failure AGENTS.md §4.3 is about: we cannot know what the plugin did,
  /// and re-firing on every BLE state update is worse than one lost alert. A
  /// sink that returns false told us plainly that nothing was shown, which is
  /// a different fact and gets the opposite answer.
  Future<bool> _showWasDropped(Future<bool> Function() step) async {
    try {
      return !await step();
    } catch (_) {
      return false;
    }
  }
}
