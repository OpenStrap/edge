// TCX (TrainingCenterDatabase v2) writer for a saved workout: one Activity,
// one Lap, one Track. HR-only (indoor) workouts get trackpoints with time +
// HeartRateBpm and no Position. Pure string building; reused by intervals.icu
// upload and the Strava file upload.

import '../data/db.dart';
import '../gps/route_models.dart';

class TcxHr {
  final DateTime time;
  final int bpm;
  const TcxHr(this.time, this.bpm);
}

class TcxPoint {
  final DateTime time;
  final double lat, lon;
  final double? alt;
  const TcxPoint(this.time, this.lat, this.lon, [this.alt]);
}

class TcxActivity {
  /// TCX Sport: `Running`, `Biking` or `Other`.
  final String sport;
  final DateTime start;
  final int durationSec;
  final double? distanceM;
  final int? calories;
  final List<TcxHr> hr;
  final List<TcxPoint> gps;
  const TcxActivity({
    required this.sport,
    required this.start,
    required this.durationSec,
    this.distanceM,
    this.calories,
    this.hr = const [],
    this.gps = const [],
  });
}

/// App `sessions.type` key to TCX Sport.
String tcxSport(String type) {
  if (type.contains('running') || type == 'run') return 'Running';
  if (type.contains('cycling') || type.contains('biking') || type.contains('bike') || type == 'cycle') return 'Biking';
  return 'Other';
}

String _t(DateTime d) => d.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

String buildTcx(TcxActivity a) {
  final start = a.start.toUtc();
  // Trackpoints: GPS fixes (each with the nearest HR within 3 s) when there
  // is a route, otherwise one point per HR sample.
  final pts = <(DateTime, int?, TcxPoint?)>[];
  final hr = [...a.hr]..sort((x, y) => x.time.compareTo(y.time));
  if (a.gps.isNotEmpty) {
    var i = 0;
    for (final p in a.gps) {
      int? bpm;
      if (hr.isNotEmpty) {
        while (i + 1 < hr.length &&
            (hr[i + 1].time.difference(p.time)).abs() <= (hr[i].time.difference(p.time)).abs()) {
          i++;
        }
        if (hr[i].time.difference(p.time).abs().inSeconds <= 3) bpm = hr[i].bpm;
      }
      pts.add((p.time, bpm, p));
    }
    // Heart rate where the route has no fix (GPS lost under cover, or a
    // route that only covers part of the session) stays in as HR-only points.
    final fixes = a.gps.map((p) => p.time).toList()..sort();
    var j = 0;
    for (final h in hr) {
      while (j + 1 < fixes.length && fixes[j + 1].isBefore(h.time)) {
        j++;
      }
      final near = [fixes[j], if (j + 1 < fixes.length) fixes[j + 1]]
          .any((t) => t.difference(h.time).abs().inSeconds <= 3);
      if (!near) pts.add((h.time, h.bpm, null));
    }
    pts.sort((x, y) => x.$1.compareTo(y.$1));
  } else {
    for (final h in hr) {
      pts.add((h.time, h.bpm, null));
    }
  }

  final hrs = [for (final h in hr) h.bpm];
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<TrainingCenterDatabase '
        'xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">')
    ..writeln('<Activities><Activity Sport="${a.sport}">')
    ..writeln('<Id>${_t(start)}</Id>')
    ..writeln('<Lap StartTime="${_t(start)}">')
    ..writeln('<TotalTimeSeconds>${a.durationSec}</TotalTimeSeconds>')
    ..writeln('<DistanceMeters>${(a.distanceM ?? 0).toStringAsFixed(1)}</DistanceMeters>');
  // Calories is left out when unknown rather than written as a made-up 0;
  // importers accept a lap without it.
  if (a.calories != null) b.writeln('<Calories>${a.calories}</Calories>');
  if (hrs.isNotEmpty) {
    final avg = (hrs.reduce((x, y) => x + y) / hrs.length).round();
    b.writeln('<AverageHeartRateBpm><Value>$avg</Value></AverageHeartRateBpm>');
    b.writeln('<MaximumHeartRateBpm><Value>${hrs.reduce((x, y) => x > y ? x : y)}</Value></MaximumHeartRateBpm>');
  }
  b
    ..writeln('<Intensity>Active</Intensity>')
    ..writeln('<TriggerMethod>Manual</TriggerMethod>')
    ..writeln('<Track>');
  for (final (time, bpm, p) in pts) {
    b.write('<Trackpoint><Time>${_t(time)}</Time>');
    if (p != null) {
      b.write('<Position><LatitudeDegrees>${p.lat}</LatitudeDegrees>'
          '<LongitudeDegrees>${p.lon}</LongitudeDegrees></Position>');
      if (p.alt != null) b.write('<AltitudeMeters>${p.alt}</AltitudeMeters>');
    }
    if (bpm != null) b.write('<HeartRateBpm><Value>$bpm</Value></HeartRateBpm>');
    b.writeln('</Trackpoint>');
  }
  b
    ..writeln('</Track>')
    ..writeln('</Lap>')
    ..writeln('</Activity></Activities>')
    ..writeln('</TrainingCenterDatabase>');
  return b.toString();
}

/// Loads a saved session (string id, as in `sessions.id`) as a [TcxActivity]:
/// HR from `decoded_onehz`, route from `workout_route`. Null when the session
/// is missing, unfinished, or has neither HR nor GPS to write.
// ponytail: HR comes from decoded_onehz, which is pruned a few days after the
// day is derived, so an old workout uploads route-only or not at all. Fall
// back to the day bundle's hr_curve if people post old sessions.
Future<TcxActivity?> tcxActivityForSession(
  String id, {
  Future<WorkoutRoute?> Function(String id)? routeOf,
}) async {
  final s = await LocalDb.session(id);
  final st = (s?['start_ts'] as num?)?.toInt();
  final en = (s?['end_ts'] as num?)?.toInt();
  if (s == null || st == null || en == null || en <= st) return null;
  final rows = await LocalDb.hrSamplesInRange(st, en);
  final hr = [
    for (final r in rows)
      TcxHr(DateTime.fromMillisecondsSinceEpoch((r['rec_ts'] as num).toInt() * 1000, isUtc: true),
          (r['hr'] as num).toInt()),
  ];
  final route = routeOf == null ? null : await routeOf(id);
  final gps = [
    for (final p in route?.points ?? const <RoutePoint>[])
      if (!p.lat.isNaN && !p.lng.isNaN && p.lat.abs() <= 90 && p.lng.abs() <= 180)
        TcxPoint(DateTime.fromMillisecondsSinceEpoch(p.tsMs, isUtc: true), p.lat, p.lng, p.alt),
  ];
  if (hr.isEmpty && gps.isEmpty) return null;
  return TcxActivity(
    sport: tcxSport((s['type'] as String?) ?? 'other'),
    start: DateTime.fromMillisecondsSinceEpoch(st * 1000, isUtc: true),
    durationSec: en - st,
    distanceM: route?.distanceMeters,
    calories: (s['calories'] as num?)?.round(),
    hr: hr,
    gps: gps,
  );
}
