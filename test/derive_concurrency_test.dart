// runWithConcurrency: the bounded worker-pool primitive that replaced the
// fully-sequential per-day `for` loops in DerivationEngine.run()/runDays()/
// rescanRecent(). A multi-day backlog sweep used to process one day fully
// (isolate spawns + compute) before starting the next, leaving every core
// but one idle. This pool lets several days' isolate work run genuinely
// concurrently across cores, with a continuous work-queue (not fixed
// batches) so a mix of fast/slow days keeps every lane busy.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';

void main() {
  group('runWithConcurrency', () {
    test('empty items resolves immediately, worker never called', () async {
      var calls = 0;
      await runWithConcurrency<int>(const [], 3, (item) async {
        calls++;
      });
      expect(calls, 0);
    });

    test('every item is processed exactly once, regardless of concurrency',
        () async {
      final items = List.generate(10, (i) => i);
      final seen = <int>[];
      await runWithConcurrency<int>(items, 3, (item) async {
        seen.add(item);
      });
      seen.sort();
      expect(seen, items);
    });

    test('concurrency=1 behaves like a plain sequential loop', () async {
      final items = [1, 2, 3, 4];
      final completionOrder = <int>[];
      await runWithConcurrency<int>(items, 1, (item) async {
        // Even with an artificial delay, concurrency=1 means strict
        // one-at-a-time — completion order must match input order exactly.
        await Future<void>.delayed(Duration.zero);
        completionOrder.add(item);
      });
      expect(completionOrder, items);
    });

    test('a concurrency higher than the item count is clamped harmlessly',
        () async {
      final items = [1, 2];
      var calls = 0;
      await runWithConcurrency<int>(items, 50, (item) async {
        calls++;
      });
      expect(calls, 2); // never spawns more lanes than items
    });

    test(
        'the first `concurrency` items start WITHOUT waiting for earlier ones '
        'to finish — real parallelism, not fixed lock-step batches', () async {
      // 3 items, concurrency=3, each holds until released — if they were
      // sequential, item 1 would never even start until item 0's gate opens.
      // With true concurrency, all 3 start immediately.
      final gates = List.generate(3, (_) => Completer<void>());
      final started = <int>[];
      final done = runWithConcurrency<int>(
        [0, 1, 2],
        3,
        (item) async {
          started.add(item);
          await gates[item].future;
        },
      );
      // Give the event loop a beat to let all 3 lanes actually start.
      await Future<void>.delayed(Duration.zero);
      expect(started.toSet(), {0, 1, 2}); // all three in flight simultaneously
      for (final g in gates) {
        g.complete();
      }
      await done;
    });

    test(
        'a slow first item does NOT block a fast later item from finishing '
        'first (continuous queue, not fixed batches)', () async {
      final finishOrder = <int>[];
      final slowGate = Completer<void>();
      final done = runWithConcurrency<int>(
        [0, 1],
        2,
        (item) async {
          if (item == 0) {
            await slowGate.future; // item 0 is slow
          }
          finishOrder.add(item);
        },
      );
      // Item 1 should complete well before item 0's gate ever opens.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(finishOrder, [1]);
      slowGate.complete();
      await done;
      expect(finishOrder, [1, 0]);
    });

    test('a free lane immediately picks up the next queued item', () async {
      // concurrency=1 over 3 items where each takes a beat — the single lane
      // must move on to the next item as soon as the current one resolves,
      // without any gap requiring external re-triggering.
      final order = <int>[];
      await runWithConcurrency<int>([10, 20, 30], 1, (item) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        order.add(item);
      });
      expect(order, [10, 20, 30]);
    });
  });
}
