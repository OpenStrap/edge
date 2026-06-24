// hr_broadcast.dart — turn the phone into a standard BLE Heart Rate Monitor that
// re-broadcasts the band's live HR. A bike computer (Wahoo/Garmin) or gym machine
// pairs with "OpenStrap HR" exactly like a chest strap and shows the live value.
//
// The phone bridges: WHOOP --(custom GATT, read by flutter_blue_plus)--> phone
//   --(standard Heart Rate Service 0x180D, ble_peripheral)--> bike computer.
//
// iOS caveat: BLE peripheral advertising is restricted in the background, so this
// is most reliable with the app in the foreground (screen on) during a ride.

import 'dart:typed_data';
import 'package:ble_peripheral/ble_peripheral.dart';

class HrBroadcaster {
  // SIG-assigned 16-bit UUIDs expanded to the 128-bit base.
  static const String _hrService = '0000180D-0000-1000-8000-00805F9B34FB';
  static const String _hrMeasurement = '00002A37-0000-1000-8000-00805F9B34FB';
  static const String _bodySensorLocation = '00002A38-0000-1000-8000-00805F9B34FB';

  final void Function()? onChange;
  HrBroadcaster({this.onChange});

  bool _ready = false;
  bool _advertising = false;
  int _subscribers = 0;

  bool get isAdvertising => _advertising;
  int get subscribers => _subscribers;

  Future<bool> isSupported() async {
    try {
      return await BlePeripheral.isSupported();
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureSetup() async {
    if (_ready) return;
    await BlePeripheral.initialize();

    BlePeripheral.setCharacteristicSubscriptionChangeCallback(
      (String deviceId, String characteristicId, bool isSubscribed, String? name) {
        _subscribers += isSubscribed ? 1 : -1;
        if (_subscribers < 0) _subscribers = 0;
        onChange?.call();
      },
    );

    await BlePeripheral.addService(
      BleService(
        uuid: _hrService,
        primary: true,
        characteristics: [
          // Heart Rate Measurement — notify only. CoreBluetooth REQUIRES a notify
          // characteristic to be dynamic (no cached `value`); attaching a value to
          // anything but a read-only characteristic throws an NSException and crashes
          // the app. So no `value` here — we push updates via updateCharacteristic.
          BleCharacteristic(
            uuid: _hrMeasurement,
            properties: [CharacteristicProperties.notify.index],
            permissions: [AttributePermissions.readable.index],
          ),
          // Body Sensor Location — 0x02 = Wrist (the WHOOP sits on the wrist).
          BleCharacteristic(
            uuid: _bodySensorLocation,
            properties: [CharacteristicProperties.read.index],
            permissions: [AttributePermissions.readable.index],
            value: Uint8List.fromList([0x02]),
          ),
        ],
      ),
    );
    _ready = true;
  }

  Future<void> start() async {
    await _ensureSetup();
    if (_advertising) return;
    await BlePeripheral.startAdvertising(
      services: [_hrService],
      localName: 'OpenStrap HR',
    );
    _advertising = true;
    onChange?.call();
  }

  Future<void> stop() async {
    if (!_advertising) return;
    await BlePeripheral.stopAdvertising();
    _advertising = false;
    _subscribers = 0;
    onChange?.call();
  }

  /// Push a new HR value to any subscribed central (the bike computer).
  Future<void> pushHr(int bpm) async {
    if (!_advertising || bpm <= 0) return;
    try {
      await BlePeripheral.updateCharacteristic(
        characteristicId: _hrMeasurement,
        value: _encodeHr(bpm),
      );
    } catch (_) {
      /* transient peripheral hiccup — next tick retries */
    }
  }

  // HR Measurement format: a flags byte then the value. flags=0x00 → 8-bit HR,
  // sensor-contact "not supported". Valid for any HR < 256.
  Uint8List _encodeHr(int bpm) =>
      Uint8List.fromList([0x00, bpm < 0 ? 0 : (bpm > 255 ? 255 : bpm)]);
}
