// Uploader — pushes unuploaded raw records + events to the backend via ApiClient
// (JWT-authenticated, per-user). The backend is idempotent on (user, device, counter),
// so re-uploading is a no-op. We send RAW hex; the backend decodes server-side.
// Local rows are deleted ONLY on a confirmed 200 (retain-until-200).

import '../data/db.dart';
import '../net/api_client.dart';

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
