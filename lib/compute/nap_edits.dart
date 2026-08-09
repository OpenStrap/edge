// User edits to a day's naps — the pure merge, kept out of the derivation
// engine so the rules are testable without a database or a day of substrate.
//
// Three people asked for this from two directions: "the app tracked sleep when
// I was awake, let me delete it" and "I took a two-hour nap and it wasn't
// counted". Both are the same feature — the detector's answer is a proposal,
// and the person who was actually there gets the last word.
//
// The user's edits are stored SEPARATELY from the detector's output and
// replayed over it on every derivation, rather than being written into the
// result. That matters because the detector improves: a day re-derived under a
// better stager should still respect "there was no nap here", and baking the
// edit into the output would freeze the old detection alongside it.

import 'package:flutter/foundation.dart';

/// What the user did to a nap.
enum NapEditKind {
  /// Added a nap the detector missed.
  added,

  /// Removed one the detector invented. Stored as a window rather than an id,
  /// because the detector's ids are not stable across a re-derivation — the
  /// bounds are the only thing that survives a re-run.
  rejected,
}

@immutable
class NapEdit {
  const NapEdit({
    required this.kind,
    required this.startSec,
    required this.endSec,
  });

  final NapEditKind kind;
  final int startSec;
  final int endSec;

  int get durationSec => endSec - startSec;

  bool overlaps(int otherStart, int otherEnd) =>
      startSec < otherEnd && otherStart < endSec;
}

/// A nap in the day bundle: `start`, `end`, `duration_min`, and friends.
typedef NapMap = Map<String, dynamic>;

/// Minimum length of a nap someone can log. Below this it is not a nap, and a
/// scatter of two-minute entries would swamp the real ones in every total.
const int kMinManualNapSec = 5 * 60;

/// Maximum. Anything longer is a sleep, not a nap, and belongs in the main
/// sleep window where the stager can actually say something about its stages.
const int kMaxManualNapSec = 6 * 60 * 60;

/// Whether a window can be logged as a nap.
bool manualNapWindowIsValid(int startSec, int endSec) {
  final d = endSec - startSec;
  return d >= kMinManualNapSec && d <= kMaxManualNapSec;
}

/// Apply [edits] to the detector's [detected] naps.
///
/// A rejected window removes every detected nap it OVERLAPS, not only one that
/// matches it exactly — the detector's bounds shift between runs, and an edit
/// that stopped applying the moment a boundary moved by a minute would be
/// worse than useless.
///
/// Added naps are appended and marked, so the UI can show which came from
/// where and the user can tell their own entry apart from a detection.
///
/// An added nap also SUPPRESSES any detected nap it overlaps. The entry screen
/// refuses an overlap against what it can see, but that is only a snapshot:
/// log a nap on a day the detector abstained on, sync more raw, and the
/// detector may then find the same bout — leaving two periods over one
/// afternoon and double-crediting it into `nap_min`, sleep need and sleep
/// debt. The person who was there outranks the detector, so their entry wins
/// and the detection is dropped.
///
/// Overlapping ADDITIONS are still not merged with each other: two logged naps
/// that overlap are a data-entry mistake, and silently fusing them would hide
/// it while inflating the total.
///
/// The result is sorted by start, so the timeline draws them in order whatever
/// order they were added in.
List<NapMap> applyNapEdits(List<NapMap> detected, List<NapEdit> edits) {
  final rejected = edits.where((e) => e.kind == NapEditKind.rejected);
  final added = edits.where((e) => e.kind == NapEditKind.added);
  bool supersedes(NapMap nap) {
    final start = (nap['start'] as num).toInt();
    final end = (nap['end'] as num).toInt();
    return rejected.any((r) => r.overlaps(start, end)) ||
        added.any((a) => a.overlaps(start, end));
  }

  final out = <NapMap>[
    for (final nap in detected)
      if (!supersedes(nap)) nap,
    for (final e in added)
      {
          'start': e.startSec,
          'end': e.endSec,
          // A logged nap has no measured sleep/wake split, so asleep and in-bed
          // are the same number — the honest reading of "I slept from here to
          // here". Claiming a lower TST would invent an efficiency nobody
          // measured.
          'duration_min': (e.durationSec / 60).round(),
          'in_bed_min': (e.durationSec / 60).round(),
          'source': 'manual',
          // No confidence: this is a report, not an estimate, and dressing it
          // in the detector's confidence scale would imply it was inferred.
          'confidence': null,
        },
  ];
  out.sort(
    (a, b) => (a['start'] as num).compareTo(b['start'] as num),
  );
  return out;
}

/// Total asleep minutes across [naps] — the `nap_min` scalar.
///
/// Always a number, including 0 for an empty list. The absent-versus-zero
/// distinction is the CALLER's: it decides whether to write `nap_min` at all,
/// because a written 0 claims there were no naps while writing nothing admits
/// the day could not be judged.
int napMinutes(List<NapMap> naps) =>
    naps.fold(0, (a, n) => a + ((n['duration_min'] as num?)?.round() ?? 0));

/// Whether [startSec, endSec) collides with an existing entry.
///
/// Used at entry time so two overlapping logged naps are refused rather than
/// silently double-counting the same hour of the afternoon.
bool napOverlapsExisting(int startSec, int endSec, List<NapMap> existing) =>
    existing.any(
      (n) =>
          startSec < (n['end'] as num).toInt() &&
          (n['start'] as num).toInt() < endSec,
    );
