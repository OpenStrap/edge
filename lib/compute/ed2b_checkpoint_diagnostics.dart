import 'dart:typed_data';

/// Observations of the real checkpoint path. No storage, codec or resume policy
/// lives here. Counters remain zero until the GREEN implementation reports work.
class Ed2bCheckpointDiagnostics {
  bool disabled = false;
  int reads = 0;
  int writes = 0;
  int hits = 0;
  int misses = 0;
  final List<String> rejections = [];
  Uint8List? lastEncodedPayload;
  Map<String, Object?>? lastDecodedPayload;

  void reset() {
    reads = 0;
    writes = 0;
    hits = 0;
    misses = 0;
    rejections.clear();
    lastEncodedPayload = null;
    lastDecodedPayload = null;
  }
}
