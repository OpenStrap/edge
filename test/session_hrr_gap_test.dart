// A saved session's HRR used to be taken at the first sample after its end,
// however far past the end that was. With the strap back on a minute after
// stopping, the "peak" was the HR at that moment and the drop from it was
// published as recovery.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/substrate.dart';

const int _end = 1786700000;

Substrate _sub({required int resumeAfter}) {
  final ts = <int>[], hr = <int>[];
  for (var t = _end - 600; t < _end; t++) {
    ts.add(t);
    hr.add(160);
  }
  for (var t = _end + resumeAfter; t <= _end + 180; t++) {
    ts.add(t);
    // Falling from 140 at the resume second.
    hr.add(140 - ((t - _end - resumeAfter) ~/ 2));
  }
  final n = ts.length;
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: const [],
    rrMs: const [],
    ax: List<double>.filled(n, 0),
    ay: List<double>.filled(n, 0),
    az: List<double>.filled(n, 1),
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
  );
}

void main() {
  test('no HRR when recording resumed well after the session end', () {
    final r = DerivationEngine.debugHrrForBout(_sub(resumeAfter: 60), _end);
    expect(r.hrrBpm, isNull);
    expect(r.tauSec, isNull);
  });

  test('a contiguous tail still scores', () {
    final r = DerivationEngine.debugHrrForBout(_sub(resumeAfter: 0), _end);
    expect(r.hrrBpm, isNotNull);
  });
}
