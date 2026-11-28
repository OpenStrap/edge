// An early bedtime (20:00) is still going at the day's midnight cut. The day
// that ends at midnight must not publish a truncated night ending at 00:00;
// only the next day, which sees the wake, owns it.
//
// Fixed local `DateTime(...)` literals, never `DateTime.now()`.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/substrate.dart';

int _local(int y, int mo, int d, [int h = 0, int mi = 0]) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

Substrate _build(int start, int n, bool Function(int t) asleepAt) {
  final ts = <int>[], hr = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  for (var i = 0; i < n; i++) {
    final t = start + i;
    final asleep = asleepAt(t);
    ts.add(t);
    hr.add(asleep ? 50 : 72);
    if (asleep) {
      ax.add(0.0);
      ay.add(0.0);
      az.add(1.0);
    } else {
      final rad = (i % 9) * 10.0 * math.pi / 180.0;
      ax.add(math.cos(rad));
      ay.add(0.0);
      az.add(math.sin(rad));
    }
  }
  return Substrate(
    tsSec: ts,
    hr: hr,
    rrTsMs: const [],
    rrMs: const [],
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 0),
    skinContact: List<int>.filled(n, 0),
  );
}

void main() {
  test('a night still going at midnight is owned only by the day it ends in',
      () {
    final start = _local(2025, 6, 15, 12);
    final bed = _local(2025, 6, 15, 20);
    final wake = _local(2025, 6, 16, 6);
    final end = _local(2025, 6, 16, 11);
    final days = calendarDays(
        _build(start, end - start, (t) => t >= bed && t < wake));

    final slept = days.where((d) => d.sleep.present).toList();
    expect(slept, hasLength(1));
    final night = slept.single;
    expect(night.date, '2025-06-16');
    final onSec = night.sleep.window!.onsetMs! ~/ 1000;
    final offSec = night.sleep.window!.offsetMs! ~/ 1000;
    expect((onSec - bed).abs(), lessThan(3600));
    expect((offSec - wake).abs(), lessThan(3600));
  });
}
