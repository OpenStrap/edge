// Device role: which registry entries can be the user's main device.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';

void main() {
  test('standard heart-rate service does not imply a chest strap', () {
    // WHY: the same service is advertised by watches and armbands.
    expect(kBleHrs.kind, DeviceKind.other);
  });

  test('the sensor set is exactly ble_hrs, polar_pmd, thermometer, scales', () {
    // WHY: workout add-ons and scales must never be offered as the main device.
    final sensors = {
      for (final e in kBandRegistry)
        if (e.role == DeviceRole.sensor) e.id,
    };
    expect(sensors,
        {'ble_hrs', 'polar_pmd', 'thermometer', 'miscale_bc', 'miscale2'});
  });

  test('every other entry is a band, including both WHOOPs', () {
    // WHY: the WHOOP bug was a band filed as a sensor; bands must stay bands.
    expect(kWhoopGen4.role, DeviceRole.band);
    expect(kWhoopGen5.role, DeviceRole.band);
    final bands = {
      for (final e in kBandRegistry)
        if (e.role == DeviceRole.band) e.id,
    };
    expect(bands, {
      'gen4', 'gen5', 'oura', 'coros', 'ultrahuman', 'miband234', 'pebble',
      'colmi', 'garmin',
    });
  });

  test('recognised as a band is not the same as can be the main device', () {
    // WHY: Coros and Garmin must trip the "this is a band" safeguard, but have
    // no supported main-device path, so the first-run list must not offer them.
    for (final e in [kWhoopGen4, kWhoopGen5]) {
      expect(e.role, DeviceRole.band, reason: e.id);
      expect(e.canBeMainDevice, isTrue, reason: e.id);
    }
    for (final e in [kCoros, kGarmin]) {
      expect(e.role, DeviceRole.band, reason: '${e.id} is recognised');
      expect(e.canBeMainDevice, isFalse, reason: '${e.id} is not offered as a main device');
    }
  });

  test('a sensor can never be the main device', () {
    // WHY: workout add-ons and scales stay off the first-run list.
    for (final e in kBandRegistry) {
      if (e.role == DeviceRole.sensor) {
        expect(e.canBeMainDevice, isFalse, reason: e.id);
      }
    }
    expect(kBandRegistry.where((e) => e.canBeMainDevice).map((e) => e.id),
        containsAll(<String>['gen4', 'gen5']),
        reason: 'positive control: the main-device list is not empty');
  });

  test('only the framed WHOOP bands can be the main device', () {
    // WHY: the main-band path (PairingScreen, AppState.isPaired) runs framed
    // WHOOP only. Oura, Colmi, Mi Band and the rest are recognised as bands
    // but pair as additional devices under their own adapter.
    expect({for (final e in kBandRegistry) if (e.canBeMainDevice) e.id},
        {'gen4', 'gen5'});
    for (final e in kBandRegistry) {
      if (e.role == DeviceRole.band && !e.isFramed) {
        expect(e.canBeMainDevice, isFalse, reason: e.id);
      }
    }
  });
}
