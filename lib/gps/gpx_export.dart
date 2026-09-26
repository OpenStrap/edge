// GPX export of an already-recorded local route — for a manual upload to
// Strava (or anywhere else that reads GPX). This is NOT a Strava
// integration: no OAuth, no API call, no network I/O. It turns a
// `WorkoutRoute` this phone already recorded into a standard GPX 1.1 file
// and hands it to the OS share sheet, same as every other export in
// `lib/ui2/profile/data.dart`. The user uploads the file to Strava
// themselves.
//
// Pure string-building, no DB / no plugin — unit-testable on its own.

import 'route_models.dart';

/// Builds a GPX 1.1 document for [route]: one `<trk>` with a single
/// `<trkseg>`, one `<trkpt>` per recorded fix, elevation when known, and HR
/// as a Garmin TrackPointExtension (`gpxtpx:hr`) — the extension Strava's
/// GPX importer already reads, so heart rate survives the round trip without
/// inventing a Strava-specific format.
///
/// [name] is the activity name shown in Strava after import (e.g. "Run").
String buildGpx(WorkoutRoute route, {required String name}) {
  final hr = route.hr; // sorted by tsMs (see LocalRepositoryImpl.getWorkoutRoute)
  var hrIdx = 0;
  const hrToleranceMs = 3000;

  // One forward pass over both point-sorted lists — same shape as a merge,
  // since both are already time-ordered. Anything fancier (binary search per
  // point) buys nothing a route capped at a few hours of 1 Hz fixes needs.
  int? hrNear(int tsMs) {
    if (hr.isEmpty) return null;
    while (hrIdx + 1 < hr.length &&
        (hr[hrIdx + 1].tsMs - tsMs).abs() <= (hr[hrIdx].tsMs - tsMs).abs()) {
      hrIdx++;
    }
    return (hr[hrIdx].tsMs - tsMs).abs() <= hrToleranceMs ? hr[hrIdx].hr : null;
  }

  final buf = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<gpx version="1.1" creator="OpenStrap" '
        'xmlns="http://www.topografix.com/GPX/1/1" '
        'xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">')
    ..writeln('<trk><name>${_xmlEscape(name)}</name><trkseg>');

  for (final p in route.points) {
    // NaN.abs() > 90 is false, so a plain range check lets NaN through —
    // same bug class fixed in the HealthKit import path (#409). A point this
    // bad is dropped rather than failing the whole export.
    if (p.lat.isNaN || p.lng.isNaN || p.lat.abs() > 90 || p.lng.abs() > 180) {
      continue;
    }
    final t = DateTime.fromMillisecondsSinceEpoch(p.tsMs, isUtc: true)
        .toIso8601String();
    buf.writeln('<trkpt lat="${p.lat}" lon="${p.lng}">');
    if (p.alt != null) buf.writeln('<ele>${p.alt}</ele>');
    buf.writeln('<time>$t</time>');
    final bpm = hrNear(p.tsMs);
    if (bpm != null) {
      buf.writeln('<extensions><gpxtpx:TrackPointExtension>'
          '<gpxtpx:hr>$bpm</gpxtpx:hr>'
          '</gpxtpx:TrackPointExtension></extensions>');
    }
    buf.writeln('</trkpt>');
  }

  buf.writeln('</trkseg></trk></gpx>');
  return buf.toString();
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
