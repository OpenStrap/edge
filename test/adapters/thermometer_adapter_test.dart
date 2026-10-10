// The Health Thermometer session over a [ReplayBandLink]: what it writes to
// the thermometer, and that a reading survives the session window cancelling
// the generator before the thermometer goes quiet.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/adapter.dart';
import 'package:openstrap_edge/ble/adapters/thermometer.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

/// 36.52 °C, flags 0x00 (Celsius, no stamp, no site).
const List<int> kReading = <int>[0x00, 0x44, 0x0E, 0x00, 0xFE];

Future<void> _settle([int turns = 20]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('writes the clock only, never a Measurement Interval', () async {
    final link = ReplayBandLink();
    final adapter = ThermometerAdapter(
      nowSeconds: () => 1_800_000_000,
      firstWait: const Duration(milliseconds: 50),
    );
    await adapter.run(link).toList();
    expect(link.writes.map((w) => w.$1), [kCurrentTimeChar]);
  });

  test('a reading is yielded on arrival, before the thermometer goes quiet',
      () async {
    final link = ReplayBandLink();
    final adapter = ThermometerAdapter(
      nowSeconds: () => 1_800_000_000,
      quiet: const Duration(minutes: 1),
    );
    final events = <BandEvent>[];
    final sub = adapter.run(link).listen(events.add);
    await _settle();
    link.feed(kHtpTemperatureMeasurement, kReading, atSec: 1_800_000_000);
    await _settle();
    // Already delivered, long before `quiet` elapses: the session window can
    // end the run here and the reading is still the host's.
    final rows = [
      for (final e in events.whereType<VendorScalars>()) ...e.rows,
    ];
    expect(rows.single.value, 36.52);
    expect(events.whereType<SampleBatch>().single.raw, hasLength(1));
    // The host's teardown: close the link, then cancel.
    await link.close();
    await sub.cancel();
  });
}
