import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/sleep_pipeline_hmm.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  hmmPipelineMain();
  reviewFixesMain();
  test('Arousals do not trigger a full cycle reset and maintain stage continuity', () {
    final analyzer = SleepStageAnalyzer();

    // Baseline erzeugen (HR ~ 60, RMSSD ~ 40)
    final baseline = List.generate(240, (i) => {'hr': 60.0, 'rmssd': 40.0});
    analyzer.computeBaseline(baseline);

    // Testsequenz: Deep Sleep -> Kurzes Arousal (Wake) -> Deep Sleep
    final nightData = <Map<String, dynamic>>[];
    
    // Block 1: Stable Deep Sleep
    nightData.addAll(List.generate(20, (i) => {'hr': 55.0, 'rmssd': 50.0}));
    
    // Block 2: Short Arousal (1 Epoche)
    nightData.add({'hr': 80.0, 'rmssd': 20.0});
    
    // Block 3: Return to Deep Sleep
    nightData.addAll(List.generate(20, (i) => {'hr': 55.0, 'rmssd': 50.0}));

    final states = analyzer.viterbiDecode(nightData);

    // Erwartung: Nach dem Arousal kehrt das System direkt wieder zu NREM Deep zurück,
    // ohne stundenlang in NREM Light "festzustecken".
    expect(states[19], SleepState.nremDeep);
    expect(states[21], SleepState.nremDeep);
  });

  group('observations the decoder cannot trust', () {
    SleepStageAnalyzer baselined() {
      final a = SleepStageAnalyzer();
      a.computeBaseline(List.generate(240, (_) => {'hr': 60.0, 'rmssd': 40.0}));
      return a;
    }

    List<Map<String, dynamic>> deepAround(List<Map<String, dynamic>> middle) => [
          ...List.generate(20, (_) => <String, dynamic>{'hr': 55.0, 'rmssd': 50.0}),
          ...middle,
          ...List.generate(20, (_) => <String, dynamic>{'hr': 55.0, 'rmssd': 50.0}),
        ];

    test('a contact-lost stretch is bridged, not scored as wake', () {
      final night = deepAround(List.generate(
          10, (_) => <String, dynamic>{'hr': 95.0, 'rmssd': 12.0, 'isContactLost': true}));
      final states = baselined().viterbiDecode(night);
      for (var t = 20; t < 30; t++) {
        expect(states[t], SleepState.nremDeep, reason: 'epoch $t');
      }
    });

    test('implausible and non-finite HR get the neutral emission', () {
      for (final bad in [250.0, double.nan, double.infinity]) {
        final night = deepAround(
            List.generate(10, (_) => <String, dynamic>{'hr': bad, 'rmssd': 12.0}));
        final states = baselined().viterbiDecode(night);
        for (var t = 20; t < 30; t++) {
          expect(states[t], SleepState.nremDeep, reason: 'hr=$bad epoch $t');
        }
      }
    });

    test('the same values without the flag still read as wake', () {
      final night = deepAround(
          List.generate(10, (_) => <String, dynamic>{'hr': 95.0, 'rmssd': 12.0}));
      final states = baselined().viterbiDecode(night);
      expect(states[25], SleepState.wake);
    });

    test('baseline skips missing and non-finite values instead of throwing', () {
      final a = SleepStageAnalyzer();
      a.computeBaseline([
        {'hr': null, 'rmssd': 40.0},
        {'rmssd': 40.0},
        {'hr': double.nan, 'rmssd': double.nan},
        ...List.generate(20, (_) => <String, dynamic>{'hr': 60.0, 'rmssd': 40.0}),
      ]);
      expect(a.hrMinNight, 60.0);
      expect(a.rmssdMeanNight, 40.0);
    });
  });
}

/// The opt-in path through [deriveDayBundle]: a quiet first half and an
/// aroused second half must re-stage (the decoder actually ran on epoch-aligned
/// beats), and a second the band did not watch stays unobserved.
void hmmPipelineMain() {
  test('opt-in HMM re-stages a measured night and keeps unobserved seconds', () {
    const t0 = 1780000000;
    const n = 4 * 3600;
    final tsSec = [for (var s = 0; s < n; s++) t0 + s];
    final hr = [for (var s = 0; s < n; s++) s < n ~/ 2 ? 55 : 80];
    final rrTs = <double>[], rrMs = <double>[];
    var t = t0 * 1000.0;
    var i = 0;
    while (t < (t0 + n) * 1000.0) {
      final aroused = t >= (t0 + n ~/ 2) * 1000.0;
      final rr = aroused
          ? 750.0 + 2.0 * ((i % 3) - 1)
          : 1090.0 + 40.0 * ((i % 5) - 2);
      t += rr;
      rrTs.add(t);
      rrMs.add(rr);
      i++;
    }
    final stages = List<String>.filled(n, 'light');
    for (var s = 100; s < 160; s++) {
      stages[s] = 'unobserved';
    }
    Map<String, dynamic> run(bool hmm) => deriveDayBundle(DayBundleInput(
          date: '2026-06-01',
          dayTsSec: tsSec,
          dayHr: hr,
          sleepTsSec: tsSec,
          sleepHr: hr,
          sleepRrTsMs: rrTs,
          sleepRrMs: rrMs,
          sleepSkinTemp: List<int>.filled(n, 0),
          sleepJson: const {},
          hypnoStages: stages,
          sleepOnsetSec: t0,
          sleepOffsetSec: t0 + n,
          profile: const {'age': 30, 'sex': 'm', 'weight': 75, 'height': 178},
          useHmmStages: hmm,
        ).toJson());
    List<String> seq(Map<String, dynamic> b) => [
          for (final s in ((b['series'] as Map)['hypnogram'] as List).cast<Map>())
            s['stage'] as String,
        ];
    expect(seq(run(false)).toSet(), {'light', 'unobserved'});
    final on = seq(run(true));
    expect(on, contains('unobserved'));
    expect(on.toSet().difference({'light', 'unobserved'}), isNotEmpty);
  });
}

/// A 4 h night: a quiet first half and an aroused second half, beats for the
/// whole night unless [rrFromSec] starts them later, and substrate rows
/// missing over [gap] (seconds into the night) when given.
const _t0 = 1780000000;
const _n = 4 * 3600;

DayBundleInput _night({
  int rrFromSec = 0,
  (int, int)? gap,
  Map<String, dynamic> sleepJson = const {},
  List<String>? stages,
  bool hmm = true,
}) {
  bool missing(int s) => gap != null && s >= gap.$1 && s < gap.$2;
  final tsSec = [
    for (var s = 0; s < _n; s++)
      if (!missing(s)) _t0 + s
  ];
  final hr = [for (final t in tsSec) t - _t0 < _n ~/ 2 ? 55 : 80];
  final rrTs = <double>[], rrMs = <double>[];
  var t = (_t0 + rrFromSec) * 1000.0;
  var i = 0;
  while (t < (_t0 + _n) * 1000.0) {
    final aroused = t >= (_t0 + _n ~/ 2) * 1000.0;
    final rr = aroused
        ? 750.0 + 2.0 * ((i % 3) - 1)
        : 1090.0 + 40.0 * ((i % 5) - 2);
    t += rr;
    if (!missing(t ~/ 1000 - _t0)) {
      rrTs.add(t);
      rrMs.add(rr);
    }
    i++;
  }
  return DayBundleInput(
    date: '2026-06-01',
    dayTsSec: tsSec,
    dayHr: hr,
    sleepTsSec: tsSec,
    sleepHr: hr,
    sleepRrTsMs: rrTs,
    sleepRrMs: rrMs,
    sleepSkinTemp: List<int>.filled(tsSec.length, 0),
    sleepJson: sleepJson,
    hypnoStages: stages ?? List<String>.filled(_n, 'light'),
    sleepOnsetSec: _t0,
    sleepOffsetSec: _t0 + _n,
    profile: const {'age': 30, 'sex': 'm', 'weight': 75, 'height': 178},
    useHmmStages: hmm,
  );
}

/// The stored per-second labels, expanded back from the hypnogram segments.
List<String> _labels(Map<String, dynamic> bundle) {
  final out = List<String>.filled(_n, '?');
  for (final seg
      in ((bundle['series'] as Map)['hypnogram'] as List).cast<Map>()) {
    for (var t = seg['start'] as int; t < (seg['end'] as int); t++) {
      out[t - _t0] = seg['stage'] as String;
    }
  }
  return out;
}

class _RefusingStore extends SharedPreferencesStorePlatform {
  @override
  Future<bool> clear() async => false;
  @override
  Future<Map<String, Object>> getAll() async => {};
  @override
  Future<bool> remove(String key) async => false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

void reviewFixesMain() {
  group('PR #628 review', () {
    test('no RMSSD baseline in the first 120 min keeps the shipped labels', () {
      // Beats only from minute 150: the baseline window holds none, so every
      // emission would be neutral and the decoder would read wake.
      final b = deriveDayBundle(_night(rrFromSec: 150 * 60).toJson());
      expect(_labels(b).toSet(), {'light'});
      expect((b['sleep'] as Map).containsKey('stager_source'), isFalse);
    });

    test('a gap in the substrate is placed by clock, and its epochs abstain',
        () {
      // 20 minutes with no rows inside the quiet half. Paired by row index the
      // lengths no longer matched and the night was silently never re-staged.
      final b = deriveDayBundle(_night(gap: (1800, 3000)).toJson());
      final l = _labels(b);
      expect(l.toSet().difference({'light'}), isNotEmpty,
          reason: 'a sparse night is re-staged');
      // No heart rate, no beats: those epochs keep the shipped label.
      for (var s = 1830; s < 2970; s++) {
        expect(l[s], 'light', reason: 'second $s has no observation');
      }
      // And the aroused half is still where the clock says it is.
      expect(l.sublist(_n ~/ 2 + 600).where((x) => x == 'wake').length,
          greaterThan((_n ~/ 2 - 600) * 0.8));
      expect(l.sublist(600, 1800).where((x) => x == 'wake'), isEmpty);
    });

    test('the night\'s accounting comes from the new labels, tagged hmm', () {
      final stages = List<String>.filled(_n, 'light');
      for (var s = 100; s < 160; s++) {
        stages[s] = 'unobserved';
      }
      final b = deriveDayBundle(_night(
        stages: stages,
        sleepJson: const {
          'window': {'onset_ms': 0},
          'tst_sec': _n - 60,
          'waso_sec': 0,
          'in_bed_sec': _n,
          'unobserved_sec': 60,
          'efficiency_pct': 100.0,
          'nrem_sec': _n - 60,
          'light_sec': _n - 60,
          'deep_sec': 0,
          'rem_sec': 0,
          'wake_sec': 0,
          'confidence': 0.8,
        },
      ).toJson());
      final sleep = b['sleep'] as Map;
      expect(sleep['stager_source'], 'hmm');
      final acc = (sleep['accounting'] as Map)['value'] as Map;
      final l = _labels(b);
      int count(Set<String> s) => l.where(s.contains).length;
      final tst = count({'light', 'deep', 'rem'});
      expect(acc['tst_sec'], tst);
      expect(acc['wake_sec'], count({'wake'}));
      expect(acc['light_sec'] + acc['deep_sec'] + acc['rem_sec'], tst);
      expect(acc['efficiency_pct'], closeTo(100.0 * tst / (_n - 60), 1e-9),
          reason: 'not the original stager\'s 100 %');
      expect(acc['efficiency_pct'], lessThan(100.0));
    });

    test('switch off: the bundle is exactly what it was', () {
      final b = deriveDayBundle(_night(hmm: false).toJson());
      expect(_labels(b).toSet(), {'light'});
      expect((b['sleep'] as Map).containsKey('stager_source'), isFalse);
    });

    test('no decode ever yields NaN or an infinite score', () {
      final a = SleepStageAnalyzer()
        ..computeBaseline([
          for (var i = 0; i < 50; i++) {'hr': 60.0, 'rmssd': 40.0}
        ]);
      // REM straight into a deep-looking stretch: the forbidden move.
      final states = a.viterbiDecode([
        for (var i = 0; i < 20; i++) {'hr': 66.0, 'rmssd': 44.0},
        for (var i = 0; i < 20; i++) {'hr': 50.0, 'rmssd': 60.0},
        for (var i = 0; i < 5; i++) {'hr': double.nan, 'rmssd': double.infinity},
      ]);
      expect(states, hasLength(45));
      for (var t = 1; t < states.length; t++) {
        expect(
            states[t - 1] == SleepState.rem && states[t] == SleepState.nremDeep,
            isFalse,
            reason: 'epoch $t');
      }
    });

    test('a refused pref write leaves the switch showing what the engine reads',
        () async {
      SharedPreferences.setMockInitialValues({});
      final real = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance = _RefusingStore();
      SharedPreferences.resetStatic();
      addTearDown(() {
        SharedPreferencesStorePlatform.instance = real;
        SharedPreferences.resetStatic();
      });
      final app = AppState.forTesting();
      addTearDown(app.dispose);
      expect(await app.setSleepHmmStages(true), isFalse);
      expect(app.sleepHmmStagesEnabled, isFalse);
    });
  });
}
