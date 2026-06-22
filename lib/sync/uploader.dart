// Uploader — pushes unuploaded raw records + events to the backend via ApiClient
// (JWT-authenticated, per-user). The backend is idempotent on (user, device, counter),
// so re-uploading is a no-op. We send RAW hex; the backend decodes server-side.
// Local rows are deleted ONLY on a confirmed 200 (retain-until-200).

import '../data/db.dart';
import '../net/api_client.dart';

// ── Backfill-aware batch sizing ────────────────────────────────────────────────
// The steady 1 Hz trickle and the morning drain of a full night the band buffered
// while disconnected are two very different workloads. The backend rate limit counts
// per POST (30 req / 60 s / user), NOT per record, and the day-packed minute store does
// the same D1 work whatever the batch size — so a large backlog uploads in BIGGER
// batches to lift the effective record ceiling ~5× (30×300 ≈ 9k/min → 30×1500 ≈ 45k/min)
// while the trickle stays on small batches to keep payloads tiny. ~1.5k caps payload at
// a few hundred KB (well under the 100 MB Worker body limit) with CPU headroom to spare.
const int kTrickleBatch = 300;
const int kBackfillBatch = 1500;
const int kBacklogThreshold = 1000; // pending records above which we switch to backfill

/// Pick an upload batch size from the current pending-record backlog.
int batchSizeForBacklog(int pending) =>
    pending > kBacklogThreshold ? kBackfillBatch : kTrickleBatch;

class UploadResult {
  final int attempted;
  final int accepted;
  final String? error;
  UploadResult(this.attempted, this.accepted, [this.error]);
  bool get ok => error == null;
}

class Uploader {
  final ApiClient api;
  Uploader(this.api);

  /// Upload all pending raw records in batches. `onChunk` fires after each chunk
  /// is uploaded + deleted so the UI can show the pending count dropping live.
  Future<UploadResult> uploadPending(
      {int batchSize = 300, Future<void> Function()? onChunk}) async {
    int attempted = 0;
    int accepted = 0;
    while (true) {
      final batch = await LocalDb.unuploadedRaw(limit: batchSize);
      if (batch.isEmpty) break;
      attempted += batch.length;
      try {
        final body = await api.ingestBatch(batch.map((r) => r.hex).toList());
        // The backend persists every record raw (R2 = system of record) and returns
        // a count. Older builds returned no count field; fall back to the batch size
        // since a 2xx means the server received + stored them all.
        accepted += (body['received'] as int?) ??
            (body['processed'] as int?) ??
            batch.length;
        await LocalDb.markUploaded(batch.map((r) => r.hex).toList());
        if (onChunk != null) await onChunk();
      } catch (e) {
        return UploadResult(attempted, accepted, e.toString());
      }
      if (batch.length < batchSize) break;
    }
    return UploadResult(attempted, accepted);
  }

  /// Upload pending events. Same guarantee: delete locally ONLY on 200.
  Future<UploadResult> uploadEvents({int batchSize = 200}) async {
    int attempted = 0;
    int accepted = 0;
    while (true) {
      final batch = await LocalDb.unuploadedEvents(limit: batchSize);
      if (batch.isEmpty) break;
      attempted += batch.length;
      try {
        await api.ingestEvents(batch.map((e) => e['hex'] as String).toList());
        accepted += batch.length;
        await LocalDb.deleteEvents(batch.map((e) => e['hex'] as String).toList());
      } catch (e) {
        return UploadResult(attempted, accepted, e.toString());
      }
      if (batch.length < batchSize) break;
    }
    return UploadResult(attempted, accepted);
  }
}
