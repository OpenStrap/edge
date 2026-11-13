// The reminder pass is serialised, and a burst of requests collapses into one
// running pass plus at most one waiting pass.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/state/coalescing_runner.dart';

void main() {
  test('requests while a run is waiting join it instead of queueing more',
      () async {
    var runs = 0;
    final gate = Completer<void>();
    final r = CoalescingRunner(() async {
      runs++;
      if (runs == 1) await gate.future;
    });

    final first = r.run(); // starts, parks on the gate
    await Future<void>.delayed(Duration.zero);
    final burst = [for (var i = 0; i < 50; i++) r.run()];
    gate.complete();
    await Future.wait([first, ...burst]);

    // One run in flight when the burst arrived, one for the whole burst.
    expect(runs, 2);
  });

  test('a request during a running pass still gets a pass that starts after it',
      () async {
    final order = <String>[];
    final gate = Completer<void>();
    var n = 0;
    final r = CoalescingRunner(() async {
      final id = ++n;
      order.add('start$id');
      if (id == 1) await gate.future;
      order.add('end$id');
    });

    final a = r.run();
    await Future<void>.delayed(Duration.zero);
    final b = r.run();
    gate.complete();
    await Future.wait([a, b]);

    expect(order, ['start1', 'end1', 'start2', 'end2']);
  });

  test('passes never overlap', () async {
    var live = 0, peak = 0;
    final r = CoalescingRunner(() async {
      peak = ++live > peak ? live : peak;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      live--;
    });
    await Future.wait([for (var i = 0; i < 20; i++) r.run()]);
    expect(peak, 1);
  });

  test('a failing pass does not stop later ones', () async {
    var n = 0;
    final r = CoalescingRunner(() async {
      if (++n == 1) throw StateError('boom');
    });
    await expectLater(r.run(), throwsStateError);
    await r.run();
    expect(n, 2);
  });
}
