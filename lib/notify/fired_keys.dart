// fired_keys.dart — the persistent "already fired this key" record.
//
// A NotificationEvent's dedupeKey (by convention "$date:$kind") promises the
// event fires at most once. The OS notification id alone does NOT enforce this:
// re-showing the same id only REPLACES the prior post in the shade — it still
// re-alerts (sound/buzz). Since derivation re-runs on every BLE sync, an insight
// whose condition holds all day (e.g. today's irregular-rhythm flag) would fire
// over and over (issue #136). This store makes emit() honour the promise: a key
// that has already fired is skipped until a *new* key comes along.
//
// Reset is automatic: keys are date-prefixed, so tomorrow's "2026-07-24:irregular"
// is a fresh key that fires once. No manual clearing is needed. The store is a
// bounded FIFO of the most-recent [maxKeys] fired keys — format-agnostic and
// safe: since a single day only ever mints a handful of distinct keys, the cap
// is far larger than any one day's worth, so a same-day key can never be evicted
// and re-fire.

import 'package:shared_preferences/shared_preferences.dart';

class FiredKeyStore {
  const FiredKeyStore();

  static const String _prefsKey = 'notif_fired_keys';

  /// How many most-recent fired keys to retain. Generous: a day mints only a
  /// handful of distinct insight keys, so this spans many days — a same-day key
  /// is never evicted (which would let it re-fire).
  static const int maxKeys = 200;

  /// Whether [dedupeKey] has already fired an OS notification.
  Future<bool> hasFired(String dedupeKey) async {
    final p = await SharedPreferences.getInstance();
    final keys = p.getStringList(_prefsKey);
    return keys != null && keys.contains(dedupeKey);
  }

  /// Record [dedupeKey] as fired. Bounded FIFO: the newest key is appended and
  /// the oldest evicted once past [maxKeys]. A key already present is left
  /// untouched — a repeated hit must NOT re-fire and must NOT refresh its
  /// recency (otherwise a hot duplicate could keep a stale key pinned forever).
  Future<void> recordFired(String dedupeKey) async {
    final p = await SharedPreferences.getInstance();
    final keys = List<String>.of(p.getStringList(_prefsKey) ?? const <String>[]);
    if (keys.contains(dedupeKey)) return;
    keys.add(dedupeKey);
    if (keys.length > maxKeys) {
      keys.removeRange(0, keys.length - maxKeys);
    }
    await p.setStringList(_prefsKey, keys);
  }
}
