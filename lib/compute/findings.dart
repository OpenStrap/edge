// FINDINGS — what the app noticed, in one place, said the same way twice.
//
// Four independent detectors fire on the cross-day rollup: the illness CUSUM,
// the multivariate overnight anomaly, the skin-temperature flag and a
// change-point search on resting heart rate. A fifth, the irregular-rhythm
// screen, comes off `metric_series`, and a sixth is the ring's lowest band
// ("Rest today"), on the same composite the ring shows.
//
// Exactly one of them — illness — ever reached a screen. The rest existed only
// as a push notification: one buzz, and if you dismissed it, gone. The
// `notifications` table with its kind/title/body/date has been in the schema
// the whole time with nothing writing to it.
//
// THE LOG IS RECOMPUTED, NOT RECORDED. Nothing here is written to disk and no
// table was added, because a finding is DERIVED and not authored — the rollup
// already carries the per-day inputs (`recent[]` holds `illness`, `anomaly`,
// `temp` and `rhr` for every day in the 90-day window), so the whole history
// is available from the first run instead of a log that starts empty today and
// fills up over three months. It also cannot drift from what the detectors
// currently say: re-derive a day, and its entry changes with it.
//
// What that costs, stated plainly: a finding whose data was later re-derived
// away DISAPPEARS from the log rather than standing as a record of what buzzed
// that morning. That is the right trade for a health app — the log answers
// "what does my data say happened", not "what did this phone display" — and it
// is the reason `notif_fired` is left alone as the fire-once ledger it is.
//
// The wording lives HERE and nowhere else. It used to be inline in the
// notification builder, which is why a log built anywhere else would have
// quietly become a second, differently-worded copy of the same six sentences.

import 'package:flutter/foundation.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/day_label.dart' show dayLabelBefore;

/// The headline composite's band cut-offs — its OWN quantiles (see the long
/// note on `readinessBand`): p=.05 → 26, p=.20 → 37, p=.75 → 61. The ring,
/// the widget, the briefing, the push and the log all band through these.
const double kReadinessRestBelow = 26; // "Rest today"
const double kReadinessEasyBelow = 37; // "Take it easy"
const double kReadinessGoodFrom = 61; // "Good to go"

/// Below this, readiness is a finding: the ring's lowest band, "Rest today"
/// (~5 % of nights by construction). Shared so the ring, the notification and
/// the log cannot disagree about which mornings were low.
const double kLowReadiness = kReadinessRestBelow;

enum FindingKind {
  illness,
  anomaly,
  tempElevated,
  irregularRhythm,
  lowReadiness,
  rhrShift,
}

@immutable
class Finding {
  const Finding(this.kind, this.date, {this.risen, this.score});

  final FindingKind kind;

  /// The day the finding is ABOUT (`YYYY-MM-DD`), which is not the day it was
  /// computed on — a back-catalogue import produces findings about last
  /// November.
  final String date;

  /// Direction, for [FindingKind.rhrShift] only.
  final bool? risen;

  /// The readiness the ring showed, for [FindingKind.lowReadiness] only.
  final int? score;

  /// DETECTION-class, the ones the design sanctions interrupting for. It picks
  /// the notification's dedupe key and marks the entry in the log; it never
  /// changes the wording, and it is never a diagnosis.
  bool get medical => switch (kind) {
        FindingKind.illness ||
        FindingKind.anomaly ||
        FindingKind.tempElevated ||
        FindingKind.irregularRhythm =>
          true,
        _ => false,
      };

  String get title => switch (kind) {
        FindingKind.illness => 'Resting heart rate has been raised',
        FindingKind.anomaly => 'Unusual overnight physiology',
        FindingKind.tempElevated => 'Skin temperature elevated',
        FindingKind.irregularRhythm => 'Irregular heart rhythm — screen',
        FindingKind.lowReadiness => 'Low recovery',
        FindingKind.rhrShift => 'Your resting heart-rate trend shifted',
      };

  String get detail => switch (kind) {
        // A red state is ACCUMULATED evidence: one very high night followed
        // by an ordinary one is enough, so nothing here may claim a streak.
        FindingKind.illness =>
          'Recent nights put your resting heart rate above your usual, from '
              'one very high night or a few slightly raised ones. One signal: a '
              'pattern, not a cause.',
        FindingKind.anomaly =>
          'Your overnight signals are off your usual.',
        FindingKind.tempElevated =>
          'Sustained rise above your usual — a possible illness signal.',
        FindingKind.irregularRhythm =>
          'Your beat-to-beat pattern looked irregular today. This is a '
              'screen, not a diagnosis — see a clinician if you have symptoms.',
        FindingKind.lowReadiness =>
          '${score == null ? 'Recovery was in its lowest band.' : 'Recovery scored $score, its lowest band.'} '
              'Taken together, that night\'s signals sat well below your usual.',
        FindingKind.rhrShift =>
          'Your resting heart rate has ${risen == false ? 'fallen noticeably below' : 'risen noticeably above'} '
              'its recent usual.',
      };

  @override
  bool operator ==(Object other) =>
      other is Finding &&
      other.kind == kind &&
      other.date == date &&
      other.risen == risen &&
      other.score == score;

  @override
  int get hashCode => Object.hash(kind, date, risen, score);
}

/// The readiness the ring and the `recovery` chart show for [date]: the
/// frozen morning headline when it is pinned to [date], else the stored
/// per-day composite. NEVER the glass-box score (a deprecated, differently
/// spread model). Null ⇒ not scored ⇒ no finding.
double? servedReadiness(
  String date, {
  ({String day, int value})? pin,
  double? stored,
}) =>
    (pin != null && pin.day == date) ? pin.value.toDouble() : stored;

/// A low-readiness finding for [date] iff the ring would say "Rest today".
/// Same comparison `readinessBand` makes (raw value vs the cut-off), same
/// rounding the ring prints.
Finding? lowReadinessFinding(String date, double? readiness) =>
    (readiness != null && readiness < kLowReadiness)
        ? Finding(FindingKind.lowReadiness, date, score: readiness.round())
        : null;

/// Every finding the rollup holds, newest day first, and within a day in the
/// order the detectors are listed above.
///
/// [cd] is the stored cross-day bundle (`getInsights()`). Only `recent[]` is
/// read: it carries one row per day with the three overnight detector verdicts
/// already computed, so nothing is re-detected here except the resting-HR
/// change points, which need the whole series at once.
///
/// [readiness] and [irregularDays] come from `metric_series` — the one store
/// that keeps a value per day for as long as the day exists — because neither
/// is in `recent[]`. Absent, those two kinds simply do not appear; they are
/// never inferred from a neighbouring day.
///
/// UNSETTLED DAYS ARE SKIPPED, for the same reason the notification stands down
/// on them: a night that is only half drained reads several bpm high, and a
/// log that shows a finding in the morning and drops it by lunchtime is worse
/// than one that waits for the day to settle. Today settles once its overnight
/// is complete (the drained edge an hour past wake), so it appears here the
/// same morning, not two days later.
List<Finding> findingsHistory(
  Map<String, dynamic> cd, {
  Map<String, double> readiness = const {},
  Set<String> irregularDays = const {},
}) {
  final recent = cd['recent'];
  if (recent is! List) return const [];

  final rows = <Map>[
    for (final r in recent)
      if (r is Map && r['date'] is String && r['unsettled'] != true) r,
  ];

  // The change-point search wants the RHR series in order, and the dates have
  // to travel with the values: the series is compacted (a day with no
  // nocturnal RHR is skipped, which is most days for some people), so the
  // detection's index is an index into the COMPACTED list, not into the days.
  final rhr = <double>[];
  final rhrDates = <String>[];
  for (final r in rows) {
    if (r['rhr'] is num) {
      rhr.add((r['rhr'] as num).toDouble());
      rhrDates.add(r['date'] as String);
    }
  }
  // ponytail: called exactly as the notification path calls it — no `dates`,
  // so a calendar gap does not break the regime. Passing them is the honest
  // reading by the detector's own documentation, but it would make this log
  // report a different set of shifts than the buzz the user actually got.
  // Change both together or neither.
  final shifts = <String, bool>{};
  if (rhr.length >= 10) {
    for (final d in ana.cusumChangePoints(rhr, h: 5.0)) {
      if (d.index >= 0 && d.index < rhrDates.length) {
        shifts[rhrDates[d.index]] = d.direction > 0;
      }
    }
  }

  final out = <Finding>[];
  for (final r in rows.reversed) {
    final date = r['date'] as String;
    if (r['illness'] == true) out.add(Finding(FindingKind.illness, date));
    if (r['anomaly'] == true) out.add(Finding(FindingKind.anomaly, date));
    if (r['temp'] == true) out.add(Finding(FindingKind.tempElevated, date));
    if (irregularDays.contains(date)) {
      out.add(Finding(FindingKind.irregularRhythm, date));
    }
    final low = lowReadinessFinding(date, readiness[date]);
    if (low != null) out.add(low);
    if (shifts.containsKey(date)) {
      out.add(Finding(FindingKind.rhrShift, date, risen: shifts[date]));
    }
  }
  return out;
}

/// The day the rollup's newest row is about, and whether it is still settling.
typedef ExceptionAnchor = ({String date, bool unsettled});

ExceptionAnchor? exceptionAnchor(Map<String, dynamic> cd) {
  final recent = cd['recent'];
  if (recent is! List || recent.isEmpty) return null;
  final last = recent.last;
  if (last is! Map || last['date'] is! String) return null;
  return (date: last['date'] as String, unsettled: last['unsettled'] == true);
}

/// The overnight-detector findings (illness, anomaly, temperature), each read
/// from its family's newest SETTLED entry and dated with THAT entry's date.
List<Finding> crossDayAlertFindings(Map<String, dynamic> cd) {
  Map? entry(String k) => cd[k] is Map ? cd[k] as Map : null;
  String? dateOf(Map? e) => e?['date'] is String ? e!['date'] as String : null;
  final ill = entry('illness'), an = entry('anomaly'), tmp = entry('temp_illness');
  return [
    if (ill?['state'] == 'red' && dateOf(ill) != null)
      Finding(FindingKind.illness, dateOf(ill)!),
    if (an?['flagged'] == true && dateOf(an) != null)
      Finding(FindingKind.anomaly, dateOf(an)!),
    if (tmp?['flag'] == 'elevated' && dateOf(tmp) != null)
      Finding(FindingKind.tempElevated, dateOf(tmp)!),
  ];
}

/// History does not interrupt: a finding may buzz only about today or
/// yesterday, by CALENDAR (DST-safe), judged on the finding's OWN date.
bool isRecentFindingDate(String date, {required String today}) =>
    date == today || date == dayLabelBefore(today, 1);

/// One aggregated health-exception notification, all about [date].
@immutable
class ExceptionNotice {
  const ExceptionNotice(this.date, this.findings);

  final String date;
  final List<Finding> findings;

  bool get medical => findings.any((f) => f.medical);

  /// Same key grammar as before ('$date:exception' / '$date:exception:medical'),
  /// keyed on the day the findings are ABOUT — so a night fires at most once.
  String get dedupeKey =>
      medical ? '$date:exception:medical' : '$date:exception';

  String get title => findings.length == 1
      ? findings.first.title
      : '${findings.length} things to look at';

  String get body => findings.length == 1
      ? findings.first.detail
      : findings.map((f) => '• ${f.title} — ${f.detail}').join('\n');
}

/// Group the due findings by the day they are about, newest day first; drop
/// anything not about today/yesterday. Within a day, detector order is kept.
///
/// Per day rather than one notice per pass: the dedupe key must be the night
/// the finding is about, or the same night evaluated under two different
/// anchors (after midnight, then again the next day) could buzz twice.
List<ExceptionNotice> dueExceptionNotices(
  Iterable<Finding> findings, {
  required String today,
}) {
  final byDate = <String, List<Finding>>{};
  for (final f in findings) {
    if (!isRecentFindingDate(f.date, today: today)) continue;
    (byDate[f.date] ??= <Finding>[]).add(f);
  }
  final dates = byDate.keys.toList()..sort((a, b) => b.compareTo(a));
  return [for (final d in dates) ExceptionNotice(d, byDate[d]!)];
}

/// Every health-exception notice one notification pass should present: the
/// whole decision `DerivationEngine._runNotifications` makes, minus the I/O.
/// The engine reads the three inputs below and emits what this returns.
///
/// [irregularFlag] and [storedReadiness] are the `metric_series` values for
/// the ANCHOR day (the rollup's newest row, [exceptionAnchor]); [pin] is the
/// frozen morning headline, whatever day it is pinned to.
///
/// ANCHORED TO THE DAY THIS IS RUNNING ON ([today]), not to the newest
/// DERIVED day. Every date in here is a day the rollup happened to see, which
/// is not today whenever the newest data is old: import a back-catalogue
/// (finalizeImport runs the pass straight after) or bump kAlgoVersion after a
/// week off the wrist, and a critical, quiet-hours-overriding health alert
/// would go out about nights from last November — in the present tense.
/// Yesterday still counts: before today's overnight settles (and just after
/// midnight) the newest settled night IS yesterday's, and that finding is
/// current. Anything older is history, and history does not interrupt. The
/// gate is by CALENDAR label ([isRecentFindingDate]), so a DST transition
/// cannot gate out a current night.
///
/// ONE exception per day, not one per finding. These signals are correlated
/// by construction — an illness flag, an overnight anomaly and an elevated
/// skin temperature are usually the same morning saying the same thing — so
/// a day's findings are presented once, aggregated ([dueExceptionNotices]).
///
/// The three overnight detectors are dated by THEIR OWN entry — the newest
/// settled night — never by the anchor: that row is usually today's, still
/// settling, and not the night the verdict is about.
List<ExceptionNotice> planExceptionNotices(
  Map<String, dynamic> cd, {
  required String today,
  double? irregularFlag,
  ({String day, int value})? pin,
  double? storedReadiness,
}) {
  final findings = <Finding>[...crossDayAlertFindings(cd)];
  final anchor = exceptionAnchor(cd);
  if (anchor != null && isRecentFindingDate(anchor.date, today: today)) {
    final date = anchor.date;
    // 24/7 irregular-rhythm SCREEN (not a diagnosis). Not a night's verdict,
    // so it does not wait for the night to settle: a day with no detected
    // sleep never settles, and waiting would lose the screen entirely.
    if (irregularFlag == 1.0) {
      findings.add(Finding(FindingKind.irregularRhythm, date));
    }
    // LOW READINESS — the ring's number, judged the way the log judges it.
    // Only on a SETTLED anchor row: before the overnight is complete the live
    // composite still moves (the reason the morning headline freezes at all),
    // and the log skips unsettled rows for the same reason. A missing
    // composite (first 14 nights, |z| capped, no sleep) is "not scored" — no
    // finding, and never a fallback to the glass-box (`readiness_glassbox`,
    // still in [cd] for its breakdown), a deprecated model with a different
    // spread.
    if (!anchor.unsettled) {
      final low = lowReadinessFinding(
        date,
        servedReadiness(date, pin: pin, stored: storedReadiness),
      );
      if (low != null) findings.add(low);
    }

    // "Something changed" — online CUSUM on the recent resting-HR series.
    // Only when the shift lands on the anchor day (a fresh change, not old
    // history we'd re-announce every pass).
    //
    // The dates travel with the values. `rhrSeries` is compacted — days with
    // no nocturnal RHR are skipped, which is most days for some users — so
    // `index == length - 1` meant "the most recent day that HAPPENED to have
    // an rhr". With a few null days in between, a week-old shift satisfied it
    // and went out at critical priority under today's date.
    //
    // `recent[].rhr` is written WITHOUT the `settled()` guard on purpose — the
    // trend chart is right to show an unsettled day's value. A critical-
    // priority ALERT is not: a night that is only half drained reads several
    // bpm high, fires "your resting HR trend shifted", and then corrects an
    // hour later with the day's dedupe key already claimed. So this consumer
    // stands down until the day settles.
    final recent = cd['recent'];
    final rhrSeries = <double>[];
    final rhrDates = <String?>[];
    if (recent is List) {
      for (final r in recent) {
        if (r is Map && r['rhr'] is num) {
          rhrSeries.add((r['rhr'] as num).toDouble());
          rhrDates.add(r['date'] as String?);
        }
      }
    }
    if (!anchor.unsettled && rhrSeries.length >= 10) {
      final dets = ana.cusumChangePoints(rhrSeries, h: 5.0);
      if (dets.isNotEmpty && rhrDates[dets.last.index] == date) {
        findings.add(
            Finding(FindingKind.rhrShift, date, risen: dets.last.direction > 0));
      }
    }
  }
  return dueExceptionNotices(findings, today: today);
}
