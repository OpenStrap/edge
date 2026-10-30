// The scale watcher: a hit syncs the scale once and then rests; no hit, no
// paired scale, or a failing scan never syncs and never kills the loop.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/scale_presence.dart';

const _ms = Duration(milliseconds: 10);

ScalePresenceWatcher _w({
  required Map<String, String> paired,
  required Future<String?> Function() hear,
  required List<String> synced,
  Duration cooldown = const Duration(seconds: 5),
  bool Function()? bandWaiting,
}) =>
    ScalePresenceWatcher(
      pairedScales: () async => paired,
      hear: (ids, window) => hear(),
      sync: (id) async => synced.add(id),
      window: _ms,
      gap: _ms,
      cooldown: cooldown,
      bandWaiting: bandWaiting,
    );

void main() {
  test('a hit syncs that scale once, then the cooldown holds it back', () async {
    final synced = <String>[];
    final w = _w(
        paired: {'aa:bb': 'miscale_bc'},
        hear: () async => 'AA:BB',
        synced: synced);
    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
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
        cooldown: const Duration(seconds: 5));
    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await w.stop().timeout(const Duration(seconds: 1));
    expect(scans, 1);
  });

  test('a band waiting to reconnect: no scale scan at all', () async {
    var scans = 0;
    final w = _w(
        paired: {'aa:bb': 'miscale_bc'},
        hear: () async {
          scans++;
          return 'aa:bb';
        },
        synced: [],
        bandWaiting: () => true);
    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await w.stop();
    expect(scans, 0);
  });
}
