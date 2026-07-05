// Value types for the on-device GPS route feature (run / ride / walk).
//
// LOCAL-FIRST: every point here is recorded on this phone, stored only in the
// local `workout_route` table, and NEVER uploaded anywhere. There is no cloud
// route service and no network I/O in this feature.
//
// These are plain, dependency-light models (only latlong2 for the map point
// type) so the pure route math in route_math.dart stays unit-testable without
// pulling in geolocator or the DB.

import 'package:latlong2/latlong.dart';

/// One raw GPS fix from the location stream, mapped off the platform Position.
class GpsSample {
  final double lat;
  final double lng;
  final double? alt;
  final double? accuracy; // horizontal accuracy in metres (smaller = better)
  final int tsMs; // epoch milliseconds

  const GpsSample({
    required this.lat,
    required this.lng,
    this.alt,
    this.accuracy,
    required this.tsMs,
  });
}

/// A persisted route point, one row of `workout_route`.
class RoutePoint {
  final int seq; // monotonically increasing within a session
  final int tsMs; // epoch milliseconds
  final double lat;
  final double lng;
  final double? alt;
  final double? accuracy;

  const RoutePoint({
    required this.seq,
    required this.tsMs,
    required this.lat,
    required this.lng,
    this.alt,
    this.accuracy,
  });

  LatLng get latLng => LatLng(lat, lng);

  /// A DB row for `workout_route` (session_id is supplied at write time).
  Map<String, Object?> toRow(String sessionId) => {
        'session_id': sessionId,
        'seq': seq,
        'ts_ms': tsMs,
        'lat': lat,
        'lng': lng,
        'alt': alt,
        'accuracy': accuracy,
      };

  factory RoutePoint.fromRow(Map<String, Object?> r) => RoutePoint(
        seq: (r['seq'] as num).toInt(),
        tsMs: (r['ts_ms'] as num).toInt(),
        lat: (r['lat'] as num).toDouble(),
        lng: (r['lng'] as num).toDouble(),
        alt: (r['alt'] as num?)?.toDouble(),
        accuracy: (r['accuracy'] as num?)?.toDouble(),
      );
}

/// A 1 Hz heart-rate sample (from the decoded_onehz substrate), used to colour
/// the route and to compute each split's average HR.
class HrSample {
  final int tsMs; // epoch milliseconds
  final int hr; // bpm

  const HrSample({required this.tsMs, required this.hr});
}

/// A map vertex: a position plus the HR zone (0..5) in effect there, or null
/// when no HR sample was near it (drawn in a neutral colour).
class RouteVertex {
  final LatLng pos;
  final int? zone;

  /// True when this vertex starts a NEW segment after a recording gap (signal
  /// loss / screen-off pause). The map breaks the polyline here instead of
  /// drawing a straight line across the gap.
  final bool gapBefore;

  const RouteVertex(this.pos, this.zone, {this.gapBefore = false});
}

/// One distance split (per km or per mi, depending on the chosen unit).
class Split {
  final int index; // 1-based
  final double meters; // distance covered in this split (< unit on the last)
  final int durationSec;
  final double? avgHr; // null when no HR samples fell in this split

  const Split({
    required this.index,
    required this.meters,
    required this.durationSec,
    this.avgHr,
  });

  /// Seconds per full unit (km or mi) — the split's pace. `unitMeters` is the
  /// length of a whole unit (1000 for km, 1609.344 for mi).
  double paceSecPerUnit(double unitMeters) =>
      meters <= 0 ? double.infinity : durationSec / (meters / unitMeters);
}

/// Everything the UI needs to render a workout's route: the raw points, the HR
/// samples over the session window (for zone colouring), the total distance and
/// moving time, and both km and mi splits (the UI picks by user unit).
class WorkoutRoute {
  final String sessionId;
  final List<RoutePoint> points;
  final List<HrSample> hr;
  final double distanceMeters;
  final int movingSec;
  final List<Split> splitsKm;
  final List<Split> splitsMi;

  const WorkoutRoute({
    required this.sessionId,
    required this.points,
    required this.hr,
    required this.distanceMeters,
    required this.movingSec,
    required this.splitsKm,
    required this.splitsMi,
  });

  /// A drawable route needs at least a segment.
  bool get hasPath => points.length >= 2;
}
