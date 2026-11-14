// A chosen device is paired by the entry's own registered pairing when it has
// one (a ring's key exchange), else the plain pairing. Both screens go through
// pairRegisteredEntry, so a plain connect that finds a ring and retries on the
// sensor screen still reaches the ring's own pairing.
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart' show kBleHrs, kOura;
import 'package:openstrap_edge/ble/band_identity.dart' show PairOutcome;
import 'package:openstrap_edge/ui2/pairing/pair_dispatch.dart';

void main() {
  final device = BluetoothDevice.fromId('AA:BB:CC:DD:EE:01');

  test('an entry with a registered pairing uses it, not the plain one', () async {
    var picked = 0;
    var plainCalls = 0;
    final outcome = await pairRegisteredEntry(
      kOura,
      device,
      pickFor: (e) => e.id == kOura.id
          ? (d) async {
              picked++;
              return null;
            }
          : null,
      plain: (e, d, {label, earlierBand, confirmation}) async {
        plainCalls++;
        return const PairOutcome.saved();
      },
    );
    expect(picked, 1);
    expect(plainCalls, 0,
        reason: 'the ring must be proven by its own key exchange first');
    expect(outcome.saved, isTrue);
  });

  test('a registered pairing that fails reports its message and saves nothing',
      () async {
    final outcome = await pairRegisteredEntry(
      kOura,
      device,
      pickFor: (e) => (d) async => 'Wrong key',
      plain: (e, d, {label, earlierBand, confirmation}) async =>
          const PairOutcome.saved(),
    );
    expect(outcome.saved, isFalse);
    expect(outcome.error, 'Wrong key');
  });

  test('an entry with no registered pairing goes through the plain pairing',
      () async {
    var plainCalls = 0;
    final outcome = await pairRegisteredEntry(
      kBleHrs,
      device,
      label: 'Strap',
      pickFor: (e) => null,
      plain: (e, d, {label, earlierBand, confirmation}) async {
        plainCalls++;
        expect(e.id, kBleHrs.id);
        expect(label, 'Strap');
        return const PairOutcome.saved();
      },
    );
    expect(plainCalls, 1);
    expect(outcome.saved, isTrue);
  });

  test('production table: a ring has its own pairing, a chest strap does not', () {
    expect(registeredPickFor(kOura), isNotNull,
        reason: 'a ring must be paired by its own key exchange');
    expect(registeredPickFor(kBleHrs), isNull);
  });

  group('wiring (source order; these paths cannot be interleaved in a widget test)', () {
    test('both screens pair through the shared dispatch', () {
      final sensor = File('lib/ui2/profile/pair_sensor.dart').readAsStringSync();
      final picker = File('lib/ui2/pairing/device_picker.dart').readAsStringSync();
      expect(sensor, contains('await pairRegisteredEntry(entry, cand.device'),
          reason: 'a reclassified ring retried here must reach its own pairing');
      expect(picker, contains('await pairRegisteredEntry(sensor.entry, cand.device'));
    });

    test('_openEntry checks mounted before either navigation branch', () {
      final picker = File('lib/ui2/pairing/device_picker.dart').readAsStringSync();
      final start = picker.indexOf('Future<BandFlowResult> _openEntry(');
      final guard = picker.indexOf('if (!mounted) return BandFlowResult.closed;', start);
      final framed = picker.indexOf('if (entry.isFramed) {', start);
      expect(start, greaterThan(0));
      expect(guard, greaterThan(start));
      expect(guard, lessThan(framed),
          reason: 'the guard must come before the framed/unframed branches');
    });
  });
}
