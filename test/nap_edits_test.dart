// User edits replayed over the nap detector's output.
//
// The rule that carries the most weight: a rejection matches by OVERLAP, not
// by exact bounds. The detector's boundaries move between runs, and an edit
// that stopped applying the moment a boundary shifted by a minute would be
// worse than useless — the nap the user deleted would quietly come back.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/nap_edits.dart';

Map<String, dynamic> nap(int start, int end, {double? confidence}) => {
  'start': start,
  'end': end,
  'duration_min': ((end - start) / 60).round(),
  'in_bed_min': ((end - start) / 60).round(),
  'confidence': confidence ?? 0.8,
};

void main() {
  const hour = 3600;

  group('rejection', () {
    test('removes a detected nap it overlaps', () {
      final out = applyNapEdits(
        [nap(13 * hour, 14 * hour)],
        const [
          NapEdit(
            kind: NapEditKind.rejected,
            startSec: 13 * hour,
            endSec: 14 * hour,
          ),
        ],
      );
      expect(out, isEmpty);
    });

    test('still applies when the detector shifts its bounds', () {
      // The whole reason it matches by overlap. A re-derivation that moves the
      // start by four minutes must not resurrect a nap the user deleted.
      final out = applyNapEdits(
        [nap(13 * hour + 240, 14 * hour - 120)],
        const [
          NapEdit(
            kind: NapEditKind.rejected,
            startSec: 13 * hour,
            endSec: 14 * hour,
          ),
        ],
      );
      expect(out, isEmpty);
    });

    test('leaves a nap it does not touch', () {
      final out = applyNapEdits(
        [nap(13 * hour, 14 * hour), nap(17 * hour, 18 * hour)],
        const [
          NapEdit(
            kind: NapEditKind.rejected,
            startSec: 13 * hour,
            endSec: 14 * hour,
          ),
        ],
      );
      expect(out, hasLength(1));
      expect(out.single['start'], 17 * hour);
    });

    test('abutting is not overlapping', () {
      // A nap that starts exactly when another ends is a different nap.
      final out = applyNapEdits(
        [nap(14 * hour, 15 * hour)],
        const [
          NapEdit(
            kind: NapEditKind.rejected,
            startSec: 13 * hour,
            endSec: 14 * hour,
          ),
        ],
      );
      expect(out, hasLength(1));
    });
  });

  group('addition', () {
    test('is appended and marked as the user’s own', () {
      final out = applyNapEdits(
        [nap(13 * hour, 14 * hour)],
        const [
          NapEdit(
            kind: NapEditKind.added,
            startSec: 16 * hour,
            endSec: 17 * hour,
          ),
        ],
      );
      expect(out, hasLength(2));
      final added = out.firstWhere((n) => n['source'] == 'manual');
      expect(added['start'], 16 * hour);
      expect(added['duration_min'], 60);
    });

    test('asleep and in-bed are the same, and confidence is absent', () {
      // A logged nap has no measured sleep/wake split. Claiming a lower TST
      // would invent an efficiency nobody measured, and giving it a confidence
      // would dress a report up as an estimate.
      final out = applyNapEdits(const [], const [
        NapEdit(
          kind: NapEditKind.added,
          startSec: 16 * 3600,
          endSec: 16 * 3600 + 1800,
        ),
      ]);
      expect(out.single['duration_min'], 30);
      expect(out.single['in_bed_min'], 30);
      expect(out.single['confidence'], isNull);
    });

    test('supersedes a detection it overlaps', () {
      // The entry screen refuses an overlap against what it can SEE. Log a nap
      // on a day the detector abstained on, sync more raw, and the detector
      // may then find the same bout — two periods over one afternoon, and the
      // hour double-credited into nap minutes, sleep need and sleep debt. The
      // person who was there outranks the detector.
      final out = applyNapEdits(
        [nap(13 * hour, 14 * hour)],
        const [
          NapEdit(
            kind: NapEditKind.added,
            startSec: 13 * hour + 600,
            endSec: 14 * hour + 600,
          ),
        ],
      );
      expect(out, hasLength(1));
      expect(out.single['source'], 'manual');
      expect(napMinutes(out), 60, reason: 'counted once, not twice');
    });

    test('leaves a detection it does not overlap', () {
      final out = applyNapEdits(
        [nap(13 * hour, 14 * hour)],
        const [
          NapEdit(
            kind: NapEditKind.added,
            startSec: 17 * hour,
            endSec: 18 * hour,
          ),
        ],
      );
      expect(out, hasLength(2));
      expect(napMinutes(out), 120);
    });

    test('overlapping additions are kept apart, not fused', () {
      // Fusing them would hide a data-entry mistake while inflating the total.
      // Entry rejects the overlap; the merge does not paper over it.
      final out = applyNapEdits(const [], const [
        NapEdit(kind: NapEditKind.added, startSec: 3600, endSec: 7200),
        NapEdit(kind: NapEditKind.added, startSec: 5400, endSec: 9000),
      ]);
      expect(out, hasLength(2));
    });
  });

  test('the result is ordered by start whatever order edits arrived in', () {
    final out = applyNapEdits(
      [nap(15 * hour, 16 * hour)],
      const [
        NapEdit(kind: NapEditKind.added, startSec: 20 * hour, endSec: 21 * hour),
        NapEdit(kind: NapEditKind.added, startSec: 9 * hour, endSec: 10 * hour),
      ],
    );
    expect(
      out.map((n) => n['start']),
      [9 * hour, 15 * hour, 20 * hour],
    );
  });

  test('no edits changes nothing', () {
    final detected = [nap(13 * hour, 14 * hour), nap(17 * hour, 18 * hour)];
    expect(applyNapEdits(detected, const []), detected);
  });

  group('napMinutes', () {
    test('sums asleep minutes across detected and logged alike', () {
      // A logged nap credits against sleep need exactly as a detected one
      // does — that was the explicit decision, not an accident.
      final merged = applyNapEdits(
        [nap(13 * hour, 14 * hour)],
        const [
          NapEdit(kind: NapEditKind.added, startSec: 16 * 3600, endSec: 17 * 3600),
        ],
      );
      expect(napMinutes(merged), 120);
    });

    test('is zero for an empty list — the caller decides absent vs zero', () {
      expect(napMinutes(const []), 0);
    });
  });

  group('manualNapWindowIsValid', () {
    test('accepts a real nap', () {
      expect(manualNapWindowIsValid(0, 30 * 60), isTrue);
      expect(manualNapWindowIsValid(0, 2 * hour), isTrue);
    });

    test('rejects one too short to be a nap', () {
      expect(manualNapWindowIsValid(0, 60), isFalse);
      expect(manualNapWindowIsValid(0, kMinManualNapSec - 1), isFalse);
      expect(manualNapWindowIsValid(0, kMinManualNapSec), isTrue);
    });

    test('rejects one long enough to be a night', () {
      // Longer than this belongs in the main sleep window, where the stager
      // can actually say something about it.
      expect(manualNapWindowIsValid(0, kMaxManualNapSec + 1), isFalse);
      expect(manualNapWindowIsValid(0, kMaxManualNapSec), isTrue);
    });

    test('rejects a backwards or empty window', () {
      expect(manualNapWindowIsValid(100, 100), isFalse);
      expect(manualNapWindowIsValid(200, 100), isFalse);
    });
  });

  group('napOverlapsExisting', () {
    final existing = [nap(13 * hour, 14 * hour)];

    test('catches an overlap at either edge and containment', () {
      expect(napOverlapsExisting(13 * hour + 60, 15 * hour, existing), isTrue);
      expect(napOverlapsExisting(12 * hour, 13 * hour + 60, existing), isTrue);
      expect(
        napOverlapsExisting(13 * hour + 600, 13 * hour + 900, existing),
        isTrue,
      );
      expect(napOverlapsExisting(12 * hour, 15 * hour, existing), isTrue);
    });

    test('allows a window that merely touches', () {
      expect(napOverlapsExisting(14 * hour, 15 * hour, existing), isFalse);
      expect(napOverlapsExisting(12 * hour, 13 * hour, existing), isFalse);
    });
  });
}
