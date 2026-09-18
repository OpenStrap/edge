// notification_ids.dart — collision-free OS notification id ALLOCATION.
//
// The id handed to `FlutterLocalNotificationsPlugin.show` decides which post a
// notification lands on: the SAME id REPLACES the notification already in the
// shade, it does not stack beside it. Ids used to be DERIVED from the dedupeKey
// as `categoryBase + dedupeKey.hashCode.abs() % 100000` — a hash modulo, so two
// DIFFERENT dedupeKeys in the same category whose hashes agree mod 100000 map
// onto the same id and one of the two notifications silently vanishes with no
// trace. The old comment ("partitioned so a health alert can never overwrite a
// reminder") only ever covered CROSS-category collisions; within a category the
// scheme guaranteed nothing.
//
// Ids are now ALLOCATED instead: each dedupeKey takes the next free slot in its
// category's band. The allocation itself goes through `LocalDb.claimNotifSlot`
// — one SQLite `INSERT OR IGNORE` against a UNIQUE(category, slot) index,
// exactly the primitive `FiredKeyStore`/`claimNotifFired` uses for the
// fire-once guard — because a plain SharedPreferences read-then-write has no
// atomicity across isolates: the foreground app isolate and a headless
// BLE/BGTask derive isolate can both read the same free slot before either
// writes it back, and both then compute the same OS notification id (see
// derivation_engine.dart's plain/escalated same-day dedupeKey pair for a real
// case where two isolates can race to FIRST-allocate two different keys in
// the same category band). The DB claim closes that window; SharedPreferences
// is kept only as a mirror (for the in-memory memo / prune bookkeeping below)
// and as the degraded-mode fallback when no DB is available.
//
// RETENTION. Allocations are pruned on the same schedule as FiredKeyStore's
// fire-once claims: a date-prefixed dedupeKey older than [retentionDays] can no
// longer be re-posted, so its slot is freed. Undated keys (e.g.
// "alarm_fired:<epoch>") are rare and left alone.
//
// DEGRADED MODE. With no usable shared_preferences (a plain unit test, a torn
// down background isolate) the in-memory maps below are the whole store: ids
// stay collision-free for the life of the process, they just aren't stable
// across a restart. That is strictly better than the hash it replaces.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/day_label.dart';
import '../data/db.dart';
import 'fired_keys.dart';
import 'notification_event.dart';

class NotificationIds {
  NotificationIds._();
  static final NotificationIds instance = NotificationIds._();

  /// Slots per category band. Bands are disjoint and start at [bandBaseFor].
  static const int bandSize = 100000;

  /// How long a dated allocation is kept before its slot is recycled. Matches
  /// [FiredKeyStore.retentionDays] — a key that can no longer fire can no
  /// longer need its id either.
  static const int retentionDays = FiredKeyStore.retentionDays;

  /// How far to probe forward for a free slot before giving up and reusing the
  /// counter position. Only reachable with [bandSize] live keys in ONE category
  /// (i.e. never, given the prune pass above).
  static const int maxProbes = 1024;

  static const String _kSlot = 'notif_osid:'; // "<cat>:<dedupeKey>" → slot
  static const String _kOwner = 'notif_osslot:'; // "<cat>:<slot>"    → dedupeKey
  static const String _kNext = 'notif_osnext:'; // "<cat>"            → next slot

  /// The low edge of each category's id band. Kept 100k apart and well above
  /// the fixed device/scheduled-reminder ids (< 3000) in NotificationService.
  static int bandBaseFor(NotifCategory c) => switch (c) {
        NotifCategory.device => 100000,
        NotifCategory.recovery => 200000,
        NotifCategory.health => 300000,
        NotifCategory.reminders => 400000,
      };

  // In-memory mirror of the three prefs namespaces. Also the ONLY store when
  // shared_preferences is unavailable (see DEGRADED MODE above).
  final Map<String, int> _slots = {};
  final Map<String, String> _owners = {};
  final Map<String, int> _next = {};

  /// Drop every in-memory allocation. Tests only — a fresh process starts with
  /// empty maps and re-reads the persisted ones.
  @visibleForTesting
  void resetForTest() {
    _slots.clear();
    _owners.clear();
    _next.clear();
  }

  /// The stable OS notification id for [e]. Same dedupeKey → same id (replace
  /// in place); two different dedupeKeys in the same category → NEVER the same
  /// id. Never throws.
  Future<int> idFor(NotificationEvent e) async {
    final base = bandBaseFor(e.category);
    try {
      return base + await _slotFor(e);
    } catch (_) {
      // Absolute last resort: keep the category band correct rather than
      // failing the present outright.
      return base;
    }
  }

  Future<int> _slotFor(NotificationEvent e) async {
    final cat = e.category.name;
    final slotKey = '$_kSlot$cat:${e.dedupeKey}';

    final memo = _slots[slotKey];
    if (memo != null) return memo;

    SharedPreferences? p;
    try {
      p = await SharedPreferences.getInstance();
    } catch (_) {
      p = null; // no platform prefs — the in-memory maps carry the process
    }
    if (p != null) {
      try {
        await p.reload(); // the OTHER isolate may have allocated since
      } catch (_) {/* freshness is best-effort */}
      final existing = p.getInt(slotKey);
      if (existing != null) {
        _slots[slotKey] = existing;
        return existing;
      }
    }

    final nextKey = '$_kNext$cat';
    final start = p?.getInt(nextKey) ?? _next[nextKey] ?? 0;

    // Preferred path: one atomic DB claim (INSERT OR IGNORE against a
    // UNIQUE(category, slot) index), the same primitive claimNotifFired uses
    // for the fire-once guard. This is what actually closes the cross-isolate
    // race described in the file header — `start` above is only a probe hint,
    // the UNIQUE index is what makes the claim correct even if the hint is
    // stale. Falls through to the SharedPreferences probe below on any
    // failure (no DB in this process — a plain unit test, a torn-down
    // background isolate — or the DB throwing).
    try {
      final slot = await LocalDb.claimNotifSlot(
        cat,
        e.dedupeKey,
        startAt: start,
        bandSize: bandSize,
        maxProbes: maxProbes,
      );
      _slots[slotKey] = slot;
      if (p != null) {
        try {
          await p.setInt(slotKey, slot);
          await p.setInt(nextKey, (slot + 1) % bandSize);
        } catch (_) {/* mirror is best-effort; the DB is the source of truth */}
      }
      return slot;
    } catch (_) {/* degrade to the SharedPreferences scheme below */}

    var slot = start % bandSize;
    for (var i = 0; i < maxProbes; i++) {
      final candidate = (start + i) % bandSize;
      final ownerKey = '$_kOwner$cat:$candidate';
      final owner = p?.getString(ownerKey) ?? _owners[ownerKey];
      if (owner == null || owner == e.dedupeKey) {
        slot = candidate;
        break;
      }
    }

    final ownerKey = '$_kOwner$cat:$slot';
    _slots[slotKey] = slot;
    _owners[ownerKey] = e.dedupeKey;
    _next[nextKey] = (slot + 1) % bandSize;
    if (p != null) {
      try {
        await p.setInt(slotKey, slot);
        await p.setString(ownerKey, e.dedupeKey);
        await p.setInt(nextKey, (slot + 1) % bandSize);
        // Never prune the allocation we just made — an event legitimately
        // carrying an old date (a backfilled day) would otherwise lose its slot
        // the instant it got one.
        await _prune(p, keep: slotKey);
      } catch (_) {/* the in-memory maps still hold the allocation */}
    }
    return slot;
  }

  /// Free the slots of dated allocations older than [retentionDays], in both
  /// directions. Cheap and rare (only after a FRESH allocation).
  Future<void> _prune(SharedPreferences p, {String? keep}) async {
    try {
      final cutoff =
          dayLabelOf(DateTime.now().subtract(const Duration(days: retentionDays)));
      for (final k in p.getKeys().toList(growable: false)) {
        if (!k.startsWith(_kSlot) || k == keep) continue;
        final rest = k.substring(_kSlot.length); // "<cat>:<dedupeKey>"
        final sep = rest.indexOf(':');
        if (sep < 0) continue;
        final cat = rest.substring(0, sep);
        final day = FiredKeyStore.leadingDate(rest.substring(sep + 1));
        if (day == null || day.compareTo(cutoff) >= 0) continue;
        final slot = p.getInt(k);
        await p.remove(k);
        _slots.remove(k);
        if (slot != null) {
          final ownerKey = '$_kOwner$cat:$slot';
          await p.remove(ownerKey);
          _owners.remove(ownerKey);
        }
      }
    } catch (_) {/* bounding is best-effort — never break an allocation on it */}
  }
}
