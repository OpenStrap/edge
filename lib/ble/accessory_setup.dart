// AccessorySetupKit (ASK) bridge — iOS 18+ pairing.
//
// Per Apple TN3115, on iOS 26 the OS only relaunches a terminated app into the
// background for a Bluetooth accessory that was provisioned via AccessorySetupKit. Our
// native CoreBluetooth restore central (BleRestoreManager) still does the relaunch work,
// but iOS 26 only honours it for an ASK-provisioned peripheral. So on iOS 18+ pairing
// goes through the ASK picker.
//
// ASK is a provisioning gate, not a connection owner: it returns the accessory's
// CoreBluetooth peripheral UUID (`bluetoothIdentifier`), which is exactly the value
// flutter_blue_plus uses as `BluetoothDevice.remoteId` on iOS. So the returned id becomes
// the PairedDevice.remoteId and flutter_blue_plus connects to it exactly as before — no
// second GATT owner, no conflict.
//
// No-op on Android and on iOS < 18 (callers fall back to the service-filtered scan).

import 'dart:io';

import 'package:flutter/services.dart';

import 'adapters/_registry.dart' show plistUuid;

class AccessorySetup {
  static const _ch = MethodChannel('openstrap/accessory_setup');

  /// True only on iOS 18+ (where ASK exists). False on Android and older iOS.
  static Future<bool> isSupported() async {
    if (!Platform.isIOS) return false;
    try {
      return (await _ch.invokeMethod<bool>('isSupported')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Every ASK-provisioned accessory's uppercased CoreBluetooth UUID, in session
  /// order (position 0 is the first band ever provisioned). Empty on Android and
  /// iOS < 18.
  static Future<List<String>> provisionedIds() async {
    if (!Platform.isIOS) return const [];
    try {
      final ids = await _ch.invokeListMethod<String>('provisionedIds');
      return ids ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// The first provisioned accessory, or null. Kept as a thin wrapper over
  /// [provisionedIds] so the two can never disagree.
  static Future<String?> provisionedId() async {
    final ids = await provisionedIds();
    return ids.isEmpty ? null : ids.first;
  }

  /// Show the ASK picker and return the provisioned band's CoreBluetooth UUID (use as
  /// PairedDevice.remoteId). Throws on cancel / error so the caller can surface it.
  ///
  /// [addAnother] requests a SECOND accessory rather than skipping the picker for an
  /// already-known one. Passing `null` (not `false`) on the default path keeps the wire
  /// bytes byte-identical to today's call for the single-band path.
  static Future<String> showPicker({bool addAnother = false}) async {
    final id = await _ch.invokeMethod<String>(
        'showPicker', addAnother ? true : null);
    if (id == null || id.isEmpty) {
      throw Exception('Pairing cancelled.');
    }
    return id;
  }

  /// Show the ASK picker for ONE sensor, filtered to [services], and return its
  /// CoreBluetooth UUID — the `remoteId` the sensor's pairing step connects to.
  /// Throws on cancel / error, like [showPicker].
  ///
  /// For `kAskPickerSensors` only: with `NSAccessorySetupKitSupports` declared
  /// the app has no standard Bluetooth authorization, so a sensor the user has
  /// not approved here cannot be found by a scan at all (#371/#372). Each
  /// service must be declared under `OSAskSensorServices`; the native side
  /// refuses anything else. Sent in [plistUuid] form (`180D`, not the 128-bit
  /// expansion), the form the plist declares. An already-approved sensor comes back with no sheet.
  static Future<String> showSensorPicker(List<String> services) async {
    final id = await _ch.invokeMethod<String>('showPicker', <String, Object>{
      'services': [for (final s in services) plistUuid(s)],
    });
    if (id == null || id.isEmpty) {
      throw Exception('Pairing cancelled.');
    }
    return id;
  }

  /// Drop the ASK approval of sensor [id], so pairing that kind of sensor again
  /// opens the sheet instead of handing back this id. The native side only ever
  /// removes a sensor, never a band. Best-effort; a no-op where there is no ASK.
  ///
  /// NO CALLER, AND THAT IS THE CONCLUSION, not an oversight. Both call sites
  /// it was written for have been taken out again:
  ///   * before the sensor picker, reverted by `2068fd4b`;
  ///   * on an explicit forget, taken out here — see the comment in
  ///     `HrsLink.forgetDevice`.
  ///
  /// The reason is the same both times and is not about the trigger.
  /// `ASAccessorySession.removeAccessory` removes the accessory "from the system
  /// and for all apps … this call will always remove it from the system", bond
  /// included, so calling it unpairs the device from the PHONE: the vendor app
  /// loses it too, nothing here can put it back, and until the user re-pairs
  /// with that app the device does not advertise at all — which surfaces as a
  /// silent, timeout-less connect that names nothing. See #520.
  ///
  /// So before wiring this up anywhere, be sure the user asked to unpair the
  /// device from their phone, and not merely to remove it from this app.
  static Future<void> removeSensor(String id) async {
    try {
      await _ch.invokeMethod('removeSensor', id.toUpperCase());
    } catch (_) {}
  }

  /// Deprovision every ASK band, sensors kept (called on unpair). Best-effort.
  static Future<void> removeAll() async {
    if (!Platform.isIOS) return;
    try {
      await _ch.invokeMethod('removeAll');
    } catch (_) {}
  }
}
