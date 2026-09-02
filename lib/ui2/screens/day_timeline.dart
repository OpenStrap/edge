// DAY TIMELINE — what happened, in the order it happened.
//
// Every screen in this app answers "how much" for one number over many days.
// None of them answered "what was going on around then", which is the question
// somebody asks the moment a line moves: the workout, the nap, the coffee at
// nine, the night the band spent on the charger. The pieces were all on disk
// and all on the same axis already — `getDayTimeline` joins HR, HRV, sleep,
// naps, sessions and events; `getDayWear` holds the off-wrist segments; meals,
// doses and timed journal fields each carry their own clock — and nothing put
// them in one column.
//
// WHAT IT IS NOT. It is not an explanation. Two things next to each other on a
// clock is adjacency, and adjacency is not cause — a timeline is the most
// tempting place in the app to imply otherwise, so the page states the limit
// in the same words the journal findings use and never orders items by
// anything but time.
//
// A THING WITH NO CLOCK DOES NOT GET A PLACE ON ONE. A journal note is stored
// per DAY with no time, and so is a meal logged without one. Placing those
// anywhere on the axis — midnight, noon, the middle — would be inventing the
// one fact the entry is missing. They go in their own block underneath, which
// says what it is.

import 'dart:convert' show jsonDecode;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ble/adapters/signals.dart' show InputSignal;
import '../../data/day_label.dart' show localDayEndSec;
import '../../data/db.dart';
import '../../data/journal_fields.dart';
import '../../data/local_repository.dart';
import '../../data/med_store.dart';
import '../../data/nutrition_store.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../state/locale_controller.dart';
import '../activity/catalogue.dart' show activityByName;
import '../profile/devices.dart'
    show DeviceFilter, DeviceOption, signalCandidates;
import '../ui2.dart';
import 'home_screen.dart' show clockOfTs, repoOf;
import 'metric_detail.dart' show dayNavRow, detailScaffold, pickDay;

/// One thing that happened, at a time it is known to have happened at.
@immutable
class Moment {
  const Moment({
    required this.at,
    required this.title,
    required this.icon,
    this.color,
    this.until,
    this.detail = '',
  });

  /// Epoch seconds. The ONLY sort key — nothing on this page is ranked.
  final int at;

  /// Epoch seconds when this was a span rather than an instant.
  final int? until;

  final String title;
  final String detail;
  final IconData icon;

  /// The accent this line is drawn in, or NULL for a fact about the band
  /// rather than about the person — the charger, the restart, the wrist it was
  /// not on. Those render in muted ink, because a colour is a claim that the
  /// row belongs to a domain and none of them do.
  final Color? color;
}

/// Something that was logged for this day and carries no time of day. Kept
/// apart from [Moment] by the type, so it cannot accidentally be placed.
@immutable
class DayNote {
  const DayNote(this.title, this.detail, this.icon);
  final String title, detail;
  final IconData icon;
}

/// Band events worth a line. Everything else the strap emits is about the
/// strap — bonds, flash writes, sync bookkeeping — and belongs on Devices, not
/// in somebody's day.
Map<int, (String, IconData)> _events(AppLocalizations? l) => {
  7: (l?.dayTimelineChargerOn ?? 'On the charger', LucideIcons.batteryCharging),
  8: (l?.dayTimelineChargerOff ?? 'Off the charger', LucideIcons.batteryFull),
  14: (l?.dayTimelineDoubleTap ?? 'You double-tapped the band', LucideIcons.hand),
  15: (l?.dayTimelineRestarted ?? 'The band restarted', LucideIcons.rotateCw),
  21: (l?.dayTimelineBatteryPackAttached ?? 'Battery pack attached',
      LucideIcons.batteryCharging),
  22: (l?.dayTimelineBatteryPackRemoved ?? 'Battery pack removed', LucideIcons.battery),
  57: (l?.dayTimelineAlarmWentOff ?? 'Alarm went off', LucideIcons.alarmClock),
};

/// An off-wrist gap shorter than this is a dropout, not an event in a day.
/// Listing every one of them would bury the four that mean something under
/// forty that mean the strap moved.
const int kMinOffWristMin = 15;

String _dur(num? minutes) {
  if (minutes == null) return '';
  final m = minutes.round();
  return m < 60 ? '${m}m' : '${m ~/ 60}h ${m % 60}m';
}

String _span(int from, int? to) =>
    to == null ? clockOfTs(from) : '${clockOfTs(from)} – ${clockOfTs(to)}';

/// THE JOIN. Pure, so the ordering and the placement rules are testable
/// without a database or a frame.
///
/// [timeline] is `getDayTimeline`, [wear] is `getDayWear`. Everything else is
/// one store each. A source that returned nothing simply contributes nothing —
/// there is no placeholder for a domain the user does not use.
List<Moment> dayMoments({
  required Map<String, dynamic> timeline,
  Map<String, dynamic> wear = const {},
  List<FoodEntry> meals = const [],
  List<({String label, int at})> doses = const [],
  Map<String, JournalMetricValue> journal = const {},
  List<JournalFieldSpec> fields = const [],
  AppLocalizations? l,
}) {
  final out = <Moment>[];
  int? asInt(Object? v) => (v as num?)?.toInt();

  // Sleep. The onset normally sits in the PREVIOUS calendar day — a day's
  // sleep is the night that ended that morning — so it sorts to the top and
  // reads as what it is: you were already asleep when this day started.
  for (final s in (timeline['sleep'] as List?) ?? const []) {
    if (s is! Map) continue;
    final on = asInt(s['onset_ts']), off = asInt(s['wake_ts']);
    if (on == null || off == null) continue;
    out.add(Moment(
      at: on,
      until: off,
      title: l?.dayTimelineAsleep ?? 'Asleep',
      detail: '${_span(on, off)} · ${_dur((off - on) / 60)}',
      icon: LucideIcons.moon,
      color: C.blue,
    ));
  }

  for (final n in (timeline['naps'] as List?) ?? const []) {
    if (n is! Map) continue;
    final on = asInt(n['start']), off = asInt(n['end']);
    if (on == null) continue;
    out.add(Moment(
      at: on,
      until: off,
      title: l?.dayTimelineNap ?? 'Nap',
      detail: '${_span(on, off)} · ${_dur(n['duration_min'] as num?)}',
      icon: LucideIcons.bedDouble,
      color: C.indigo,
    ));
  }

  for (final s in (timeline['sessions'] as List?) ?? const []) {
    if (s is! Map) continue;
    final on = asInt(s['start_ts']);
    if (on == null) continue;
    final type = s['type']?.toString();
    final act = activityByName(type);
    final bits = <String>[
      _span(on, asInt(s['end_ts'])),
      if (s['duration_min'] != null) _dur(s['duration_min'] as num?),
      if (s['avg_hr'] != null) '${s['avg_hr']} bpm avg',
    ];
    out.add(Moment(
      at: on,
      until: asInt(s['end_ts']),
      title: act?.name ??
          (type == null
              ? (l?.dayTimelineWorkout ?? 'Workout')
              : type.replaceAll('_', ' ')),
      detail: bits.join(' · '),
      icon: act?.icon ?? LucideIcons.dumbbell,
      color: act?.color ?? C.orange,
    ));
  }

  // The band off the wrist. This is the single most useful line on the page on
  // most people's days, because it is the reason the rest of the day is empty
  // — and the segments already carry the exact clock times.
  for (final w in (wear['segments'] as List?) ?? const []) {
    if (w is! Map || w['on'] == true) continue;
    final on = asInt(w['start']), off = asInt(w['end']);
    final len = (w['len_min'] as num?) ?? (on != null && off != null ? (off - on) / 60 : null);
    if (on == null || len == null || len < kMinOffWristMin) continue;
    out.add(Moment(
      at: on,
      until: off,
      title: l?.dayTimelineBandOffWrist ?? 'Band off your wrist',
      detail: '${_span(on, off)} · ${_dur(len)}',
      icon: LucideIcons.watch,
    ));
  }

  // The day's extremes. NOT anomalies — the highest and lowest reading a day
  // has is arithmetic, and calling it unusual would be a claim the number does
  // not support. What it is good for is a time to look at.
  final highs = timeline['highs'];
  if (highs is Map) {
    for (final e in [
      ('peak_hr', l?.dayTimelineHighestHr ?? 'Highest heart rate', LucideIcons.trendingUp),
      ('low_hr', l?.dayTimelineLowestHr ?? 'Lowest heart rate', LucideIcons.trendingDown),
    ]) {
      final h = highs[e.$1];
      final t = h is Map ? asInt(h['t']) : null;
      final v = h is Map ? h['v'] as num? : null;
      if (t == null || v == null) continue;
      out.add(Moment(
        at: t,
        title: e.$2,
        detail: l?.dayTimelineBpmAt(v.round(), clockOfTs(t)) ??
            '${v.round()} bpm at ${clockOfTs(t)}',
        icon: e.$3,
        color: C.red,
      ));
    }
  }

  // Events, de-duplicated: the strap delivers the same (id, ts) up to four
  // times, and a day with the charger on it should not read as four chargers.
  final seen = <String>{};
  final events = _events(l);
  for (final e in (timeline['events'] as List?) ?? const []) {
    if (e is! Map) continue;
    final id = asInt(e['event_id']), t = asInt(e['ts']);
    final def = id == null ? null : events[id];
    if (def == null || t == null || !seen.add('$id/$t')) continue;
    out.add(Moment(
      at: t,
      title: def.$1,
      detail: clockOfTs(t),
      icon: def.$2,
    ));
  }

  for (final m in meals) {
    final t = m.atTs;
    if (t == null) continue;
    final kcal = m.kcal;
    out.add(Moment(
      at: t,
      title: m.label.isEmpty ? m.meal : m.label,
      detail: [
        clockOfTs(t),
        if (m.meal.isNotEmpty) m.meal,
        // A bare occasion is complete as a log. It just has no energy on it,
        // and printing "0 kcal" for one is the fabrication this app refuses.
        if (kcal != null) '${kcal.round()} kcal',
      ].join(' · '),
      icon: LucideIcons.utensils,
      color: C.domFood,
    ));
  }

  for (final d in doses) {
    out.add(Moment(
      at: d.at,
      title: d.label,
      detail: l?.dayTimelineTakenAt(clockOfTs(d.at)) ?? 'Taken at ${clockOfTs(d.at)}',
      icon: LucideIcons.pill,
      color: C.purple,
    ));
  }

  // Timed journal fields — caffeine and alcohol carry the minute they last
  // landed, which is the sleep-relevant fact about both.
  final dayStart = asInt(timeline['day_start']);
  final specs = {for (final f in fields) f.key: f};
  journal.forEach((key, v) {
    final min = v.atMinuteOfDay;
    if (min == null || dayStart == null) return;
    final spec = specs[key];
    final n = v.value == v.value.roundToDouble()
        ? v.value.round().toString()
        : v.value.toStringAsFixed(1);
    out.add(Moment(
      at: dayStart + min * 60,
      title: spec?.label ?? key.replaceAll('_', ' '),
      // "last one at" is the stored meaning, and saying just "at" would turn a
      // total plus one timestamp into a single event that never happened.
      detail: '$n${spec == null || spec.unit.isEmpty ? '' : ' ${spec.unit}'} · '
          '${l?.dayTimelineLastAt(clockOfTs(dayStart + min * 60)) ?? 'last at ${clockOfTs(dayStart + min * 60)}'}',
      icon: LucideIcons.notebookPen,
      color: C.domMind,
    ));
  });

  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

/// Logged for the day, with no time on it. Same sources, opposite branch.
List<DayNote> dayNotes({
  List<FoodEntry> meals = const [],
  Map<String, JournalMetricValue> journal = const {},
  List<JournalFieldSpec> fields = const [],
  List<Map<String, dynamic>> journalRows = const [],
  AppLocalizations? l,
}) {
  final out = <DayNote>[];
  for (final r in journalRows) {
    final note = (r['note'] as String?)?.trim() ?? '';
    // `tags_json`, not `tags` — the column holds a JSON list and a reader that
    // asked for the wrong name got null and silently dropped every tagged day
    // whose note was empty.
    final tags = <String>[];
    try {
      final j = jsonDecode((r['tags_json'] as String?) ?? '[]');
      if (j is List) tags.addAll([for (final t in j) t.toString()]);
    } catch (_) {/* a malformed row loses its tags, not the note */}
    if (note.isEmpty && tags.isEmpty) continue;
    out.add(DayNote(
      note.isEmpty ? (l?.dayTimelineTaggedTitle ?? 'Tagged') : note,
      tags.join(' · '),
      LucideIcons.notebookPen,
    ));
  }
  final specs = {for (final f in fields) f.key: f};
  journal.forEach((key, v) {
    if (v.atMinuteOfDay != null) return;
    final spec = specs[key];
    final n = v.value == v.value.roundToDouble()
        ? v.value.round().toString()
        : v.value.toStringAsFixed(1);
    out.add(DayNote(
      spec?.label ?? key.replaceAll('_', ' '),
      '$n${spec == null || spec.unit.isEmpty ? '' : ' ${spec.unit}'}',
      LucideIcons.clipboardList,
    ));
  });
  for (final m in meals) {
    if (m.atTs != null) continue;
    out.add(DayNote(
      m.label.isEmpty ? m.meal : m.label,
      [
        if (m.meal.isNotEmpty) m.meal,
        if (m.kcal != null) '${m.kcal!.round()} kcal',
      ].join(' · '),
      LucideIcons.utensils,
    ));
  }
  return out;
}

// ═══════════════════ the day on one clock ═══════════════════
//
// The picture of the same day the list below is the writing of. One
// destination, two halves: the graph answers WHEN, the list answers WHAT, and
// neither is a second copy of the other.
//
// FOUR LANES, and the count is the design. Heart rate is the spine — it is the
// only thing this band measures all day at a rate worth drawing. Sleep is a
// band across the hours it covers. Workouts are blocks on the top edge.
// Movement is a strip along the floor. Everything else the day holds — meals,
// doses, notes, breathing, temperature, HRV — stays in the list rather than
// getting a lane, because ten labelled lanes is a chart nobody reads twice and
// the things that were left out are all better as a line of text with a time
// on it than as a shape.
//
// GAPS STAY GAPS. The band spends real hours off the wrist, and a line drawn
// across those hours is a measurement of somebody who was not wearing it. A
// minute with nothing in it breaks the curve AND changes the ground behind it,
// so an empty stretch reads as absent rather than as flat.

/// One slot per minute. A sample's index IS its clock time, which is what
/// makes every lane share one axis without any of them being resampled.
const int kDayMinutes = 1440;

/// The day, drawn. All four lanes on one time base, built once.
@immutable
class DayGraph {
  const DayGraph({
    this.hr = const [],
    this.movement = const [],
    this.rest = const [],
    this.work = const [],
  });

  /// Beats per minute, one slot per minute of the day, `null` where nothing
  /// was recorded.
  final List<double?> hr;

  /// Share of each minute spent moving, 0…1, `null` where nothing was
  /// recorded. Note the difference from a zero: 0 is a minute we watched you
  /// sit still, `null` is a minute we were not there for.
  final List<double?> movement;

  /// Asleep and naps, as (from, to) minute of the day.
  final List<(int, int, Color)> rest;

  /// Workouts, same units.
  final List<(int, int, Color)> work;

  int get slots => hr.length > movement.length ? hr.length : movement.length;

  bool get hasCurve => hr.any((v) => v != null);

  bool get isEmpty =>
      !hasCurve &&
      rest.isEmpty &&
      work.isEmpty &&
      !movement.any((v) => v != null);

  /// The stretches with nothing measured in them, as (from, to) minutes.
  ///
  /// EVERY lane has to be empty. A minute with movement but no heart rate was
  /// still a minute we were there for, and so was a minute inside a night or a
  /// workout — the span itself is the measurement, even where no curve was
  /// drawn over it. Marking those as unrecorded would put the two claims on
  /// top of each other and let the ground contradict the band.
  List<(int, int)> get unmeasured {
    final n = slots;
    final known = List<bool>.filled(n, false);
    for (final (a, b, _) in [...rest, ...work]) {
      for (var i = a; i < b && i < n; i++) {
        known[i] = true;
      }
    }
    final out = <(int, int)>[];
    int? from;
    for (var i = 0; i < n; i++) {
      final has = known[i] ||
          (i < hr.length && hr[i] != null) ||
          (i < movement.length && movement[i] != null);
      if (has) {
        if (from != null) out.add((from, i));
        from = null;
      } else {
        from ??= i;
      }
    }
    if (from != null) out.add((from, n));
    return out;
  }
}

/// THE JOIN, for the picture. Pure, like [dayMoments] — the placement rules
/// are the thing worth testing and they need neither a database nor a frame.
///
/// [timeline] is `getDayTimeline`. Anything it did not carry contributes
/// nothing; there is no placeholder lane for a day with no workouts in it.
DayGraph dayGraph(Map<String, dynamic> timeline, {List<Object?>? hrOverride}) {
  final dayStart = (timeline['day_start'] as num?)?.toInt();
  if (dayStart == null || dayStart <= 0) return const DayGraph();
  // The day's REAL length. A spring-forward day is 23 h and a fall-back day is
  // 25 h, and a flat 1440 would drop the last hour of one of them — the same
  // bug day_label.dart exists to stop everywhere else.
  final end = localDayEndSec((timeline['date'] as String?) ?? '');
  final n = end == null || end <= dayStart
      ? kDayMinutes
      : ((end - dayStart) / 60).round();

  int? slot(Object? ts) {
    final t = (ts as num?)?.toInt();
    if (t == null) return null;
    final m = (t - dayStart) ~/ 60;
    return m < 0 || m >= n ? null : m;
  }

  final hr = List<double?>.filled(n, null);
  for (final e in hrOverride ?? (timeline['hr'] as List?) ?? const []) {
    if (e is! Map) continue;
    final i = slot(e['t']);
    final v = (e['v'] as num?)?.toDouble();
    // hr 0 is the pipeline's "no lock", not a heart that stopped.
    if (i == null || v == null || v <= 0) continue;
    hr[i] = v;
  }

  // The activity curve is 5-minute buckets. Each one fills its own five
  // minutes and no more — smearing it wider would put movement in minutes it
  // was never measured over.
  final movement = List<double?>.filled(n, null);
  for (final e in (timeline['activity'] as List?) ?? const []) {
    if (e is! Map) continue;
    final i = slot(e['t']);
    final v = (e['v'] as num?)?.toDouble();
    if (i == null || v == null || !v.isFinite) continue;
    for (var k = i; k < i + 5 && k < n; k++) {
      movement[k] = v;
    }
  }

  /// A span clipped to the day. A night's onset sits in the PREVIOUS calendar
  /// day, so it clips to midnight rather than being dropped — you were already
  /// asleep when this day started, and that is a fact about this day.
  (int, int, Color)? span(Object? from, Object? to, Color col) {
    final a = (from as num?)?.toInt(), b = (to as num?)?.toInt();
    if (a == null || b == null || b <= a) return null;
    final lo = ((a - dayStart) ~/ 60).clamp(0, n);
    final hi = ((b - dayStart) ~/ 60).clamp(0, n);
    return hi <= lo ? null : (lo, hi, col);
  }

  // A nap is asleep. It gets its own name in the list below, where the
  // distinction is worth a word; up here a second blue would be a second key
  // for the same fact.
  final rest = <(int, int, Color)>[
    for (final s in (timeline['sleep'] as List?) ?? const [])
      if (s is Map) ?span(s['onset_ts'], s['wake_ts'], C.blue),
    for (final s in (timeline['naps'] as List?) ?? const [])
      if (s is Map) ?span(s['start'], s['end'], C.blue),
  ];
  // ONE COLOUR FOR EVERY WORKOUT. The list below draws each activity in its
  // own, which is where that distinction is readable; up here it would be four
  // more hues on a chart whose whole job is to be glanced at, and a legend
  // swatch that lied about three quarters of the blocks.
  final work = <(int, int, Color)>[
    for (final s in (timeline['sessions'] as List?) ?? const [])
      if (s is Map) ?span(s['start_ts'], s['end_ts'], C.orange),
  ];

  return DayGraph(hr: hr, movement: movement, rest: rest, work: work);
}

// ═══════════════════ the screen ═══════════════════

class TimelineData {
  const TimelineData({
    this.day,
    this.days = const [],
    this.graph = const DayGraph(),
    this.moments = const [],
    this.notes = const [],
    this.raw,
  });

  final String? day;

  /// Every derived day, newest first — what [DayNav] steers over.
  final List<String> days;

  /// The same day as [moments], drawn.
  final DayGraph graph;
  final List<Moment> moments;
  final List<DayNote> notes;

  /// The raw `getDayTimeline` payload [graph] was built from — retained so a
  /// per-device selection can rebuild [graph] with `dayGraph(raw!,
  /// hrOverride: …)` without a second `getDayTimeline` call (M6 §7.3).
  final Map<String, dynamic>? raw;

  static Future<TimelineData> load(
    LocalRepository repo, {
    String? want,
    AppLocalizations? l,
  }) async {
    final days = await repo.availableDays();
    final today = await repo.getToday();
    final day = pickDay(
        days, want, (today['status'] as Map?)?['today_day']?.toString());
    if (day == null) return TimelineData(days: days);

    final timeline = await repo.getDayTimeline(day);
    final wear = await repo.getDayWear(day);
    final fields = await repo.getJournalFields();
    final journal = await repo.getJournalMetrics(day);
    final db = await LocalDb.instance;
    final meals = await NutritionDb.entriesForDay(db, day);
    final notes = await LocalDb.journalRows(sinceDaysEpoch: day);

    // Doses: one row per (medication, slot), and only the ones actually taken
    // carry a clock. A skipped dose is a real fact with no time attached, so it
    // is not on the axis — see the note at the top of this file.
    final defs = {for (final d in await MedDb.defs(db, activeOnly: false)) d.key: d};
    final taken = <({String label, int at})>[];
    (await MedDb.dosesForDay(db, day)).forEach((key, slots) {
      for (final row in slots.values) {
        final ts = (row['taken_ts'] as num?)?.toInt();
        if (ts == null) continue;
        taken.add((label: defs[key]?.label ?? key, at: ts));
      }
    });

    // WHAT OTHER SOURCES SAY about this day (M6). Gated on isNotEmpty being
    // the ONLY behaviour change: zero rows today, on every install, so the
    // list below is empty and this section renders nothing.
    final observations = await repo.getDayObservations(day);

    return TimelineData(
      day: day,
      days: days,
      graph: dayGraph(timeline),
      raw: timeline,
      moments: dayMoments(
        timeline: timeline,
        wear: wear,
        meals: [for (final m in meals) m.sanitised],
        doses: taken,
        journal: journal,
        fields: fields,
        l: l,
      ),
      notes: [
        ...dayNotes(
          meals: [for (final m in meals) m.sanitised],
          journal: journal,
          fields: fields,
          journalRows: [for (final r in notes) if (r['date'] == day) r],
          l: l,
        ),
        // ONE ROW PER OBSERVATION. Attribution always shown and never
        // abbreviated — a vendor number rendered without its source is a
        // number the user will read as ours. No tier, no confidence, no
        // dot — Observation deliberately carries none. A vendorKey renders
        // verbatim ('BioCharge' stays 'BioCharge'; mapping it onto one of
        // our keys is the worst available mistake here).
        for (final r in observations)
          DayNote(
            (r['vendor_key'] as String?) ?? (r['key'] as String?) ?? '',
            '${r['value']}${(r['unit'] as String?)?.isNotEmpty == true ? ' ${r['unit']}' : ''} · ${r['attribution']}',
            LucideIcons.tag,
          ),
      ],
    );
  }
}

class DayTimelineScreen extends StatefulWidget {
  const DayTimelineScreen({super.key, this.day, this.data});

  /// The day to open. Null means the newest derived one.
  final String? day;
  final TimelineData? data;

  @override
  State<DayTimelineScreen> createState() => _DayTimelineScreenState();
}

class _DayTimelineScreenState extends State<DayTimelineScreen> {
  TimelineData? _d;
  bool _loading = true;
  String? _day;

  /// The devices that could serve `hr` on this screen — registry-only, no
  /// query. Empty on every single-device install, which keeps the filter row
  /// absent (M6 §7.3).
  List<DeviceOption> _candidates = const [];

  /// The device whose own curve [_d]'s graph is drawn from, or null for the
  /// merged one. Cleared on every day change — a device selection is about
  /// the day on screen.
  String? _device;
  bool _deviceBounded = false;
  String? _deviceOldest;

  // `TimelineData` bakes `AppLocalizations` strings into `moments`/`notes` at
  // load time (see `TimelineData.load`), so a language switch while this
  // screen is alive would otherwise leave it showing the old locale until
  // something else (a day change, a revision bump) happens to reload it.
  // Sentinel so the system-default locale (`code == null`) is not mistaken
  // for "never seen yet" on the first pass.
  static const Object _localeUnset = Object();
  Object? _seenLocale = _localeUnset;

  /// Bumped on every `_load()` call so an OLDER one that resolves after a
  /// NEWER one (a locale change firing while a day-nav load is still in
  /// flight) can tell it lost the race and must not overwrite fresher data.
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _day = widget.day;
    if (widget.data != null) {
      _d = widget.data;
      _loading = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `code` alone misses a SYSTEM locale change while it is null (no
    // in-app override) — see the same fix in RevisionReload.
    final Object localeKey;
    try {
      final code = context.watch<LocaleController>().code;
      localeKey = code ?? Localizations.localeOf(context);
    } catch (_) {
      return;
    }
    if (identical(_seenLocale, _localeUnset)) {
      _seenLocale = localeKey;
    } else if (_seenLocale != localeKey && widget.data == null) {
      _seenLocale = localeKey;
      _load();
    }
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    final repo = repoOf(context);
    if (repo == null) {
      if (mounted && token == _loadToken) setState(() => _loading = false);
      return;
    }
    final l = AppLocalizations.of(context);
    try {
      final d = await TimelineData.load(repo, want: _day, l: l);
      final candidates = mounted
          ? signalCandidates(context.read<AppState>(),
              requires: {InputSignal.hr1Hz})
          : const <DeviceOption>[];
      if (mounted && token == _loadToken) {
        setState(() => (
          _d = d,
          _candidates = candidates,
          _device = null,
          _loading = false,
        ));
      }
    } catch (_) {
      if (mounted && token == _loadToken) setState(() => _loading = false);
    }
  }

  Future<void> _selectDevice(String? id) async {
    final d = _d;
    final day = _day ?? d?.day;
    if (d?.raw == null || day == null) return;
    if (id == null) {
      setState(() {
        _device = null;
        _deviceBounded = false;
        _deviceOldest = null;
        _d = TimelineData(
          day: d!.day,
          days: d.days,
          graph: dayGraph(d.raw!),
          moments: d.moments,
          notes: d.notes,
          raw: d.raw,
        );
      });
      return;
    }
    final repo = repoOf(context);
    if (repo == null) return;
    final c = await repo.getDeviceChart('hr', deviceId: id, date: day);
    if (!mounted) return;
    final bounded = c['bounded'] == true;
    setState(() {
      _device = id;
      _deviceBounded = bounded;
      _deviceOldest = c['oldest'] as String?;
      _d = TimelineData(
        day: d!.day,
        days: d.days,
        graph: bounded
            ? const DayGraph()
            : dayGraph(d.raw!, hrOverride: c['points'] as List?),
        moments: d.moments,
        notes: d.notes,
        raw: d.raw,
      );
    });
  }

  void _goDay(String day) {
    setState(() {
      _day = day;
      _loading = true;
    });
    _load();
  }

  @override
  Widget build(BuildContext c) {
    final d = _d ?? const TimelineData();
    final l = AppLocalizations.of(c);
    return detailScaffold(c, l?.dayTimelineTitle ?? 'Breakdown of your day',
        sub: l?.dayTimelineSub ?? 'MIDNIGHT TO MIDNIGHT', [
      ...dayNavRow(_day ?? d.day, d.days, _goDay),
      if (_loading) ...[
        const SizedBox(height: S.x8),
        const Center(child: CircularProgressIndicator()),
      ] else ...[
        if (_candidates.length >= 2) ...[
          const SizedBox(height: S.x2),
          DeviceFilter(
            options: _candidates,
            selected: _device,
            onSelect: _selectDevice,
          ),
          if (_deviceBounded)
            Padding(
              padding: const EdgeInsets.only(top: S.x2),
              child: Text(
                l?.dayTimelineDeviceBounded(_deviceOldest ?? '') ??
                    'Per-device detail is kept for recent days only. Before '
                        '${_deviceOldest ?? ''} we know which device recorded, '
                        'not what it said.',
                style: F.over.copyWith(color: P.of(c).ink3),
              ),
            ),
          const SizedBox(height: S.x2),
        ],
        ...timelineBody(c, d),
      ],
    ]);
  }
}

/// The graph, or nothing.
///
/// NOTHING when there is no heart-rate curve: the curve is what the y axis is
/// for, and a frame with an axis and no line under it reads as a measurement
/// of zero. A day like that is entirely carried by the list underneath, which
/// is the right shape for it — a handful of things that happened, in order.
Widget? dayGraphCard(BuildContext c, DayGraph g) {
  if (!g.hasCurve) return null;
  final p = P.of(c);
  final l = AppLocalizations.of(c);
  final n = g.slots;
  double at(int m) => n <= 0 ? 0 : m / n;
  final axis = AxisSpec.of([for (final v in g.hr) ?v], ticks: 3);
  if (axis == null) return null;

  final asleep = p.on(C.blue), workout = p.on(C.orange);
  final gaps = g.unmeasured;
  return Surface(
    child: ChartFrame(
      title: l?.dayTimelineHeartRateTitle ?? 'Heart rate',
      unit: 'bpm',
      height: 200,
      yAxis: axis,
      // Three, and only three, because ChartFrame lays the first flush left,
      // the last flush right and the rest centred — which puts a middle label
      // exactly on the middle of the plot and a five-label row 5 % out.
      xLabels: [
        l?.dayTimelineMidnight ?? 'Midnight',
        l?.dayTimelineNoon ?? 'Noon',
        l?.dayTimelineMidnight ?? 'Midnight',
      ],
      legend: [
        if (g.rest.isNotEmpty) (l?.dayTimelineAsleep ?? 'Asleep', asleep),
        if (g.work.isNotEmpty) (l?.dayTimelineWorkout ?? 'Workout', workout),
        if (g.movement.any((v) => v != null))
          (l?.dayTimelineMoving ?? 'Moving', p.on(C.domMove)),
        if (gaps.isNotEmpty) (l?.dayTimelineNotRecorded ?? 'Not recorded', p.card2),
      ],
      series: g.hr,
      child: Stack(children: [
        Positioned.fill(
          child: CustomPaint(
            size: Size.infinite,
            painter: DayLanes(
              p: p,
              gaps: [for (final (a, b) in gaps) (at(a), at(b))],
              rest: [
                for (final (a, b, _) in g.rest) (at(a), at(b), asleep),
              ],
              work: [
                for (final (a, b, _) in g.work) (at(a), at(b), workout),
              ],
              movement: g.movement,
            ),
          ),
        ),
        Positioned.fill(
          child: CustomPaint(
            size: Size.infinite,
            // No fill under the line: the area would swallow the bands behind
            // it, and the bands are the half of this picture the curve cannot
            // say on its own.
            painter: LineChart(g.hr, p.on(C.red), fill: false, axis: axis),
          ),
        ),
      ]),
    ),
  );
}

/// The page's body, given loaded data. Split out so the gallery can build every
/// state of it without a repository.
List<Widget> timelineBody(BuildContext c, TimelineData d) {
  final p = P.of(c);
  final l = AppLocalizations.of(c);
  final graph = dayGraphCard(c, d.graph);
  return [
    ?graph,
    if (d.moments.isEmpty && d.notes.isEmpty && graph == null)
      StatusCard(
        l?.dayTimelineNothingRecordedTitle ?? 'Nothing was recorded on this day',
        l?.dayTimelineNothingRecordedBody ??
            'No sleep, no session, no log and no band event carrying a time. A day '
                'with nothing on it is usually a day the band was off.',
        icon: LucideIcons.circleSlash,
      )
    else ...[
      if (d.moments.isEmpty)
        StatusCard(
          l?.dayTimelineNoTimeTitle ?? 'Nothing on this day carries a time',
          l?.dayTimelineNoTimeBody ?? 'What was logged for it is below.',
          icon: LucideIcons.clock,
        )
      else
        // The written half of the same day. It carries its own heading now
        // that the picture is above it: the graph says when, this says what,
        // and without a name between them the rows read as a caption.
        Section(
          l?.dayTimelineWhatHappenedSection ?? 'What happened',
          Surface(
            pad: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x2),
            child: Column(
              children: [
                for (final m in d.moments) MomentRow(m),
              ],
            ),
          ),
        ),
      if (d.notes.isNotEmpty)
        Section(
          l?.dayTimelineAlsoLoggedSection ?? 'Also logged on this day',
          Surface(
            pad: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x2),
            child: Column(
              children: [
                for (final n in d.notes)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: S.x3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(n.icon, size: 17, color: p.ink3),
                        const SizedBox(width: S.x3),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(n.title,
                                  style: F.body.copyWith(color: p.ink)),
                              if (n.detail.isNotEmpty)
                                Text(n.detail,
                                    style: F.cap.copyWith(color: p.ink2)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      if (d.notes.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: S.x2, left: S.x1),
          child: Text(
            l?.dayTimelineNoTimeNote ??
                'These were recorded against the day and carry no time of day, so '
                    'they are not placed on it.',
            style: F.over.copyWith(color: p.ink3, height: 1.5),
          ),
        ),
    ],
    const SizedBox(height: S.x4),
    Text(
      l?.dayTimelinePatternsNote ??
          'Patterns in your own logs, not causes. Two things next to each other '
              'here happened near each other, which is all this page claims.',
      style: F.over.copyWith(color: p.ink3, height: 1.5),
    ),
  ];
}

/// One line of the day. The time is the left column and everything aligns to
/// it, because the ONE thing this page is ordered by should be the one thing
/// you can scan.
class MomentRow extends StatelessWidget {
  const MomentRow(this.m, {super.key});
  final Moment m;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Semantics(
      label: '${clockOfTs(m.at)}, ${m.title}. ${m.detail}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Scaled with the text, not fixed: the column exists so the times
            // line up, and a hard 62 px is a clipped clock at 3.1x on exactly
            // the phones whose owners chose 3.1x.
            SizedBox(
              width: MediaQuery.textScalerOf(c).scale(58),
              child: Text(clockOfTs(m.at), style: F.n17.copyWith(color: p.ink3)),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(m.icon,
                  size: 17, color: m.color == null ? p.ink3 : p.on(m.color!)),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.title,
                    style: F.body
                        .copyWith(color: p.ink, fontWeight: FontWeight.w600),
                  ),
                  if (m.detail.isNotEmpty)
                    Text(m.detail,
                        style: F.cap.copyWith(color: p.ink2, height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
