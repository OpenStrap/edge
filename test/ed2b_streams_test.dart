@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/aggregate.dart' as agg;
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/ed2b_stream_diagnostics.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/night_resp_bins.dart';

// Deliberately no fork DayCalculationState, mode or revision framework. The
// optional diagnostics observe the real upstream batch calls until GREEN.
Map<String, dynamic> _input({int beats = 950, bool gaps = false,
    bool artifacts = false}) {
  const start = 1577930400;
  final rr = <double>[], times = <double>[];
  var t = start * 1000.0;
  for (var i = 0; i < beats; i++) {
    final x = 970 + 38 * math.sin(i * .071) + 24 * math.sin(i * 1.31);
    rr.add(artifacts && i >= 430 && i < 465 ? 2400.0 : x);
    times.add(t);
    t += x;
    if (gaps && i == 510) t += 90000;
  }
  return DayBundleInput(date: '2020-01-02', dayTsSec: const [],
    dayHr: const [], sleepTsSec: const [], sleepHr: const [],
    sleepRrMs: rr, sleepRrTsMs: times, sleepSkinTemp: const [],
    sleepJson: const {}, hypnoStages: const [], sleepOnsetSec: start,
    sleepOffsetSec: t ~/ 1000 + 1, profile: const {},
    deviceFamily: 'gen4').toJson();
}

Map<String, dynamic> _prefix(Map<String, dynamic> input, int beats) => {
  ...input,
  'sleep_rr_ms': (input['sleep_rr_ms'] as List<double>).take(beats).toList(),
  'sleep_rr_ts_ms': (input['sleep_rr_ts_ms'] as List<double>).take(beats).toList(),
};

String _wire(Object? value) => jsonEncode(value);
List<double> _rr(Map<String, dynamic> x) => x['sleep_rr_ms'] as List<double>;
List<double> _times(Map<String, dynamic> x) => x['sleep_rr_ts_ms'] as List<double>;

void _near(Object? got, Object? want, [String path = r'$']) {
  if (got is num && want is num) {
    // #99 PRSA profile/capacity abs+relative 1e-9; confidence abs 1e-12.
    final tol = path.endsWith('.confidence') ? 1e-12 :
        1e-9 + 1e-9 * want.abs();
    expect((got - want).abs(), lessThanOrEqualTo(tol), reason: path);
  } else if (want is Map) {
    expect(got, isA<Map>(), reason: path);
    final g = got as Map;
    expect(g.keys.toList(), want.keys.toList(), reason: path);
    for (final k in want.keys) { _near(g[k], want[k], '$path.$k'); }
  } else if (want is List) {
    expect(got, isA<List>(), reason: path);
    final g = got as List;
    expect(g.length, want.length, reason: path);
    for (var i = 0; i < want.length; i++) { _near(g[i], want[i], '$path[$i]'); }
  } else { expect(got, want, reason: path); }
}

void _oracles(Map<String, dynamic> input, Map<String, dynamic> bundle) {
  final c = ana.correctRr(_rr(input), rrTsMs: _times(input));
  final nn = c.nn, ts = c.nnTimesMs;
  final af = (1 - c.cleanFraction).clamp(0.0, 1.0);
  final h = ana.HrvFreqStream(), r = ana.RsaRespStream(), v = ana.CvhrStream();
  for (var i = 0; i < nn.length; i += 73) {
    final end = math.min(i + 73, nn.length);
    final a = nn.sublist(i, end), b = ts.sublist(i, end);
    h.fold(a, b); r.fold(a, b); v.fold(a, b);
  }
  final clinical = bundle['clinical'] as Map;
  final respiration = bundle['respiration'] as Map;
  if (nn.length >= 20) {
    final batch = ana.hrvFreq(nn, ts, artifactFraction: af).toJson((x) => x.toJson());
    expect(_wire(h.snapshot(artifactFraction: af).toJson((x) => x.toJson())), _wire(batch));
    expect(_wire(clinical['hrv_freq']), _wire(batch));
  }
  if (nn.length >= 30) {
    final batch = ana.rsaRespRate(nn, ts, artifactFraction: af).toJson((x) => x.toJson());
    expect(_wire(r.snapshot(artifactFraction: af).toJson((x) => x.toJson())), _wire(batch));
    expect(_wire(respiration['rsa']), _wire(batch));
  }
  if (nn.length >= 60) {
    final batch = ana.cvhrApneaScreen(nn, ts, artifactFraction: af).toJson((x) => x.toJson());
    expect(_wire(v.snapshot(artifactFraction: af).toJson((x) => x.toJson())), _wire(batch));
    expect(_wire(respiration['cvhr_apnea']), _wire(batch));
    // #99 contains 914bb6a: an entirely provisional tail on a FRESH stream.
    expect(_wire(ana.CvhrStream().snapshot(tailNnMs: nn,
      tailNnTimesMs: ts, artifactFraction: af).toJson((x) => x.toJson())), _wire(batch));
  }
  for (final deceleration in [true, false]) {
    final a = agg.prsaAggregator(deceleration: deceleration);
    var state = a.empty();
    final column = agg.DoubleColumn(Float64List.fromList(nn));
    for (var i = 0; i < nn.length; i += 37) {
      state = a.addSlice(state, column, i, math.min(i + 37, nn.length));
    }
    final batch = (deceleration ? ana.decelerationCapacity(nn) :
        ana.accelerationCapacity(nn)).toJson((x) => x.toJson());
    _near(a.finish(state).toJson((x) => x.toJson()), batch);
    _near(clinical[deceleration ? 'prsa_dc' : 'prsa_ac'], batch);
  }
}

void _bundleSame(Map<String, dynamic> got, Map<String, dynamic> cold) {
  // #99 documents PRSA capacity/profile abs+relative 1e-9 and confidence
  // abs 1e-12. Every other bundle byte, including notes and absence, is exact.
  final gc = Map<String, dynamic>.from(got['clinical'] as Map);
  final cc = Map<String, dynamic>.from(cold['clinical'] as Map);
  for (final k in ['prsa_dc', 'prsa_ac']) { _near(gc.remove(k), cc.remove(k)); }
  expect(_wire({...got, 'clinical': gc}), _wire({...cold, 'clinical': cc}));
}

void _exact(Map<String, dynamic> input, Ed2bStreamDiagnostics diagnostics) {
  final cold = deriveDayBundle(input);
  final got = deriveDayBundle(input, streamDiagnostics: diagnostics);
  _bundleSame(got, cold);
  _oracles(input, got);
}

void main() {
  for (final style in ['smooth', 'gaps + capped artifact run']) {
    final input = _input(gaps: style != 'smooth', artifacts: style != 'smooth');
    test('E7 $style chunked night NN is batch-exact and folds each beat once', () {
      final d = Ed2bStreamDiagnostics();
      var observed = false;
      d.onCorrected = (nn, times, fraction) {
        observed = true;
        final c = ana.correctRr(_rr(current), rrTsMs: _times(current));
        expect(_wire(nn), _wire(c.nn)); expect(_wire(times), _wire(c.nnTimesMs));
        expect(fraction, c.cleanFraction);
      };
      // Cuts straddle the 248-beat capped corrector's provisional tail and
      // the >32 artifact run. No cut is rounded to an epoch boundary.
      for (final n in [1, 91, 247, 248, 249, 431, 464, 465, 701, 950]) {
        current = _prefix(input, n);
        _exact(current, d);
      }
      expect(observed, isTrue);
      expect(d.processedNightBeats, _rr(input).length,
          reason: 'RAM corrector must process only the appended raw beats');
      expect(d.retainedNightBeats, greaterThan(0));
      expect(d.nightRebuilds, 1);
    });

    for (final stream in ['frequency', 'rsa', 'cvhr', 'prsa', 'rsa_bins']) {
      final contract = {'frequency': 'E8', 'rsa': 'E8', 'cvhr': 'E9',
        'prsa': 'E10', 'rsa_bins': 'E10'}[stream];
      test('$contract $style $stream streams across growing and repeated passes', () {
        final d = Ed2bStreamDiagnostics();
        for (final n in [300, 641, 950]) { _exact(_prefix(input, n), d); }
        final work = d.processedBeats(stream);
        expect(work, greaterThan(0), reason: 'real metric path must be exercised');
        _exact(input, d);
        expect(d.processedBeats(stream), work,
            reason: 'repeat must reuse settled stream state');
        expect(d.retainedStreamBeats(stream), greaterThan(0));
        expect(d.streamRestarts(stream), 1);
      });
    }
  }

  for (final feature in ['rr', 'frequency', 'rsa', 'cvhr', 'prsa', 'rsa_bins']) {
    for (final key in ['input revision', 'store generation', 'algorithm']) {
      test('E7-E10 $feature refuses changed $key, equals cold, then reuses replacement', () {
        final d = Ed2bStreamDiagnostics();
        final input = _input();
        d.context(inputRevision: 1, generation: 1, algorithm: 114);
        _exact(input, d);
        final before = feature == 'rr' ? d.processedNightBeats : d.processedBeats(feature);
        d.context(inputRevision: key == 'input revision' ? 2 : 1,
          generation: key == 'store generation' ? 2 : 1,
          algorithm: key == 'algorithm' ? 115 : 114);
        _exact(input, d);
        final miss = feature == 'rr' ? d.processedNightBeats : d.processedBeats(feature);
        expect(miss, greaterThan(before), reason: 'changed context must reject retained work');
        _exact(input, d);
        expect(feature == 'rr' ? d.processedNightBeats : d.processedBeats(feature), miss,
            reason: 'the replacement context must subsequently hit');
      });
    }
  }

  for (final mutation in ['old value', 'old timestamp', 'shorter prefix', 'shifted onset']) {
    test('E7-E10 $mutation rebuilds the night and preserves every bundle byte', () {
      final d = Ed2bStreamDiagnostics();
      final input = _input(); _exact(input, d);
      final changed = _prefix(input, mutation == 'shorter prefix' ? 700 : 950);
      if (mutation == 'old value') (_rr(changed))[100] += 7;
      if (mutation == 'old timestamp') (_times(changed))[100] += .125;
      if (mutation == 'shifted onset') {
        changed['sleep_rr_ms'] = _rr(changed).sublist(10);
        changed['sleep_rr_ts_ms'] = _times(changed).sublist(10);
        changed['sleep_onset_sec'] = (changed['sleep_onset_sec'] as int) + 10;
      }
      _exact(changed, d);
      final miss = d.processedNightBeats;
      _exact(changed, d);
      expect(d.processedNightBeats, miss, reason: 'changed prefix must be retained after rebuild');
      expect(d.nightRebuilds, 2);
    });
  }

  test('E7 RAM night owner survives a real isolate hop without changed output', () async {
    final d = Ed2bStreamDiagnostics(); final input = _input();
    deriveDayBundle(input, streamDiagnostics: d);
    final before = d.processedNightBeats;
    final hopped = await Isolate.run(() {
      final bundle = deriveDayBundle(input, streamDiagnostics: d);
      return (bundle, d);
    });
    _bundleSame(hopped.$1, deriveDayBundle(input));
    expect(hopped.$2.processedNightBeats, before);
    expect(hopped.$2.retainedNightBeats, greaterThan(0));
  });

  test('guard: #99 capped RR settles and snapshots equal batch at every chunk', () {
    final input = _input(gaps: true, artifacts: true);
    final stream = ana.RrCorrector();
    final settled = <double>[], times = <double>[];
    var previous = 0;
    for (final n in [1, 91, 247, 248, 249, 431, 464, 465, 701, 950]) {
      final next = stream.fold(_rr(input).sublist(previous, n),
        tsMs: _times(input).sublist(previous, n));
      settled.addAll(next.nn); times.addAll(next.nnTimes);
      final tail = stream.snapshot();
      final batch = ana.correctRr(_rr(input).sublist(0, n),
        rrTsMs: _times(input).sublist(0, n));
      expect(_wire([...settled, ...tail.tailNn]), _wire(batch.nn));
      expect(_wire([...times, ...tail.tailNnTimes]), _wire(batch.nnTimesMs));
      previous = n;
    }
  });

  test('E11 exceptional exit releases occupied identity memo and retry is fresh', () {
    final d = Ed2bStreamDiagnostics(); final input = _input(beats: 2300);
    var digestsAtExit = 0, memoAtExit = 0;
    d.onBeforePassReturn = () {
      digestsAtExit = d.fullListDigests; memoAtExit = d.identityMemoEntries;
      throw StateError('injected after the actual analytics pass');
    };
    expect(() => deriveDayBundle(input, streamDiagnostics: d), throwsStateError);
    expect(digestsAtExit, greaterThan(0), reason: 'must exercise actual hash work before failure');
    expect(memoAtExit, greaterThan(0), reason: 'must fail while the pass owns real identity keys');
    expect(d.identityMemoEntries, 0, reason: 'finally must release lists after exceptions');
    d.onBeforePassReturn = null;
    _rr(input)[90] += 13; _exact(input, d);
    expect(d.identityMemoEntries, 0);
  });

  for (final key in ['input revision', 'generation', 'algorithm']) {
    test('E11 $key never reuses a preceding pass identity digest', () {
      final input = _input(beats: 2300), d = Ed2bStreamDiagnostics();
      d.context(inputRevision: 1, generation: 1, algorithm: 114);
      _exact(input, d); final first = d.fullListDigests;
      d.context(inputRevision: key == 'input revision' ? 2 : 1,
        generation: key == 'generation' ? 2 : 1,
        algorithm: key == 'algorithm' ? 115 : 114);
      _rr(input)[89] += 9; _exact(input, d);
      expect(d.fullListDigests, greaterThan(first));
      expect(d.maximumListDigestsPerIdentity, 1);
      expect(d.identityMemoEntries, 0);
    });
  }

  test('E10 RSA bins cross 30-minute edges; sequential PRSA is batch-toleranced', () {
    final input = _input(beats: 4000, gaps: true);
    final d = Ed2bStreamDiagnostics();
    List<double>? actualBins;
    d.onRespWindows = (rates) { actualBins = rates; };
    _exact(_prefix(input, 1861), d); _exact(input, d);
    final c = ana.correctRr(_rr(input), rrTsMs: _times(input));
    final bins = <int, (List<double>, List<double>)>{};
    for (var i = 0; i < c.nn.length; i++) {
      final key = ((c.nnTimesMs[i] - c.nnTimesMs.first) / 1800000).floor();
      final b = bins.putIfAbsent(key, () => (<double>[], <double>[]));
      b.$1.add(c.nn[i]); b.$2.add(c.nnTimesMs[i]);
    }
    final rates = <double>[];
    for (final b in bins.values) {
      if (b.$1.length < 60) continue;
      final stream = ana.RsaRespStream();
      for (var i = 0; i < b.$1.length; i += 79) {
        final end = math.min(i + 79, b.$1.length);
        stream.fold(b.$1.sublist(i, end), b.$2.sublist(i, end));
      }
      final batch = ana.rsaRespRate(b.$1, b.$2, artifactFraction: 0);
      expect(_wire(stream.snapshot(artifactFraction: 0).toJson((v) => v.toJson())),
        _wire(batch.toJson((v) => v.toJson())));
      final rate = batch.present ? batch.value!.brpm : null;
      if (rate != null) rates.add(rate);
    }
    expect(_wire(actualBins), _wire(rates));
    expect(bins.length, greaterThanOrEqualTo(3));
    expect(d.slicesProcessed('rsa_bins'), greaterThanOrEqualTo(3));
    final before = d.processedBeats('rsa_bins'); _exact(input, d);
    expect(d.processedBeats('rsa_bins'), before);
    expect(d.retainedStreamBeats('rsa_bins'), greaterThan(0));
    expect(d.retainedStreamBeats('prsa'), greaterThan(0));
  });

  test('E11 shared long night lists are hashed once each per pass and released', () {
    final d = Ed2bStreamDiagnostics(); final input = _input(beats: 2300);
    _exact(input, d);
    expect(d.fullListDigests, greaterThan(0), reason: 'real dependency proofs must be measured');
    expect(d.maximumListDigestsPerIdentity, 1);
    expect(d.identityMemoEntries, 0, reason: 'identity keys must not pin worker arrays between passes');
    final before = d.fullListDigests;
    // Reuse the SAME input identities, mutate content between passes. A digest
    // surviving endPass would conceal the changed old prefix.
    _rr(input)[100] += 11; _exact(input, d);
    expect(d.fullListDigests, greaterThan(before));
    expect(d.maximumListDigestsPerIdentity, 1); expect(d.identityMemoEntries, 0);
  });

  test('guard: diagnostics enabled or disabled never changes bundle bytes', () {
    final input = _input(gaps: true, artifacts: true);
    final d = Ed2bStreamDiagnostics()..disabled = true;
    _exact(input, d); d.disabled = false; _exact(input, d);
  });

  test('guard: empty and thin inputs preserve absence and no identity retention', () {
    for (final n in [0, 1, 19, 29, 59]) {
      final input = _input(beats: n); final d = Ed2bStreamDiagnostics();
      final got = deriveDayBundle(input, streamDiagnostics: d);
      expect(_wire(got), _wire(deriveDayBundle(input)));
      expect(d.identityMemoEntries, 0);
      if (n == 0) expect(d.processedNightBeats, 0);
    }
  });
  test('E10 closed RSA bins reapply the night artifact gate after append and JSON restart', () {
    final input = _input(beats: 6200);
    final c = ana.correctRr(_rr(input), rrTsMs: _times(input));
    final bins = NightRespBins();
    bins.fold(c.nn.sublist(0, 4000), c.nnTimesMs.sublist(0, 4000));
    List<double> batch(double artifacts) => respPerWindow(c.nn, c.nnTimesMs,
        artifactFraction: artifacts);
    // A positive control ensures the artifact gate, rather than absent signal,
    // is the only reason a high-artifact snapshot has no rates.
    expect(batch(0), isNotEmpty);
    bins.fold(c.nn.sublist(4000), c.nnTimesMs.sublist(4000));
    expect(bins.snapshot(const [], const [], artifactFraction: 0), batch(0));
    expect(batch(.5), isEmpty);
    expect(bins.snapshot(const [], const [], artifactFraction: .5), batch(.5));
    final saved = (jsonDecode(jsonEncode(bins.toJson())) as Map).cast<String, dynamic>();
    final restored = NightRespBins.fromJson(saved, c.nn.length);
    expect(restored.snapshot(const [], const [], artifactFraction: .5), batch(.5));
    expect(restored.snapshot(const [], const [], artifactFraction: 0), batch(0));
  });

}

// Assigned immediately before each synchronous derive; used only to inspect
// the callback's actual corrected arrays without adding them to output JSON.
Map<String, dynamic> current = {};
