import 'dart:convert';

enum ActivityKind { nap, workout }

enum ActivityReviewStatus { pending, confirmed, discarded, superseded }

/// Durable proposal, separate from the sleep and workout records it may create.
class ActivitySuggestion {
  const ActivitySuggestion({
    required this.id,
    required this.kind,
    required this.startTs,
    required this.endTs,
    required this.revision,
    this.status = ActivityReviewStatus.pending,
    this.details = const {},
  });

  final String id;
  final ActivityKind kind;
  final int startTs, endTs, revision;
  final ActivityReviewStatus status;
  final Map<String, dynamic> details;
  int get durationMin => ((endTs - startTs) / 60).round();
  String? get sport => details['sport'] as String?;

  factory ActivitySuggestion.fromRow(Map<String, dynamic> row) =>
      ActivitySuggestion(
        id: row['id'] as String,
        kind: ActivityKind.values.byName(row['kind'] as String),
        startTs: (row['start_ts'] as num).toInt(),
        endTs: (row['end_ts'] as num).toInt(),
        revision: (row['revision'] as num).toInt(),
        status: ActivityReviewStatus.values.byName(row['status'] as String),
        details: Map<String, dynamic>.from(
          jsonDecode(row['details_json'] as String) as Map,
        ),
      );
}

class ActivityReviewException implements Exception {
  const ActivityReviewException(this.message);
  final String message;
  @override
  String toString() => message;
}
