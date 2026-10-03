// PURE POLICY — when the rolling per-user sleep profile may be folded, and when
// it is allowed to influence staging.
//
// Background. `cardioStager` (analytics) can blend a persisted per-user profile
// (`baselines` key `sleep_user_profile`) into tonight's per-night-local
// baselines, bounded by `SleepUserProfile.personalWeight` (0 → 0.5 as nights
// accumulate). The profile is produced by EWMA-folding one observation per
// night, once the data has run past that day ([nightOver]).
//
// Two defects made that layer harmful in the field, and this policy exists to
// prevent both:
//
//  1. NOT IDEMPOTENT. The fold ran on every staging pass for a day — algo
//     bumps, BLE-drain re-derives, backfill sweeps — not once per day. A real
//     user export carried `nights: 1348` against 12 days of data. Because
//     `personalWeight` saturates at 28 nights, that pins the blend at its 0.5
//     cap immediately, and the EWMA (alpha ~2/15) collapses onto whichever day
//     was re-derived last instead of a representative fortnight. Replaying the
//     corrupt profile over the same 11 nights moved wake 4.3% → 36.4% and deep
//     1.9% → 0.0% on the worst night: the personalization layer was
//     re-manufacturing the very wake over-call cardio_stager.dart was written
//     to eliminate. Fold at most ONCE per day_id.
//
//  2. NO WARM-UP. Personalization was applied from the first night. The one
//     direct trial of per-subject personalization for wrist-PPG staging (van
//     der Aar et al. 2025, Physiol Meas, n=59, fine-tuned per subject and
//     scored against PSG) found performance improved in 82.5% of subjects and
//     that significant gains required >= 3 nights — which also means ~17.5%
//     got WORSE. A one- or two-night profile is therefore pure downside. Below
//     the floor we stay on per-night-local baselines, the cold-start path
//     cardio_stager.dart was actually validated on.
//
// A profile written before fold tracking existed carries no [foldedDaysKey].
// Its `nights` is untrustworthy and there is no record of which days went in,
// so it CANNOT be repaired — [usableProfileJson] discards it and lets the
// profile rebuild honestly.

import 'dart:convert';

class SleepProfilePolicy {
  /// Minimum folded nights before the profile may influence staging.
  static const int minNightsForBlend = 3;

  /// Key inside the profile payload holding the day_ids already folded in.
  /// Its ABSENCE marks a pre-tracking (legacy) payload.
  static const String foldedDaysKey = 'folded_days';

  /// Cap on tracked day_ids so the `baselines` row cannot grow unbounded.
  static const int maxFoldedDays = 400;

  const SleepProfilePolicy._();

  /// Day_ids already folded into [payloadJson]. Empty for absent, corrupt, or
  /// legacy payloads — a legacy payload is being discarded anyway, so treating
  /// its (unknown) history as empty is the consistent answer.
  static Set<String> foldedDays(String? payloadJson) {
    final m = _decode(payloadJson);
    final days = m?[foldedDaysKey];
    if (days is! List) return const <String>{};
    return {for (final d in days) if (d is String) d};
  }

  /// True when [payloadJson] predates fold tracking and must be discarded.
  /// A null/corrupt payload is NOT "legacy" — there is simply nothing to
  /// discard, and callers already treat it as a cold start.
  static bool isLegacy(String? payloadJson) {
    final m = _decode(payloadJson);
    if (m == null) return false;
    return m[foldedDaysKey] is! List;
  }

  /// The payload to hand the staging worker, or null for a cold start.
  /// Corrupt and legacy payloads both collapse to null.
  static String? usableProfileJson(String? payloadJson) {
    final m = _decode(payloadJson);
    if (m == null) return null;
    if (m[foldedDaysKey] is! List) return null; // legacy ⇒ rebuild
    return payloadJson;
  }

  /// Whether tonight's observation may be folded into the profile.
  /// Overrides (manual / user-confirmed windows) never fold: the window is
  /// asserted by the human, so its baselines are not evidence about the
  /// sleeper's typical autonomic signature.
  static bool shouldFold({
    required Set<String> alreadyFolded,
    required String dayId,
    required bool hasOverride,
  }) =>
      !hasOverride && !alreadyFolded.contains(dayId);

  /// Whether the data has run past the day's window ([dayEndSec], the last
  /// second of the day), so its night is over and complete. Before that a
  /// pass stages the night only up to the data edge, and folding that
  /// fragment would use up the day's one fold.
  static bool nightOver({required int? dataEdgeSec, required int dayEndSec}) =>
      dataEdgeSec != null && dataEdgeSec > dayEndSec;

  /// Whether a profile with [nights] folded nights may influence staging.
  static bool shouldBlend(int? nights) =>
      nights != null && nights >= minNightsForBlend;

  /// [alreadyFolded] + [dayId], sorted and capped. The cap evicts the OLDEST
  /// entries: re-folding a day that has aged out is far less harmful than an
  /// unbounded row, and at a ~14-night EWMA horizon an ancient re-fold is
  /// nearly a no-op.
  ///
  /// PRECONDITION: [dayId] is a `YYYY-MM-DD` local day label (what
  /// `day_label.dart` produces, and the only thing derivation passes). The cap
  /// leans on that: eviction is by LEXICOGRAPHIC order, which equals
  /// chronological order only for zero-padded ISO dates. Feed this an epoch
  /// string or a UUID and the sort no longer means "age", so a RECENT day could
  /// be evicted while an older one is kept — and an evicted day passes
  /// [shouldFold] again, i.e. the double-fold this class exists to prevent.
  /// Asserted rather than silently sorted differently, because the failure is
  /// invisible in the payload.
  static List<String> appendFoldedDay(
      Set<String> alreadyFolded, String dayId) {
    assert(_isDayLabel(dayId),
        'folded day_ids must be YYYY-MM-DD (eviction sorts on them); got "$dayId"');
    final out = (<String>{...alreadyFolded, dayId}).toList()..sort();
    if (out.length > maxFoldedDays) {
      out.removeRange(0, out.length - maxFoldedDays);
    }
    return out;
  }

  static final RegExp _dayLabel = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  static bool _isDayLabel(String s) => _dayLabel.hasMatch(s);

  /// Stamp the folded-day set into a profile map produced by
  /// `SleepUserProfile.toJson()` (which does not know about this key).
  static Map<String, dynamic> withFoldedDays(
    Map<String, dynamic> profileMap,
    Set<String> alreadyFolded,
    String dayId,
  ) =>
      {
        ...profileMap,
        foldedDaysKey: appendFoldedDay(alreadyFolded, dayId),
      };

  // NO DART-LEVEL LOCK HERE, DELIBERATELY.
  //
  // An earlier revision serialised the fold with a `static Future` mutex. That
  // is not sufficient and is worse than nothing, because it looks sufficient:
  // derivation runs in more than one isolate (Android headless sync wakes
  // construct their own DerivationEngine in a background isolate), and a Dart
  // static has one copy PER ISOLATE. A
  // background heavy pass and a foreground sweep would each hold "the" lock and
  // still clobber each other.
  //
  // The read-modify-write is instead done inside one exclusive SQLite
  // transaction — see `LocalDb.updateBaseline` and
  // `DerivationEngine._foldObservationIntoProfile`. SQLite's write lock is
  // cross-connection, so it holds across isolates AND across processes.
  //
  // Callers must re-read the payload and re-check [shouldFold] INSIDE that
  // transaction; any value read before the staging isolate ran is stale by
  // definition.

  static Map<String, dynamic>? _decode(String? payloadJson) {
    if (payloadJson == null || payloadJson.isEmpty) return null;
    try {
      final d = jsonDecode(payloadJson);
      return d is Map ? d.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }
}
