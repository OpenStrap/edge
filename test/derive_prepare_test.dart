import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/substrate.dart';

void main() {
  test(
    'prepareDerivationPayload can filter a multi-day substrate to one target day',
    () {
      final start =
          DateTime(2026, 6, 26, 23, 55).millisecondsSinceEpoch ~/ 1000;
      final end = DateTime(2026, 6, 27, 0, 5).millisecondsSinceEpoch ~/ 1000;
      final ts = <int>[];
      final hr = <int>[];
      final ax = <double>[];
      final ay = <double>[];
      final az = <double>[];
      for (var t = start; t <= end; t++) {
        ts.add(t);
        hr.add(60);
        ax.add(0);
        ay.add(0);
        az.add(1);
      }
      final sub = Substrate(
        tsSec: ts,
        hr: hr,
        rrTsMs: const [],
        rrMs: const [],
        ax: ax,
        ay: ay,
        az: az,
        spo2Red: List<int>.filled(ts.length, 0),
        spo2Ir: List<int>.filled(ts.length, 0),
        skinTemp: List<int>.filled(ts.length, 0),
      );

      final all = prepareDerivationPayload(sub);
      expect(all.days.map((d) => d.date).toList(), [
        '2026-06-26',
        '2026-06-27',
      ]);

      final one = prepareDerivationPayload(sub, targetDay: '2026-06-27');
      expect(one.days, hasLength(1));
      expect(one.days.first.date, '2026-06-27');
      expect(one.dataNowSec, sub.lastTs);
    },
  );

  test('prepareDerivationPayload returns empty when target day is absent', () {
    final start = DateTime(2026, 6, 27, 10).millisecondsSinceEpoch ~/ 1000;
    final ts = List<int>.generate(601, (i) => start + i);
    final sub = Substrate(
      tsSec: ts,
      hr: List<int>.filled(ts.length, 60),
      rrTsMs: const [],
      rrMs: const [],
      ax: List<double>.filled(ts.length, 0),
      ay: List<double>.filled(ts.length, 0),
      az: List<double>.filled(ts.length, 1),
      spo2Red: List<int>.filled(ts.length, 0),
      spo2Ir: List<int>.filled(ts.length, 0),
      skinTemp: List<int>.filled(ts.length, 0),
    );

    final none = prepareDerivationPayload(sub, targetDay: '2026-06-28');
    expect(none.days, isEmpty);
  });
}
