// ED-2b RED observations only. This object retains no analytics state and never
// changes a result. Work is counted beside the existing batch calls. GREEN can
// replace those calls with streams while preserving these measurement meanings.
class Ed2bStreamDiagnostics {
  int passes = 0;
  int processedNightBeats = 0;
  int nightRebuilds = 0;
  final Map<String, int> _batchBeats = {};
  final Map<String, int> _batchCalls = {};
  bool disabled = false;
  void Function(List<double> nn, List<double> times, double cleanFraction)?
      onCorrected;
  void Function()? onBeforePassReturn;
  void Function(List<double>)? onRespWindows;

  void beginPass() { passes++; }
  void endPass() { onBeforePassReturn?.call(); }
  void context({required int inputRevision, required int generation,
      required int algorithm}) {} // RED: no retained state to invalidate.
  // Total input work: GREEN counts only newly appended/settled beats here,
  // regardless of whether the operation uses a batch call or an addSlice.
  int get retainedNightBeats => 0;
  int get settledNightBeats => 0;
  int get identityMemoEntries => 0;
  int get fullListDigests => 0;
  int get maximumListDigestsPerIdentity => 0;
  int retainedStreamBeats(String stream) => 0;
  int processedBeats(String stream) => _batchBeats[stream] ?? 0;
  int slicesProcessed(String stream) => _batchCalls[stream] ?? 0;
  int streamRestarts(String stream) => 0;

  void observeNightCorrection(int rawBeats, List<double> nn,
      List<double> times, double cleanFraction) {
    processedNightBeats += rawBeats;
    if (rawBeats > 0) nightRebuilds++;
    onCorrected?.call(nn, times, cleanFraction);
  }

  void observeBatch(String stream, int beats) {
    _batchCalls[stream] = slicesProcessed(stream) + 1;
    _batchBeats[stream] = processedBeats(stream) + beats;
  }
}
