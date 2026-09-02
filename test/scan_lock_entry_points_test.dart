// M0 §4.4: structural gate for `withScanLock`'s entry points. The realistic
// violation is a ninth call site added six months from now, outside every
// lock -- exactly the bug this milestone fixed at
// lib/ui2/profile/pair_sensor.dart (spec-m0-m2.md §4).
//
// Only two files may call FlutterBluePlus.startScan/stopScan or read
// isScanning directly: lib/ble/ble_engine.dart and lib/ble/hrs_link.dart,
// both of which route every call through withScanLock. Every other file must
// go through HrsLink's public API (`scanFor`, `stopScanIfRunning`) or
// BleEngine's.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _allowlist = {'lib/ble/ble_engine.dart', 'lib/ble/hrs_link.dart'};

final _pureComment = RegExp(r'^\s*(///|//|\*|/\*)');

void main() {
  final dartFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('FlutterBluePlus.(start|stop)Scan is only ever called from the '
      'allowlisted BLE files', () {
    final pattern = RegExp(r'FlutterBluePlus\.(start|stop)Scan');
    final offenders = <String>[];
    for (final f in dartFiles) {
      final rel = f.path.replaceFirst(RegExp(r'^\./'), '');
      if (_allowlist.contains(rel)) continue;
      for (final line in f.readAsStringSync().split('\n')) {
        if (_pureComment.hasMatch(line)) continue;
        if (pattern.hasMatch(line)) offenders.add('$rel: $line');
      }
    }
    expect(offenders, isEmpty,
        reason: 'a new scan entry point must go through withScanLock via '
            'BleEngine or HrsLink, not call FlutterBluePlus directly:\n'
            '${offenders.join('\n')}');
  });

  test('FlutterBluePlus.isScanning is only ever read from the allowlisted '
      'BLE files', () {
    // The real hazard: a new file awaiting `isScanning == false` OUTSIDE the
    // lock, which is exactly the shape of bug #8 this milestone fixed.
    final pattern = RegExp(r'FlutterBluePlus\.isScanning');
    final offenders = <String>[];
    for (final f in dartFiles) {
      final rel = f.path.replaceFirst(RegExp(r'^\./'), '');
      if (_allowlist.contains(rel)) continue;
      for (final line in f.readAsStringSync().split('\n')) {
        if (_pureComment.hasMatch(line)) continue;
        if (pattern.hasMatch(line)) offenders.add('$rel: $line');
      }
    }
    expect(offenders, isEmpty,
        reason: 'a new file reading isScanning outside withScanLock:\n'
            '${offenders.join('\n')}');
  });
}
