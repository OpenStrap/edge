// A band's OWN hypnogram as a main-sleep source (`vendor_staged`).
//
// Precedence in `calendarDays`: user override > vendor_staged > auto >
// auto_fallback > none. Stages arrive already mapped to our `stages4` words
// (each adapter owns its one mapping function), and are banked in
// `vendor_sleep_epoch`, never in `observation`. A night is only used when
// [vendorNightRejection] has nothing against it; otherwise it stays stored and
// unused.

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/coverage_resolver.dart' show OwnedSpan, spanAt;

/// One 30 s (or longer) epoch the band staged, in epoch seconds, half-open.
class VendorEpoch {
  final int startSec;
  final int endSec;

  /// 'wake' | 'light' | 'deep' | 'rem'.
  final String stage;
  const VendorEpoch(this.startSec, this.endSec, this.stage);
}

/// The sleep stages a device family can actually tell apart. A stage missing
/// here is one the device folds into another (Mi Band's light sleep holds its
/// REM), so its absence from a night is not "no REM". Unlisted families
/// report all four.
const Map<String, Set<String>> kVendorStagesReported = {
  'miband234': {'wake', 'light', 'deep'},
  'pebble': {'light', 'deep'},
  kHrWindowNightSource: {},
};

Set<String> vendorStagesReported(String? family) =>
    kVendorStagesReported[family] ?? const {'wake', 'light', 'deep', 'rem'};

/// [VendorNight.source] of a night WE staged off a ring's own records
/// (inputs/ultrahuman_inputs.dart): it stages the day as ours ('auto'), not
/// as the device's.
const String kOurRingNightSource = 'hr_5min_stager';

/// [VendorNight.source] of a night that is our HR-led window alone, off a
/// ring that gives HR and nothing to stage by (inputs/colmi_inputs.dart): one
/// epoch, no stages ([kVendorStagesReported]). Ours, from the HR fallback
/// ('auto_fallback'), not the device's.
const String kHrWindowNightSource = 'hr_5min_window';

/// One night of one device's epochs, as `vendor_sleep_epoch` groups them.
class VendorNight {
  final String deviceId;
  final String source;
  final int decodedAtSec;

  /// Sorted by [VendorEpoch.startSec].
  final List<VendorEpoch> epochs;
  const VendorNight({
    required this.deviceId,
    required this.source,
    required this.decodedAtSec,
    required this.epochs,
  });

  int get onsetSec => epochs.first.startSec;
  int get offsetSec => epochs.last.endSec;
}

/// Page-boundary jitter tolerated between consecutive epochs.
const int kVendorEpochJitterSec = 60;
const int kVendorNightMinSec = 3 * 3600;
const int kVendorNightMaxSec = 14 * 3600;

/// A night where one stage holds at least this share is not a hypnogram.
const double kVendorDegenerateShare = 0.9;

/// How far a vendor night's onset and its offset may EACH sit from the window
/// it has to agree with. Edges, not overlap: a partly-synced night (head or
/// tail pages still on the ring) lies wholly inside ours and would pass any
/// overlap test, then replace a full night with half of one. It also rejects
/// a night whose page timing is off by more than this. A shift smaller than
/// this (one page, if pages are stamped at their start rather than their end)
/// is inside our own detection's error and no gate here can see it.
const int kVendorEdgeToleranceSec = 60 * 60;

/// Whether window a and window b start and end within
/// [kVendorEdgeToleranceSec] of each other.
bool vendorEdgesAgree(int aOn, int aOff, int bOn, int bOff) =>
    (aOn - bOn).abs() <= kVendorEdgeToleranceSec &&
    (aOff - bOff).abs() <= kVendorEdgeToleranceSec;

/// Whether our own substrate ([ourTsSec], sorted epoch seconds of the rows
/// admitted to derivation) saw less than half of [n]. Such a night is
/// UNCLAIMED: nothing of ours can stage it or contradict it, so the device's
/// own night is the only one there is.
bool vendorNightUnclaimed(VendorNight n, List<int> ourTsSec) {
  var seen = 0;
  for (final t in ourTsSec) {
    if (t >= n.offsetSec) break;
    if (t >= n.onsetSec) seen++;
  }
  return seen * 2 < n.offsetSec - n.onsetSec;
}

/// The [nights] whose device owns `hr1Hz` at the night's midpoint, so a
/// secondary ring never restages the night of the device that owns the
/// signal. [hrOwner] is that signal's resolved spans; when none has an owner
/// the primary owns it, the same rule the substrate masking uses. With
/// [ourTsSec], a night [vendorNightUnclaimed] by it is kept too: the primary
/// cannot own a night it never recorded.
List<VendorNight> ownedVendorNights(
  List<VendorNight> nights,
  List<OwnedSpan> hrOwner, {
  required String primaryDeviceId,
  List<int>? ourTsSec,
}) {
  final resolved = hrOwner.any((s) => s.deviceId != null);
  return [
    for (final n in nights)
      if (n.epochs.isNotEmpty &&
          ((resolved
                      ? spanAt(hrOwner, (n.onsetSec + n.offsetSec) ~/ 2)
                          ?.deviceId
                      : primaryDeviceId) ==
                  n.deviceId ||
              (ourTsSec != null && vendorNightUnclaimed(n, ourTsSec))))
        n,
  ];
}

/// Why [n] must not stage a night, or null when it may.
///
/// [dataStartSec]/[dataEndSec] bound the substrate the night would be staged
/// over; [ours] is the window our own detection (accel-led or HR-led) found,
/// null when it found none. The decoder behind these epochs is unverified on
/// some rings, so every check is a structural one a wrong layout would fail.
/// An [unclaimed] night ([vendorNightUnclaimed]) skips the checks against our
/// substrate and our window: there is none to check against.
String? vendorNightRejection(
  VendorNight n, {
  required int dataStartSec,
  required int dataEndSec,
  required ({int onsetSec, int offsetSec})? ours,
  bool unclaimed = false,
}) {
  if (n.epochs.isEmpty) return 'empty';
  for (var i = 0; i < n.epochs.length; i++) {
    final e = n.epochs[i];
    if (e.endSec <= e.startSec) return 'bad_epoch';
    if (i == 0) continue;
    final gap = e.startSec - n.epochs[i - 1].endSec;
    if (gap < -kVendorEpochJitterSec) return 'overlap';
    if (gap > kVendorEpochJitterSec) return 'gap';
  }
  final len = n.offsetSec - n.onsetSec;
  if (len < kVendorNightMinSec || len > kVendorNightMaxSec) return 'length';
  if (n.offsetSec > n.decodedAtSec ||
      (!unclaimed &&
          (n.onsetSec < dataStartSec || n.offsetSec > dataEndSec))) {
    return 'outside_data';
  }
  final share = <String, int>{};
  for (final e in n.epochs) {
    share.update(e.stage, (s) => s + e.endSec - e.startSec,
        ifAbsent: () => e.endSec - e.startSec);
  }
  // A source that tells no sleep stages apart holds one stage by definition.
  final staged =
      vendorStagesReported(n.source).where((s) => s != 'wake').length > 1;
  if (staged && share.values.reduce(math.max) >= len * kVendorDegenerateShare) {
    return 'degenerate';
  }
  if (unclaimed) return null;
  if (ours == null) return 'no_own_sleep';
  if (!vendorEdgesAgree(
      n.onsetSec, n.offsetSec, ours.onsetSec, ours.offsetSec)) {
    return 'edges';
  }
  return null;
}

/// [forced] (our segmentation forced onto [n]'s window) with every stage
/// figure replaced by [n]'s epochs. The window, confidence and indices stay
/// ours; a second no epoch covers is 'unobserved'.
ana.SleepSegmentation vendorStagedSegmentation(
  ana.SleepSegmentation forced,
  VendorNight n,
) {
  final win = forced.window;
  if (win == null || win.onsetMs == null) return forced;
  return _staged(win, forced.stages4.length, n, forced.confidence);
}

/// [n] alone as the night, for an UNCLAIMED one ([vendorNightUnclaimed]): the
/// device's window, every second its stage. Confidence is the window-length
/// term our own windows publish (`inBed / 7 h`, clamped 0.3..0.95) with no
/// staging term, because we staged nothing.
ana.SleepSegmentation vendorOnlySegmentation(VendorNight n) {
  final len = n.offsetSec - n.onsetSec;
  return _staged(
    ana.SleepWindow(
      onsetIdx: 0,
      offsetIdx: len,
      onsetMs: n.onsetSec * 1000.0,
      offsetMs: n.offsetSec * 1000.0,
      immobile: const [],
      zAngleDeg: const [],
      sptSec: len,
    ),
    len,
    n,
    (len / (7 * 3600)).clamp(0.3, 0.95).toDouble(),
  );
}

ana.SleepSegmentation _staged(
  ana.SleepWindow win,
  int inBed,
  VendorNight n,
  double confidence,
) {
  final start = win.onsetMs! ~/ 1000;
  final s4 = List<String>.filled(inBed, 'unobserved');
  for (final e in n.epochs) {
    for (var t = math.max(e.startSec, start);
        t < math.min(e.endSec, start + inBed);
        t++) {
      s4[t - start] = e.stage;
    }
  }
  var tst = 0, light = 0, deep = 0, rem = 0, wake = 0, unobserved = 0;
  var first = -1, last = -1;
  for (var i = 0; i < inBed; i++) {
    switch (s4[i]) {
      case 'unobserved':
        unobserved++;
        continue;
      case 'wake':
        wake++;
        continue;
      case 'light':
        light++;
      case 'deep':
        deep++;
      case 'rem':
        rem++;
    }
    tst++;
    if (first < 0) first = i;
    last = i;
  }
  if (tst == 0) return ana.SleepSegmentation.absent;
  var waso = 0, awakenings = 0, longest = 0, run = 0, wakeRun = 0;
  for (var i = 0; i < inBed; i++) {
    final asleep = s4[i] != 'wake' && s4[i] != 'unobserved';
    run = asleep ? run + 1 : 0;
    if (run > longest) longest = run;
    if (s4[i] == 'wake' && i > first && i < last) {
      waso++;
      wakeRun++;
      if (wakeRun == ana.kSustainedAwakeningSec) awakenings++;
    } else {
      wakeRun = 0;
    }
  }
  final observed = inBed - unobserved;
  // A device that reports no wake stages every second of its night as sleep:
  // efficiency would read 100 and awakenings 0 every night by construction,
  // which is no measurement. Those figures stay null for it.
  final reported = vendorStagesReported(n.source);
  final seesWake = reported.contains('wake');
  return ana.SleepSegmentation(
    window: win,
    stages: [
      for (final s in s4)
        s == 'rem'
            ? ana.SleepStage.rem
            : (s == 'light' || s == 'deep'
                ? ana.SleepStage.nrem
                : ana.SleepStage.wake),
    ],
    stages4: s4,
    tstSec: tst,
    wasoSec: seesWake ? waso : null,
    inBedSec: inBed,
    unobservedSec: unobserved,
    efficiencyPct: seesWake && observed > 0 ? 100.0 * tst / observed : null,
    // A night with no stages told apart (our HR-led window alone) has its
    // sleep time and no stage figures: its 'light' only means asleep.
    nremSec: reported.contains('light') || reported.contains('deep')
        ? light + deep
        : null,
    lightSec: reported.contains('light') ? light : null,
    deepSec: reported.contains('deep') ? deep : null,
    // Same for REM on a device that folds it into light: 0 would be served
    // as the device's measured REM.
    remSec: reported.contains('rem') ? rem : null,
    wakeSec: seesWake ? wake : null,
    sustainedAwakenings: seesWake ? awakenings : null,
    longestSleepRunSec: longest,
    confidence: confidence,
  );
}
