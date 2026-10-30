// fired_keys.dart — the persistent, cross-isolate "already fired this key" record.
//
// A NotificationEvent's dedupeKey (by convention "$date:$kind") promises the
// event fires at most once. The OS notification id alone does NOT enforce this:
// re-showing the same id only REPLACES the prior post in the shade — it still
// re-alerts (sound/buzz). Since derivation re-runs on every BLE sync, an insight
// whose condition holds all day (e.g. today's low-readiness or irregular-rhythm
// flag) would fire over and over (issue #136). This store makes emit() honour the
// promise: a key that has already fired is skipped until a *new* key comes along.
//
// CROSS-ISOLATE. Derivation ran in TWO isolates when this was written: the
// long-lived foreground pass (kept alive for BLE) and the WorkManager
// background pass (background_derivation.dart, since removed — its tombstone
// explains why). The hardening below stays: the iOS headless/BGTask paths can
// still run emit() from a second isolate, and the failure modes are the same.
// The NotificationCenter lock only orders emits WITHIN one
// isolate; it can't coordinate across them. Three distinct things went wrong
// there, and a same-day key re-fired all day:
//
//   1. Stale read cache. The legacy SharedPreferences instance loads a snapshot
//      once and never re-reads disk. The long-lived foreground isolate loaded
//      prefs before today's key existed, so after the background isolate recorded
//      it, hasFired() still read the stale snapshot as "not fired" → re-alert.
//   2. Lost-update clobber. Keys lived in ONE shared list mutated via
//      read-modify-write (getStringList → add → setStringList). With no
//      cross-process lock, whichever isolate wrote last rewrote the WHOLE list
//      from its own (stale) copy, dropping the other's keys — including a
//      just-recorded one, which then re-fired.
//   3. Check-then-record is not atomic. Even with a fresh read and independent
//      per-key flags, "has it fired?" and "record that it fired" are two separate
//      operations. Both isolates can read false before either writes, and both
//      present. Fresher reads shrink that window; they cannot close it.
//
// (1) and (2) are properties of the storage medium; (3) is a property of the
// PROTOCOL, so the fix is a protocol change: [claim] replaces check-then-record
// with a single atomic operation, backed by SQLite. `INSERT OR IGNORE` against a
// PRIMARY KEY is one statement and writers are serialised, so for a given key
// exactly one caller in the whole process ever wins. That caller — and only it —
// presents. See LocalDb.claimNotifFired.
//
// DEGRADED MODE. If the DB is unusable (not yet open, torn down mid-background
// pass, or absent in a plain unit test), claim falls back to the
// SharedPreferences per-key flags: reload-before-read plus one independent bool
// per key, which still fixes (1) and (2) and leaves only the narrow (3) window.
// The fallback is deliberately NOT "assume already fired" — a broken DB must
// never silently swallow every notification on the device. Every successful
// claim also writes the prefs mirror, so the two stores can't disagree about a
// key that fired while the DB was down.
//
// Reset is automatic: keys are date-prefixed, so tomorrow's "2026-07-27:low_read"
// is a fresh key that fires once. Growth is bounded by the prune pass: dated
// claims older than [retentionDays] are dropped (the dedupe only needs today, so
// a fortnight is ample). Keys without a leading date (e.g. "alarm_fired:<epoch>")
// have no day to expire against and are rare, so they're left alone.

import 'package:shared_preferences/shared_preferences.dart';

import '../data/day_label.dart';
import '../data/db.dart';

class FiredKeyStore {
  const FiredKeyStore();

  /// Per-key flag namespace for the degraded-mode mirror. Each fired dedupeKey
  /// is its own bool at "$_prefix$dedupeKey" — never a shared list (see the
  /// clobber note above).
  static const String _prefix = 'notif_fired:';

  /// The pre-#145 shared list. Read once to carry already-fired keys over, then
  /// deleted. Without this, every key that had already fired on the day of the
  /// upgrade would fire a second time under the new scheme.
  static const String legacyListKey = 'notif_fired_keys';

  /// How long a dated fired flag is retained before the prune pass drops it.
  /// The guard only needs the current day; a fortnight is a generous margin.
  static const int retentionDays = 14;

  /// Atomically claim [dedupeKey] for a one-time fire.
  ///
  /// Returns true iff THIS caller owns the fire and should present. Any other
  /// claimant — a concurrent emit in this isolate, or the other derivation
  /// isolate — gets false. A caller that wins the claim but then fails to
  /// present MUST [release] it, or that key never fires again.
  Future<bool> claim(String dedupeKey) async {
    final p = await _prefs();
    if (p != null) {
      await _reload(p);
      await _migrateLegacyList(p);
    }
    // Scoped tightly to the claim DECISION. Nothing after it may re-enter the
    // degraded branch: once the atomic claim is won, a throw in the bookkeeping
    // below must not be mistaken for "no DB", which would leave the key claimed
    // in the table while we report a fallback claim — firing it twice.
    bool? won;
    try {
      won = await LocalDb.claimNotifFired(dedupeKey);
    } catch (_) {
      won = null; // DEGRADED — no atomic claim available.
    }

    if (won == null) {
      // Fall back to the per-key flags: still fresh cross-isolate reads and
      // clobber-free writes, just without atomicity. Deliberately NOT "assume
      // fired" — an unusable DB must never mute every notification on the
      // device.
      if (p == null) return true; // no store at all — never suppress the alert
      try {
        if (p.getBool('$_prefix$dedupeKey') ?? false) return false;
        await p.setBool('$_prefix$dedupeKey', true);
        await _prunePrefs(p);
      } catch (_) {/* best-effort — better a repeat alert than a silent one */}
      return true;
    }

    if (!won) return false;

    // We own the fire. Everything below is bookkeeping and must never revoke it.
    try {
      if (p != null) {
        // RECONCILE, don't undo. The DB row is fresh, but a fallback claim taken
        // while the DB was down lives only in the prefs mirror — so a mirror
        // that already reads true means this key HAS fired and the row we just
        // inserted is simply the truth arriving late. Keep it and back off.
        //
        // Emphatically NOT release(): that clears the mirror too, and the mirror
        // is the only evidence of the degraded-mode fire. Erasing it leaves both
        // stores reading "not fired", so the NEXT pass would win cleanly and
        // re-alert — reopening this PR's bug in the one path (DB recovered after
        // an outage) these comments call out as expected. Undoing the insert
        // instead of keeping it has the same flaw one pass later, and leaves the
        // claim table permanently ignorant of a fire it should own.
        if (p.getBool('$_prefix$dedupeKey') ?? false) return false;
        await p.setBool('$_prefix$dedupeKey', true);
        // The mirror is written on every fire, so it needs the same prune as
        // the table. Pruning only in degraded mode left one prefs key per fire
        // forever on any device with a working DB, and the whole prefs file is
        // parsed at cold start and on every reload() above.
        await _prunePrefs(p);
      }
      await LocalDb.pruneNotifFired(_cutoffLabel());
    } catch (_) {/* bookkeeping is best-effort — the claim stands */}
    return true;
  }

  /// Give back a claim taken by [claim] when the present did NOT happen
  /// (permission denied, OS error, a throw). Best-effort; never throws.
  Future<void> release(String dedupeKey) async {
    try {
      await LocalDb.releaseNotifFired(dedupeKey);
    } catch (_) {/* degraded mode has no DB row to give back */}
    try {
      final p = await _prefs();
      await p?.remove('$_prefix$dedupeKey');
    } catch (_) {/* mirror is best-effort */}
  }

  /// Whether [dedupeKey] has already fired an OS notification. Read-only — it
  /// does NOT claim, so it must never be used to gate a present (that's [claim];
  /// a check followed by a separate record is exactly the race this store
  /// exists to kill). For diagnostics, tests, and non-presenting callers.
  Future<bool> hasFired(String dedupeKey) async {
    try {
      if (await LocalDb.notifFiredExists(dedupeKey)) return true;
    } catch (_) {/* fall through to the mirror */}
    final p = await _prefs();
    if (p == null) return false;
    // Reload: this isolate's snapshot can be stale relative to a write from the
    // OTHER derivation isolate, and reading stale is what let an already-fired
    // key re-alert across isolates.
    await _reload(p);
    return p.getBool('$_prefix$dedupeKey') ?? false;
  }

  /// Record [dedupeKey] as fired without caring who won. Idempotent. Prefer
  /// [claim] anywhere the result gates a present.
  Future<void> recordFired(String dedupeKey) async => claim(dedupeKey);

  /// The oldest day label a dated claim may carry and still be retained.
  static String _cutoffLabel() =>
      dayLabelOf(DateTime.now().subtract(const Duration(days: retentionDays)));

  static Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null; // no platform prefs (headless test) — DB path still works
    }
  }

  static Future<void> _reload(SharedPreferences p) async {
    try {
      await p.reload();
    } catch (_) {/* reload is best-effort freshness, never fatal */}
  }

  /// Carry the pre-#145 shared list over to the per-key flags and the claim
  /// table exactly once, then delete it. Idempotent: the list's absence IS the
  /// "already migrated" marker, so this costs one cached getStringList per call.
  static Future<void> _migrateLegacyList(SharedPreferences p) async {
    try {
      final legacy = p.getStringList(legacyListKey);
      if (legacy == null) return;
      for (final k in legacy) {
        await p.setBool('$_prefix$k', true);
      }
      try {
        await LocalDb.seedNotifFired(legacy);
      } catch (_) {/* degraded — the prefs mirror above still carries them */}
      await p.remove(legacyListKey);
    } catch (_) {/* migration is best-effort; worst case is one repeat alert */}
  }

  /// Drop dated mirror flags older than [retentionDays]. Best-effort and cheap:
  /// it only runs after a won claim (rare), and a slightly stale view just
  /// prunes a little late. Keys without a leading YYYY-MM-DD are left untouched.
  static Future<void> _prunePrefs(SharedPreferences p) async {
    try {
      final cutoff = _cutoffLabel();
      for (final k in p.getKeys()) {
        if (!k.startsWith(_prefix)) continue;
        final d = leadingDate(k.substring(_prefix.length));
        if (d != null && d.compareTo(cutoff) < 0) await p.remove(k);
      }
    } catch (_) {/* bounding is best-effort — never break a record on it */}
  }

  /// The leading "YYYY-MM-DD" of a dedupeKey, or null if it isn't dated.
  static String? leadingDate(String dedupeKey) {
    if (dedupeKey.length < 10) return null;
    final head = dedupeKey.substring(0, 10);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(head)) return null;
    return head;
  }
}
