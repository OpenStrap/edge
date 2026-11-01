// The scale watcher: a hit syncs the scale once and then rests; no hit, no
// paired scale, or a failing scan never syncs and never kills the loop.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/scale_presence.dart';

const _ms = Duration(milliseconds: 10);

ScalePresenceWatcher _w({
  required Map<String, String> paired,
  required Future<String?> Function() hear,
  required List<String> synced,
  Duration cooldown = const Duration(seconds: 5),
  Future<void> Function(String)? syncFn,
  Duration syncTimeout = const Duration(minutes: 2),
}) =>
    ScalePresenceWatcher(
      pairedScales: () async => paired,
      hear: (ids, window) => hear(),
      sync: syncFn ?? (id) async => synced.add(id),
      syncTimeout: syncTimeout,
      window: _ms,
      gap: _ms,
      cooldown: cooldown,
    );

void main() {
  test('a hit syncs that scale once, then the cooldown holds it back', () async {
    final synced = <String>[];
    final first = Completer<void>();
    final w = _w(
        paired: {'aa:bb': 'miscale_bc'},
        hear: () async => 'AA:BB',
        synced: synced,
        syncFn: (id) async {
          synced.add(id);
          if (!first.isCompleted) first.complete();
        });
    w.start();
    await first.future.timeout(const Duration(seconds: 2));
    // Many 10 ms gaps pass; the 5 s cooldown must hold every later hit back.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await w.stop();
    expect(synced, ['miscale_bc']);
  });

  test('nothing heard, or nothing paired: no sync, loop keeps running',
      () async {
    final synced = <String>[];
    var scans = 0;
    final w = _w(
        paired: {'aa:bb': 'miscale_bc'},
        hear: () async {
          scans++;
          return null;
        },
        synced: synced);
    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await w.stop();
    expect(synced, isEmpty);
    expect(scans, greaterThan(2));

    var scanned = false;
    final none = _w(paired: {}, hear: () async {
      scanned = true;
      return null;
    }, synced: synced);
    none.start();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await none.stop();
    expect(scanned, isFalse);
  });

  test('a scan that throws backs off for the cooldown instead of spinning',
      () async {
    var scans = 0;
    final w = _w(
        paired: {'aa:bb': 'miscale_bc'},
        hear: () async {
          scans++;
          throw StateError('bluetooth off');
        },
        synced: [],
        cooldown: const Duration(milliseconds: 60));
    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 260));
    await w.stop().timeout(const Duration(seconds: 1));
    // Retried after the cooldown (so the loop is alive), but not every 10 ms
    // gap (that would be ~25 scans).
    expect(scans, inInclusiveRange(2, 8));
  });

  test('a session that never finishes is abandoned, scanning resumes', () async {
    var scans = 0;
    final w = _w(
        paired: {'aa:bb': 'miscale_bc'},
        hear: () async {
          scans++;
          return 'aa:bb';
        },
        synced: [],
        syncFn: (_) => Completer<void>().future, // hangs forever
        syncTimeout: const Duration(milliseconds: 30),
        cooldown: const Duration(milliseconds: 40));
    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await w.stop().timeout(const Duration(seconds: 1));
    expect(scans, greaterThan(1));
  });

  test('a start() while a stopped loop is still draining restarts it, every time',
      () async {
    var scans = 0, inFlight = 0, maxInFlight = 0;
    Completer<void>? entered;
    final w = _w(
        paired: {'aa:bb': 'miscale_bc'},
        hear: () async {
          scans++;
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          if (entered?.isCompleted == false) entered!.complete();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          inFlight--;
          return null;
        },
        synced: []);
    entered = Completer<void>();
    w.start();
    w.start(); // a second start() while running must not add a second loop
    await entered.future.timeout(const Duration(seconds: 2));
    // Two stop/start rounds: a restart flag that is never cleared would show
    // up as a spurious extra loop on the second round.
    for (var round = 0; round < 2; round++) {
      final stopped = w.stop();
      w.start(); // the old scan is still in flight
      await stopped;
      final before = scans;
      entered = Completer<void>();
      await entered.future.timeout(const Duration(seconds: 2));
      expect(scans, greaterThan(before), reason: 'round $round restarted');
    }
    await w.stop();
    expect(maxInFlight, 1);
  });

  test('stop() cancels a pending restart', () async {
    var scans = 0;
    final started = Completer<void>();
    final w = _w(
        paired: {'aa:bb': 'miscale_bc'},
        hear: () async {
          scans++;
          if (!started.isCompleted) started.complete();
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return null;
        },
        synced: []);
    w.start();
    await started.future.timeout(const Duration(seconds: 2));
    final stopped = w.stop();
    w.start();
    await w.stop();
    await stopped;
    final after = scans;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(scans, after);
  });
}
