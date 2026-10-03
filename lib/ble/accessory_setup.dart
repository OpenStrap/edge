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

  /// Deprovision the provisioned BANDS on unpair, leaving a paired sensor (a ring)
  /// alone. Best-effort.
  ///
  /// NOT `removeAll`, and the difference is not cosmetic: `ASAccessorySession
  /// .removeAccessory` does not just revoke this app's grant. Apple's own answer is that
  /// it removes the accessory "from the system and for ALL apps … this call will always
  /// remove it from the system" — the link-layer bond included. So unpairing a WHOOP band
  /// used to unpair the user's Oura ring from the PHONE as well, which nothing in this
  /// app can put back and which the Oura app and NOOP also lose. Seen in the field: the
  /// ring gone from Settings › Bluetooth.
  static Future<void> removeBands() async {
    if (!Platform.isIOS) return;
    try {
      await _ch.invokeMethod('removeBands');
    } catch (_) {}
  }
}
