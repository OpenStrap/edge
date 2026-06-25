// iOS CoreBluetooth state-restoration bridge.
//
// The native BleRestoreManager (ios/Runner/BleRestoreManager.swift) holds a no-timeout
// pending connect to the paired band so iOS relaunches the app when the band reappears —
// even from terminated. When that fires, native invokes `wake` here and we run the same
// headless drain the periodic task uses, then tell native we're done so it re-arms.
//
// No-op on Android (the Edge Tracking foreground service keeps the process + live
// connection alive there — no restore central needed).

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../sync/background_sync.dart';

class IosBleRestore {
  static const _ch = MethodChannel('openstrap/ble_restore');
  static bool _busy = false;

  /// Set true while the app holds a live foreground session (BleEngine connected).
  /// A wake-triggered headless sync would otherwise fight flutter_blue_plus for the
  /// band, so we skip it — the foreground session is already draining.
  static bool foregroundActive = false;

  /// Register the wake handler and tell native Flutter is ready. Call once at startup.
  static Future<void> init() async {
    if (!Platform.isIOS) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method != 'wake') return null;
      if (foregroundActive) {
        await _done();
        return null;
      }
      if (_busy) return null;
      _busy = true;
      try {
        await runHeadlessSync();
      } catch (e) {
        debugPrint('[ios-restore] headless sync threw: $e');
      } finally {
        _busy = false;
        await _done();
      }
      return null;
    });
    try {
      await _ch.invokeMethod('ready');
    } catch (_) {}
  }

  /// Tell native whether the app currently owns the live connection (via
  /// flutter_blue_plus). While true, the restore central must NOT arm a competing
  /// pending connect to the same peripheral. Set false (then [arm]) to hand the band
  /// to the restore path for background relaunch.
  static Future<void> setOwnsBand(bool owns) async {
    if (!Platform.isIOS) return;
    try {
      await _ch.invokeMethod('setOwnsBand', owns);
    } catch (_) {}
  }

  /// Tell native that an accessory was just provisioned via the ASK picker (first-time
  /// pairing). This is the cue for the native restore central to be CREATED — it is
  /// deliberately deferred at launch on a fresh install so the ASK picker can be shown
  /// with NO CBCentralManager alive (else `showPicker` fails with "CBManager is active
  /// with global permissions"). Must be called BEFORE any flutter_blue_plus call.
  static Future<void> provisioned(String remoteId) async {
    if (!Platform.isIOS) return;
    try {
      await _ch.invokeMethod('provisioned', remoteId);
    } catch (_) {}
  }

  /// Arm restoration for this band (its iOS peripheral UUID == PairedDevice.remoteId).
  static Future<void> arm(String remoteId) async {
    if (!Platform.isIOS) return;
    try {
      await _ch.invokeMethod('arm', remoteId);
    } catch (_) {}
  }

  /// Stop restoration (sign-out / unpair).
  static Future<void> disarm() async {
    if (!Platform.isIOS) return;
    try {
      await _ch.invokeMethod('disarm');
    } catch (_) {}
  }

  static Future<void> _done() async {
    try {
      await _ch.invokeMethod('syncDone');
    } catch (_) {}
  }
}
