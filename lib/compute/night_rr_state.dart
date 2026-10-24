import 'dart:collection';
import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart' as ana;

typedef NightRr = ({List<double> nn, List<double> nnTimesMs,
  double cleanFraction, int droppedCount, int correctedCount});
typedef NightListProof = ({int beats, int times, (int, int) nn, (int, int) ts});

NightRr nightRrBatch(List<double> rr, List<double> times) {
  final c = ana.correctRr(rr, rrTsMs: times);
  return (nn: c.nn, nnTimesMs: c.nnTimesMs, cleanFraction: c.cleanFraction,
    droppedCount: c.droppedCount, correctedCount: c.correctedCount);
}

/// One RAM night, copied into a worker and returned with its result. Raw
/// prefix copies prove append-only input; settled output is never re-corrected.
class NightRrState {
  static const maxRetainedBeats = 200000;
  ana.RrCorrector? _corrector;
  final List<double> _rr = [], _times = [], _nn = [], _nnTimes = [];
  (int, int, int)? _context;
  (String, int)? _night;
  final _memos = <String, ({Object dependencies, Object? value})>{};
  final _digests = _PassListDigests();
  int processedNightBeats = 0, nightRebuilds = 0;

  int get retainedNightBeats => _rr.length;
  int get settledNightBeats => _nn.length;
  int get identityMemoEntries => _digests.entries;
  int get fullListDigests => _digests.computed;
  int get maximumListDigestsPerIdentity => _digests.maximumPerIdentity;

  void beginPass() => _digests.clear();
  void endPass() => _digests.clear();

  void context({required int inputRevision, required int generation,
      required int algorithm}) {
    final next = (inputRevision, generation, algorithm);
    if (_context != next) clear();
    _context = next;
  }

  void clear() {
    _resetNight();
    _digests.clear();
  }

  void _resetNight() {
    _corrector = null;
    _rr.clear(); _times.clear(); _nn.clear(); _nnTimes.clear();
    _night = null;
    _memos.clear();
  }

  /// Shared by the night metric memos. No digest outlives this pass's
  /// identities; only its integer words may be kept as a dependency proof.
  NightListProof dependencyProof(List<double> nn, List<double> times) =>
      (beats: nn.length, times: times.length,
        nn: _digests.digest(nn), ts: _digests.digest(times));

  NightRr correct(List<double> rr, List<double> times,
      {required String day, required int onsetSec}) {
    final night = (day, onsetSec);
    var held = _rr.length;
    var extendsPrefix = _night == night && rr.length >= held &&
        times.length == rr.length;
    for (var i = 0; extendsPrefix && i < held; i++) {
      extendsPrefix = identical(rr[i], _rr[i]) && identical(times[i], _times[i]);
    }
    if (!extendsPrefix) {
      _resetNight();
      held = 0;
    }
    // Keep malformed/oversized input on the unchanged batch path. Eviction
    // affects work only, never absence rules or numeric output.
    if (rr.isEmpty || times.length != rr.length ||
        rr.length > maxRetainedBeats) {
      _resetNight();
      processedNightBeats += rr.length;
      return nightRrBatch(rr, times);
    }
    _night = night;
    if (_corrector == null) nightRebuilds++;
    final corrector = _corrector ??= ana.RrCorrector();
    if (rr.length > held) {
      final addRr = held == 0 ? rr : rr.sublist(held);
      final addTimes = held == 0 ? times : times.sublist(held);
      final ana.RrSettled settled;
      try {
        settled = corrector.fold(addRr, tsMs: addTimes);
      } on ArgumentError {
        _resetNight();
        processedNightBeats += rr.length;
        return nightRrBatch(rr, times);
      }
      processedNightBeats += addRr.length;
      _rr.addAll(addRr); _times.addAll(addTimes);
      _nn.addAll(settled.nn); _nnTimes.addAll(settled.nnTimes);
    }
    final tail = corrector.snapshot();
    return (nn: [..._nn, ...tail.tailNn],
      nnTimesMs: [..._nnTimes, ...tail.tailNnTimes],
      cleanFraction: tail.cleanFraction, droppedCount: tail.droppedCount,
      correctedCount: tail.correctedCount);
  }

  /// Exact batch-result reuse. Growing lists still run the ordinary batch
  /// consumers; incremental metric streams are a separate adoption step.
  T memo<T>(String key, Object dependencies, T Function() compute) {
    if (_corrector == null) return compute();
    final old = _memos[key];
    if (old != null && old.dependencies == dependencies) return old.value as T;
    final result = compute();
    if (!_memos.containsKey(key) && _memos.length >= 8) {
      _memos.remove(_memos.keys.first);
    }
    _memos[key] = (dependencies: dependencies, value: result);
    return result;
  }
}

/// Short window lists are walked directly. Only long shared lists occupy
/// identity keys, and the pipeline releases all keys in finally.
class _PassListDigests {
  final HashMap<List<double>, (int, int, int, int)> _byList = HashMap.identity();
  final _bits = ByteData(8);
  int computed = 0, maximumPerIdentity = 0;
  int get entries => _byList.length;
  void clear() => _byList.clear();

  (int, int) digest(List<double> list) {
    final hit = _byList[list];
    if (hit != null && hit.$1 == list.length) return (hit.$2, hit.$3);
    var a = 0x243f6a8885a308d3, b = 0x13198a2e03707344;
    for (final value in list) {
      _bits.setFloat64(0, value);
      final word = _bits.getInt64(0);
      a = _mix(a + word + 0x9e3779b97f4a7c15);
      b = _mix((b ^ word) * 0xd6e8feb86659fd93 + 0x632be59bd9b4e019);
    }
    computed++;
    final count = (hit?.$4 ?? 0) + 1;
    if (count > maximumPerIdentity) maximumPerIdentity = count;
    if (list.length >= 2048) _byList[list] = (list.length, a, b, count);
    return (a, b);
  }

  static int _mix(int z) {
    z = (z ^ (z >>> 30)) * 0xbf58476d1ce4e5b9;
    z = (z ^ (z >>> 27)) * 0x94d049bb133111eb;
    return z ^ (z >>> 31);
  }
}
