/// Observations of the real checkpoint path. No storage, codec or resume policy
/// lives here. Counters remain zero until the GREEN implementation reports work.
class Ed2bCheckpointDiagnostics {
  bool disabled = false;
  int reads = 0;
  int writes = 0;
  int hits = 0;
  int misses = 0;
  /// Most recent refusals only; the engine lives for the whole process.
  final List<String> rejections = [];

  void reject(String reason) {
    if (rejections.length >= 32) rejections.removeAt(0);
    rejections.add(reason);
  }

  void reset() {
    reads = 0;
    writes = 0;
    hits = 0;
    misses = 0;
    rejections.clear();
  }
}
