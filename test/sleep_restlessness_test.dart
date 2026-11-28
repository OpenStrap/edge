import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/substrate.dart';

Substrate _sub(List<int> ts, double Function(int i) ax, double az) {
  final n = ts.length;
  return Substrate(
    tsSec: ts,
    hr: List<int>.filled(n, 55),
    rrTsMs: const [],
    rrMs: const [],
    ax: [for (var i = 0; i < n; i++) ax(i)],
    ay: List<double>.filled(n, 0.0),
    az: List<double>.filled(n, az),
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
    deviceFamily: 'gen4',
  );
}

void main() {
  const t0 = 1_700_000_100 - 1_700_000_100 % 300;

  test('a still wrist with a 1.03 g norm paints an empty map', () {
    final s = _sub([for (var i = 0; i < 1800; i++) t0 + i], (_) => 0.0, 1.03);
    final map = DerivationEngine.debugRestlessnessMap(s);
    expect(map, isNotEmpty);
    for (final b in map) {
      expect(b['density'], 0.0);
    }
  });

  test('a missing stretch breaks the still run and the bout count', () {
    // 30 still min, a moving minute, 40 unobserved min, a moving minute,
    // 30 still min.
    final ts = <int>[];
    var t = t0;
    void run(int minutes) {
      for (var i = 0; i < minutes * 60; i++) {
        ts.add(t++);
      }
    }

    run(30);
    final move1 = t;
    run(1);
    t += 40 * 60;
    final move2 = t;
    run(1);
    run(30);
    bool moving(int i) =>
        (ts[i] >= move1 && ts[i] < move1 + 60) ||
        (ts[i] >= move2 && ts[i] < move2 + 60);
    final s = _sub(ts, (i) => moving(i) && i.isOdd ? 0.6 : 0.0, 1.0);
    final r = DerivationEngine.debugRestlessness(s);
    expect(r['restless_min'], 2);
    expect(r['movement_bouts'], 2);
    expect(r['longest_still_min'], 30);

    // 20 still, 40 unobserved, 20 still: not one 40-minute stretch.
    final ts2 = [
      for (var i = 0; i < 1200; i++) t0 + i,
      for (var i = 0; i < 1200; i++) t0 + 3600 + i,
    ];
    final still = DerivationEngine.debugRestlessness(
        _sub(ts2, (_) => 0.0, 1.0));
    expect(still['longest_still_min'], 20);
  });
}
