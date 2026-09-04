// The HOST for a paired Polar PMD sensor: connect, drive [PolarPmdAdapter]
// over the link, write what comes back into the substrate.
//
// NOT A GENERALIZATION OF `HrsLink`. That class is hardcoded to
// [kBleHrsAdapter] per its own doc — this is a second, parallel host for a
// second notify-class band, not a widening of the first. Scanning and pairing
// are already generic over any [BandEntry] (`HrsLink.scanFor`,
// `HrsLink.pairNotifySensor`), so this file owns only what is specific to
// THIS band: arming a live session and driving it.
//
// LIVE SESSION, ARMED BY A WORKOUT — same shape as `HrsLink`, not
// `OuraLink`'s one-shot fetch-by-cursor `sync()`. A PPI stream has nothing to
// drain and nothing to trim; it either has a live GATT link open or it does
// not.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). It ships EXPERIMENTAL, and
// `kDerivableSources` stays empty until the owner has held one.
//
// ARMED AT THE SAME CALL SITES AS `HrsLink` — every place `app_state.dart`
// arms or disarms the heart-rate sensor now does the same for this link,
// unconditionally: [arm] is a no-op returning false when nothing is paired,
// same as `HrsLink.arm`.

import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost, HrsReading;
import 'adapters/polar_pmd.dart' show kPolarPmdAdapter;
import 'ble_state.dart'
    show acquireSecondaryLinkSlot, releaseSecondaryLinkSlot;

/// The live link to a paired Polar sensor. One instance; a second concurrent
/// sensor of this kind is not a thing anyone asked for.
class PolarPmdLink {
  PolarPmdLink._();
  static final PolarPmdLink instance = PolarPmdLink._();

  BluetoothDevice? _device;
  GattBandLink? _link;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  BandHost? _host;
  bool _armed = false;
  bool _holdsSecondaryLinkSlot = false;

  ValueListenable<HrsReading?> get reading => _reading;
  final ValueNotifier<HrsReading?> _reading = ValueNotifier(null);

  /// The armed sensor's `device_id`, or null when nothing is armed.
  String? get deviceId => _host?.deviceId;

  /// The `device` row for the paired sensor, or null.
  static Future<Map<String, Object?>?> pairedSensorRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kPolarPmdAdapter.id) return r;
    }
    return null;
  }

  Future<bool>? _arming;
  Future<void>? _disarming;
  int _disarms = 0;

  /// Connect to the paired sensor and start logging. No-op (returns false)
  /// when nothing is paired. Never scans — connects straight to the stored
  /// remote id.
  ///
  /// Same double-arm/teardown-race guards as `HrsLink.arm` and for the same
  /// reasons: two concurrent calls are one attempt, a call landing mid-teardown
  /// waits it out and then arms, and an attempt a [disarm] cancelled is never
  /// handed out again. See that method's own doc for the full case-by-case
  /// account — the shape here is verbatim, only the band underneath differs.
  Future<bool> arm() {
    final teardown = _disarming;
    if (teardown != null) return _armAfter(teardown);
    if (_armed) return Future.value(true);
    final existing = _arming;
    if (existing != null) return existing;
    late final Future<bool> mine;
    mine = _arm().whenComplete(() {
      if (identical(_arming, mine)) _arming = null;
    });
    return _arming = mine;
  }

  Future<bool> _armAfter(Future<void> teardown) async {
    try {
      await teardown;
    } catch (_) {/* the disarm caller's error, not ours */}
    return arm();
  }

  Future<bool> _arm() async {
    final disarmsAtStart = _disarms;
    final row = await pairedSensorRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      // The primary band's id, permanently. A sensor writing under it would
      // interleave its seconds with the band's in one REPLACE-keyed table.
      return false;
    }
    final device = BluetoothDevice.fromId(remoteId);
    try {
      _device = device;
      await acquireSecondaryLinkSlot();
      if (_disarms != disarmsAtStart) {
        releaseSecondaryLinkSlot();
        return false;
      }
      _holdsSecondaryLinkSlot = true;
      await device.connect(timeout: const Duration(seconds: 12));
      final services = await device.discoverServices();
      if (_disarms != disarmsAtStart) {
        await _disconnectAbandoned(device);
        return false;
      }
      final link = GattBandLink(
        entry: kPolarPmdAdapter.entry,
        services: services,
        onLog: (m) => debugPrint('[polar_pmd] $m'),
      );
      _link = link;
      final missing = link.missingCharacteristics(
          kPolarPmdAdapter.entry.requiredCharacteristics);
      if (missing.isNotEmpty) {
        await _teardownQuietly();
        return false;
      }
      final host = BandHost(
        adapter: kPolarPmdAdapter,
        deviceId: deviceId,
        onLog: (m) => debugPrint('[polar_pmd] $m'),
      );
      _host = host;
      host.reading.addListener(() => _reading.value = host.reading.value);
      unawaited(host.run(link).whenComplete(() {
        if (_disarms != disarmsAtStart) return;
        unawaited(disarm());
      }));
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) unawaited(disarm());
      });
      _armed = true;
      _reading.value = const HrsReading();
      return true;
    } catch (e) {
      if (_disarms != disarmsAtStart) {
        await _disconnectAbandoned(device);
      } else {
        await _teardownQuietly();
      }
      return false;
    }
  }

  Future<void> _teardownQuietly() async {
    try {
      await disarm();
    } catch (_) {/* disarm's own finally already leaves "not armed" true */}
  }

  Future<void> _disconnectAbandoned(BluetoothDevice device) async {
    if (_device != null && !identical(_device, device)) return;
    try {
      await device.disconnect();
    } catch (_) {/* already gone */}
  }

  /// Stop logging, flush the tail and drop the link. Safe to call when not
  /// armed. AWAIT it before a finish screen reads the session back.
  Future<void> disarm() {
    _disarms++;
    _arming = null;
    final prev = _disarming;
    late final Future<void> mine;
    mine = _disarmAfter(prev).whenComplete(() {
      if (identical(_disarming, mine)) _disarming = null;
    });
    return _disarming = mine;
  }

  Future<void> _disarmAfter(Future<void>? prev) async {
    if (prev != null) {
      try {
        await prev;
      } catch (_) {/* the previous caller's error, not ours */}
    }
    await _disarm();
  }

  Future<void> _disarm() async {
    final d = _device;
    try {
      _link?.close();
      await _host?.stop();
    } finally {
      await _connSub?.cancel();
      _link = null;
      _host = null;
      _connSub = null;
      _device = null;
      _armed = false;
      if (_holdsSecondaryLinkSlot) {
        _holdsSecondaryLinkSlot = false;
        releaseSecondaryLinkSlot();
      }
      _reading.value = null;
      if (d != null) {
        try {
          await d.disconnect();
        } catch (_) {/* already gone */}
      }
    }
  }
}
