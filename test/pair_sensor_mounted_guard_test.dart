// _pickDevice awaits the scan shutdown and then reaches code that reads
// localizations through `context`. Leaving the screen during that await
// disposes the context, so a mounted check has to sit between the two. The
// await cannot be interleaved from a widget test, so pin the order in source.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('_pickDevice checks mounted after the scan stop, before pairing', () {
    final src = File('lib/ui2/profile/pair_sensor.dart').readAsStringSync();
    final stop = src.indexOf('await HrsLink.stopScanIfRunning(this);');
    final pair = src.indexOf('await _pairPlain(device, label, earlierBand)');
    expect(stop, greaterThan(0));
    expect(pair, greaterThan(stop));
    final between = src.substring(stop, pair);
    expect(between, contains('if (!mounted) return;'),
        reason: 'a disposed screen must not read context after the scan stop');
  });
}
