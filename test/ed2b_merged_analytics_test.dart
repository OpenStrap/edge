import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/ed2b_stream_diagnostics.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/cardio_rows_cache.dart';
import 'package:openstrap_edge/compute/night_rr_state.dart';

void main() {
  // WHY: a capped reset can put corrected NN behind its previous segment even
  // with ordered raw timestamps. Merged batch RSA/CVHR abstain; their streams
  // throw on that clock. One absent metric must not abort the whole day.
  // Proves CLAIM(merged-clock-refusal).
  // Catches: feeding a regressing corrected clock into retained RSA/CVHR.
  test('merged clock refusals preserve a complete day and retained frequency', () {
    const start = 1577930400;
    double wobble(int i) => 1500.0 + (i % 7) * 12 - (i % 3) * 9;
    // Analytics test/output_changes/review_inputs_test.dart's capped-reset
    // fixture: 400 good beats, 33 artifacts, 400 good beats at 1.4 s cadence.
    final rr = [for (var i = 0; i < 400; i++) wobble(i),
      ...List<double>.filled(33, 3000),
      for (var i = 0; i < 400; i++) wobble(i)];
    final times = [for (var i = 0; i < rr.length; i++) start * 1000.0 + i * 1400];
    final diagnostics = Ed2bStreamDiagnostics();
    List<double>? windows;
    diagnostics.onRespWindows = (rates) => windows = rates;
    for (final count in [400, 650, 833]) {
      final input = DayBundleInput(date: '2020-01-02', dayTsSec: const [],
        dayHr: const [], sleepTsSec: const [], sleepHr: const [],
        sleepRrMs: rr.sublist(0, count), sleepRrTsMs: times.sublist(0, count),
        sleepSkinTemp: const [], sleepJson: const {}, hypnoStages: const [],
        sleepOnsetSec: start, sleepOffsetSec: start + 1200,
        profile: const {}, deviceFamily: 'gen4').toJson();
      final cold = deriveDayBundle(input);
      final retained = deriveDayBundle(input, streamDiagnostics: diagnostics);
      final respiration = retained['respiration'] as Map;
      expect(respiration['rsa'], (cold['respiration'] as Map)['rsa']);
      expect(respiration['cvhr_apnea'], (cold['respiration'] as Map)['cvhr_apnea']);
      expect((retained['clinical'] as Map)['hrv_freq'],
          (cold['clinical'] as Map)['hrv_freq']);
      if (count == 833) {
        for (final key in ['rsa', 'cvhr_apnea']) {
          expect((respiration[key] as Map)['value'], '—');
          expect((respiration[key] as Map)['note'], 'regressing beat time');
        }
        final frequency = (retained['clinical'] as Map)['hrv_freq'] as Map;
        expect(frequency['value'], isA<Map>());
        expect(frequency['note'], contains('left out'));
        final c = ana.correctRr(rr, rrTsMs: times);
        expect(windows, respPerWindow(c.nn, c.nnTimesMs,
            artifactFraction: 1 - c.cleanFraction));
        // Cutting this prefix would otherwise try to fold the earlier valid
        // RSA stream under the now-invalid clock.
        expect(diagnostics.nightState.checkpoint(start + 900), isNull);
      }
    }
    expect(diagnostics.processedNightBeats, rr.length);
    expect(diagnostics.streamRestarts('frequency'), 1);
    expect(diagnostics.retainedStreamBeats('frequency'), greaterThan(0));
    // Check that the fixture still exercises a real corrected-clock regression.
    final corrected = ana.correctRr(rr, rrTsMs: times);
    expect([for (var i = 1; i < corrected.nnTimesMs.length; i++)
      corrected.nnTimesMs[i] < corrected.nnTimesMs[i - 1]], contains(true));
  });
  // WHY: analytics main changed codec policy. Old reusable work must cost a
  // cold calculation, never load a result derived under the old pin.
  for (final codec in ['frequency v1', 'PRSA without policy']) {
    test('merged night checkpoint refuses $codec', () {
      final state = NightRrState();
      final rr = List<double>.filled(500, 950);
      final times = [for (var i = 0; i < rr.length; i++) 1000000.0 + i * 950];
      state.correct(rr, times, day: '2020-01-02', onsetSec: 1000);
      state.nightHrvFreq(0);
      state.nightPrsa();
      final checkpoint = jsonDecode(jsonEncode(state.checkpoint(2000))) as Map;
      expect(NightRrState.fromCheckpoint(
          checkpoint.cast<String, dynamic>(), 2000).retainedNightBeats, 500);
      if (codec == 'frequency v1') {
        final frequency = checkpoint['frequency'] as Map;
        frequency['version'] = 1;
        frequency.remove('dropped');
      } else {
        // PRSA's lookback inner now binds direction and anchor-ratio cap.
        final dc = (checkpoint['prsa'] as Map)['dc'] as List;
        final policy = (dc[1] as Map)['inner'] as Map;
        policy.remove('deceleration');
        policy.remove('anchorRatioCap');
      }
      expect(() => NightRrState.fromCheckpoint(
          checkpoint.cast<String, dynamic>(), 2000), throwsFormatException);
    });
  }

  // WHY: old word-wise fingerprints could alias after sign-bit changes.
  // The merged codec invalidates those rows so staging rebuilds them.
  test('merged cardio codec treats a v2 chunk as a cold miss', () {
    final cache = ana.CardioRowCache()..insert(
        const ana.CardioRowKey(1000, 30, 42),
        const ana.CardioEpochRow(0, 60, 1, 20, 1, .5, 30));
    final json = cache.toJson();
    final current = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    expect(decodeCardioRows([current]).length, 1);
    json['version'] = 2;
    expect(() => ana.CardioRowCache.fromJson(json), throwsFormatException);
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    expect(decodeCardioRows([bytes]).length, 0);
  });
}
