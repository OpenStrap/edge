// triathlon_reconciler.dart
// Post-hoc reconciliation of missed transition double-taps during a race.

import 'package:sqflite/sqflite.dart';
// Note: Assuming standard project structure for DB imports
import '../data/triathlon_store.dart'; 

class TriathlonReconciler {
  final Database db;

  TriathlonReconciler(this.db);

  /// Scans band events for missed double-tap transitions within a race.
  Future<void> reconcile(int sessionId, int startTs, int endTs) async {
    final List<Map<String, dynamic>> missedEvents = await db.query(
      'band_events',
      where: 'eventId = ? AND tsEpoch >= ? AND tsEpoch <= ?',
      whereArgs: [14, startTs, endTs], // EventId.doubleTap is 14
      orderBy: 'tsEpoch ASC',
    );

    for (final event in missedEvents) {
      final ts = event['tsEpoch'] as int;
      // Fetch segment to update
      final segs = await TriathlonDb.segments(db, sessionId.toString());
      for (final seg in segs) {
        if (ts > seg.startTs! && ts < seg.endTs!) {
           // This is a transition point within a segment.
           // In triathlon, transitions are segments.
           // Post-hoc logic: split current segment or create transition.
           // Simplification: mark as transition boundary
           final newSeg = seg.copyWith(endTs: ts, boundarySource: 'posthoc');
           await TriathlonDb.saveSegment(db, newSeg);
        }
      }
    }
  }
}
