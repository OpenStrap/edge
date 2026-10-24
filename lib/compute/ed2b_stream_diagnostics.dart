import 'night_rr_state.dart';

// Work is counted beside the real owner and the remaining batch metric calls.
class Ed2bStreamDiagnostics {
  int passes = 0;
  NightRrState nightState = NightRrState();
  int get processedNightBeats => nightState.processedNightBeats;
  int get nightRebuilds => nightState.nightRebuilds;
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
      required int algorithm}) => nightState.context(inputRevision: inputRevision,
        generation: generation, algorithm: algorithm);
  // Total input work: GREEN counts only newly appended/settled beats here,
  // regardless of whether the operation uses a batch call or an addSlice.
  int get retainedNightBeats => nightState.retainedNightBeats;
  int get settledNightBeats => nightState.settledNightBeats;
  int get identityMemoEntries => nightState.identityMemoEntries;
  int get fullListDigests => nightState.fullListDigests;
  int get maximumListDigestsPerIdentity => nightState.maximumListDigestsPerIdentity;
  int retainedStreamBeats(String stream) => nightState.retainedStreamBeats(stream);
  int processedBeats(String stream) => nightState.processedBeats(stream) +
      (_batchBeats[stream] ?? 0);
  int slicesProcessed(String stream) => nightState.slicesProcessed(stream) +
      (_batchCalls[stream] ?? 0);
  int streamRestarts(String stream) => nightState.streamRestarts(stream);

  void observeNightCorrection(int rawBeats, List<double> nn,
      List<double> times, double cleanFraction) {
    onCorrected?.call(nn, times, cleanFraction);
  }

  void observeBatch(String stream, int beats) {
    _batchCalls[stream] = (_batchCalls[stream] ?? 0) + 1;
    _batchBeats[stream] = (_batchBeats[stream] ?? 0) + beats;
  }
}
