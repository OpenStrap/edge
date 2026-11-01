import 'dart:collection';
import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart' as ana;

import 'night_prsa.dart';
import 'night_resp_bins.dart';

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
  NightRrState();
  static const maxRetainedBeats = 200000;
  ana.RrCorrector? _corrector;
  final List<double> _rr = [], _times = [], _nn = [], _nnTimes = [];
  (int, int, int)? _context;
  (String, int)? _night;
  final _memos = <String, ({Object dependencies, Object? value})>{};
  final _digests = _PassListDigests();
  List<double> _tailNn = const [], _tailTimes = const [];
  ana.HrvFreqStream? _frequency;
  ana.RsaRespStream? _rsa;
  ana.CvhrStream? _cvhr;
  NightPrsa? _prsa;
  NightRespBins? _rsaBins;
  final Map<String, int> _fed = {}, _processed = {}, _slices = {}, _restarts = {};
  int processedNightBeats = 0, nightRebuilds = 0;

  bool get canStream => _corrector != null;
  // Settled beats represented by each stream, including compacted summaries.
  int retainedStreamBeats(String key) => _fed[key] ?? 0;
  int processedBeats(String key) => _processed[key] ?? 0;
  int slicesProcessed(String key) => _slices[key] ?? 0;
  int streamRestarts(String key) => _restarts[key] ?? 0;
  int get retainedNightBeats => _rr.length;
  int get settledNightBeats => _nn.length;
  int get identityMemoEntries => _digests.entries;
  int get fullListDigests => _digests.computed;
  int get maximumListDigestsPerIdentity => _digests.maximumPerIdentity;

  // A cleared owner still records its algorithm. A transition must rebuild;
  // only a fresh owner or a same-algorithm restart may adopt disk state.
  bool acceptsCheckpointAlgorithm(int algorithm) =>
      _context == null || _context!.$3 == algorithm;

  bool acceptsPrefix(List<double> rr, List<double> times, String day, int onset) {
    if (_night != (day, onset) || rr.length < _rr.length ||
        rr.length != times.length) {
      return false;
    }
    for (var i = 0; i < _rr.length; i++) {
      if (!identical(rr[i], _rr[i]) || !identical(times[i], _times[i])) {
        return false;
      }
    }
    return true;
  }

  bool acceptsSearchPrefix(List<double> rr, List<double> times, String day) {
    if (_night?.$1 != day || rr.length != times.length || _times.isEmpty) {
      return false;
    }
    var start = 0;
    while (start < times.length && times[start] < _times.first) { start++; }
    if (start + _rr.length > rr.length) return false;
    for (var i = 0; i < _rr.length; i++) {
      if (!identical(rr[start + i], _rr[i]) || !identical(times[start + i], _times[i])) {
        return false;
      }
    }
    return true;
  }

  void bindRestoredContext(int revision, int generation, int algorithm,
      {NightRrState? previous}) {
    _context = (revision, generation, algorithm);
    // Disk state carries no work counters. Adopting it after clearing a RAM
    // owner must preserve that owner's cumulative observations.
    if (previous == null) return;
    processedNightBeats = previous.processedNightBeats;
    nightRebuilds = previous.nightRebuilds;
    _processed.addAll(previous._processed);
    _slices.addAll(previous._slices);
    _restarts.addAll(previous._restarts);
    _digests.computed = previous._digests.computed;
    _digests.maximumPerIdentity = previous._digests.maximumPerIdentity;
  }

  /// Worker only. A checkpoint stops before the closed input boundary. Cutting
  /// a live tail requires a separate fold; it must never rewind the live owner.
  Map<String, dynamic>? checkpoint(int boundary) {
    if (_corrector == null || _night == null) return null;
    var n = 0;
    while (n < _times.length && _times[n] < boundary * 1000) { n++; }
    if (n == 0) return null;
    final NightRrState state;
    if (n == _rr.length) {
      state = this;
    } else {
      state = NightRrState();
      state.correct(_rr.sublist(0, n), _times.sublist(0, n),
          day: _night!.$1, onsetSec: _night!.$2);
      if (_frequency != null) {
        final stream = state._frequency = ana.HrvFreqStream();
        state._feed('frequency', (nn, ts) { stream.fold(nn, ts); return 1; });
      }
      if (_rsa != null) {
        final stream = state._rsa = ana.RsaRespStream();
        state._feed('rsa', (nn, ts) { stream.fold(nn, ts); return 1; });
      }
      if (_cvhr != null) {
        final stream = state._cvhr = ana.CvhrStream();
        state._feed('cvhr', (nn, ts) { stream.fold(nn, ts); return 1; });
      }
      if (_prsa != null) {
        final stream = state._prsa = NightPrsa();
        state._feed('prsa', (nn, ts) { stream.fold(nn); return 1; });
      }
      if (_rsaBins != null) {
        final stream = state._rsaBins = NightRespBins();
        state._feed('rsa_bins', stream.fold);
      }
    }
    return {
      'v': 1, 'tag': {'day': state._night!.$1, 'onset': state._night!.$2,
        'count': state._rr.length},
      'rr': state._rr, 'times': state._times,
      'corrector': state._corrector!.toJson(),
      'nn': state._nn, 'nnTimes': state._nnTimes, 'fed': state._fed,
      'frequency': state._frequency?.toJson(), 'rsa': state._rsa?.toJson(),
      'cvhr': state._cvhr?.toJson(), 'prsa': state._prsa?.toJson(),
      'rsa_bins': state._rsaBins?.toJson(),
    };
  }

  factory NightRrState.fromCheckpoint(Map<String, dynamic> json, int boundary) {
    List<double> doubles(Object? v) {
      final list = (v as List).map((x) => (x as num).toDouble()).toList();
      if (list.length > maxRetainedBeats || list.any((x) => !x.isFinite)) {
        throw const FormatException('night column');
      }
      return list;
    }
    final tag = json['tag'] as Map;
    final rr = doubles(json['rr']), times = doubles(json['times']);
    final nn = doubles(json['nn']), nnTimes = doubles(json['nnTimes']);
    final correctorJson = (json['corrector'] as Map).cast<String, dynamic>();
    final count = correctorJson['maxArtifactRun'] == null
        ? correctorJson['n'] : (correctorJson['capped'] as Map)['n'];
    if (json['v'] != 1 || tag['day'] is! String || tag['onset'] is! int ||
        rr.isEmpty || rr.length != times.length || rr.length != tag['count'] ||
        count != rr.length || nn.length != nnTimes.length || nn.length > rr.length ||
        times.any((t) => t >= boundary * 1000) ||
        correctorJson['maxArtifactRun'] != 32 || correctorJson['alpha'] != 5.2 ||
        correctorJson['windowBeats'] != 91 || correctorJson['minThresholdMs'] != 100 ||
        correctorJson['reanchorGapMs'] != 1000) {
      throw const FormatException('night shape/count');
    }
    for (var i = 1; i < times.length; i++) {
      if (times[i] < times[i - 1]) throw const FormatException('night times');
    }
    for (var i = 1; i < nnTimes.length; i++) {
      if (nnTimes[i] < nnTimes[i - 1]) throw const FormatException('NN times');
    }
    final state = NightRrState()
      .._night = (tag['day'] as String, tag['onset'] as int)
      .._corrector = ana.RrCorrector.fromJson(correctorJson)
      .._rr.addAll(rr).._times.addAll(times).._nn.addAll(nn).._nnTimes.addAll(nnTimes);
    final fed = (json['fed'] as Map).cast<String, int>();
    const keys = ['frequency', 'rsa', 'cvhr', 'prsa', 'rsa_bins'];
    if (fed.keys.any((k) => !keys.contains(k))) {
      throw const FormatException('night stream key');
    }
    for (final key in keys) {
      final data = json[key];
      if (data == null) {
        if (fed.containsKey(key)) throw const FormatException('missing stream');
        continue;
      }
      if (fed[key] != nn.length) throw const FormatException('stream feed count');
      final map = (data as Map).cast<String, dynamic>();
      if (key == 'prsa') {
        state._prsa = NightPrsa.fromJson(map, fed[key]!);
      } else if (key == 'rsa_bins') {
        state._rsaBins = NightRespBins.fromJson(map, fed[key]!);
      } else {
        if (map['n'] != fed[key]) throw const FormatException('stream count');
        if (key == 'frequency' && map['oversample'] != 4.0) {
          throw const FormatException('frequency config');
        }
        if (key == 'cvhr') {
          final defaults = ana.CvhrStream().toJson();
          for (final name in ['minWidthSec', 'maxWidthSec', 'depthWidthRatioMin',
              'envWindowSec', 'maxGapSec']) {
            if (map[name] != defaults[name]) throw const FormatException('CVHR config');
          }
        }
        if (key == 'frequency') state._frequency = ana.HrvFreqStream.fromJson(map);
        if (key == 'rsa') state._rsa = ana.RsaRespStream.fromJson(map);
        if (key == 'cvhr') state._cvhr = ana.CvhrStream.fromJson(map);
      }
    }
    state._fed.addAll(fed);
    return state;
  }

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
    _tailNn = const []; _tailTimes = const [];
    _frequency = null; _rsa = null; _cvhr = null;
    _prsa = null; _rsaBins = null;
    _fed.clear();
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
    _tailNn = tail.tailNn; _tailTimes = tail.tailNnTimes;
    return (nn: [..._nn, ...tail.tailNn],
      nnTimesMs: [..._nnTimes, ...tail.tailNnTimes],
      cleanFraction: tail.cleanFraction, droppedCount: tail.droppedCount,
      correctedCount: tail.correctedCount);
  }

  /// Exact result reuse. Growing lists snapshot incremental metric streams;
  /// unchanged lists also avoid re-evaluating their provisional tails.
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

  void _feed(String key, int Function(List<double>, List<double>) fold) {
    final held = _fed[key] ?? 0;
    if (!_fed.containsKey(key)) {
      _restarts[key] = streamRestarts(key) + 1;
      _fed[key] = 0;
    }
    if (held == _nn.length) return;
    final slices = fold(_nn.sublist(held), _nnTimes.sublist(held));
    _processed[key] = processedBeats(key) + _nn.length - held;
    _slices[key] = slicesProcessed(key) + slices;
    _fed[key] = _nn.length;
  }

  ana.Metric<ana.HrvFreq> nightHrvFreq(double artifactFraction) {
    final stream = _frequency ??= ana.HrvFreqStream();
    _feed('frequency', (nn, times) { stream.fold(nn, times); return 1; });
    return stream.snapshot(tailNnMs: _tailNn, tailNnTimesMs: _tailTimes,
        artifactFraction: artifactFraction);
  }

  ana.Metric<ana.RespEstimate> nightResp(double artifactFraction) {
    final stream = _rsa ??= ana.RsaRespStream();
    _feed('rsa', (nn, times) { stream.fold(nn, times); return 1; });
    return stream.snapshot(tailNnMs: _tailNn, tailNnTimesMs: _tailTimes,
        artifactFraction: artifactFraction);
  }

  ana.Metric<ana.CvhrResult> nightCvhr(double artifactFraction) {
    final stream = _cvhr ??= ana.CvhrStream();
    _feed('cvhr', (nn, times) { stream.fold(nn, times); return 1; });
    // #99 handles a fresh stream's entirely provisional night too.
    return stream.snapshot(tailNnMs: _tailNn, tailNnTimesMs: _tailTimes,
        artifactFraction: artifactFraction);
  }

  (ana.Metric<ana.PrsaResult>, ana.Metric<ana.PrsaResult>) nightPrsa() {
    final stream = _prsa ??= NightPrsa();
    _feed('prsa', (nn, times) { stream.fold(nn); return 1; });
    return stream.snapshot(_tailNn);
  }

  List<double> nightRespWindows(double artifactFraction) {
    final stream = _rsaBins ??= NightRespBins();
    _feed('rsa_bins', stream.fold);
    return stream.snapshot(_tailNn, _tailTimes, artifactFraction: artifactFraction);
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
