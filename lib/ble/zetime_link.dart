// The HOST for the MyKronoz ZeTime: hold nothing (no key, no cursor, no
// clock anchor — this band needs none of them), connect, drive
// [ZeTimeAdapter] over the link, bank what comes back, disconnect.
//
// NOTHING HERE HAS MET HARDWARE (owner ruling R6). The registry entry stays
// EXPERIMENTAL, `ZeTimeAdapter.signals` stays `const {}`, and nothing this
// file writes becomes a number: its rows carry a non-null `source`, and every
// derive/export read filters `source IS NULL`.
//
// THE SHAPE, AND WHY IT IS `OuraLink`'s SHAPE, NOT `HrsLink`'s. This is not a
// live sensor armed by a workout — it is one connect, one benign question, one
// disconnect. So this is a one-shot [ZeTimeLink.sync], same as the ring, and
// drastically SIMPLER than the ring's: no pairing key, no drain cursor, no
// time anchor, because `ZeTimeAdapter` asks for none of those things.
//
// PAIRING REUSES `HrsLink.pairNotifySensor` WITH `tier: null`. This band
// supplies no signal — `ZeTimeAdapter.signals` is `const {}` — so there is no
// measurement quality to rank, the same reasoning `oura_link.dart`'s own
// custom pairing path states for the same field. Everything else about
// pairing a ZeTime is the plain notify-class step: no handshake, no key, no
// clock — so `pairZeTime` below is a two-line wrapper, not a parallel pairing
// flow.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import '../sync/paired_device.dart' show cleanDeviceLabel;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/zetime.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;
import 'hrs_link.dart' show HrsLink;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Pair [device] as this phone's ZeTime. Null on success, or a sentence the
/// user can act on.
///
/// A thin wrapper over the plain notify-class pairing step
/// [HrsLink.pairNotifySensor], with `tier: null` — see this file's own header
/// for why a signal-less band gets no quality tier. The advertised name is
/// read directly off [device] rather than threaded through from the picker,
/// same as `pairOuraRing` does, because the generic `pick` signature this
/// screen calls through takes only the device.
Future<String?> pairZeTime(BluetoothDevice device) => HrsLink.pairNotifySensor(
      kZeTime,
      device,
      label: cleanDeviceLabel(device.platformName),
      tier: null,
    );

/// The live link to a paired ZeTime. One instance; a second concurrent one is
/// not a thing anyone asked for.
class ZeTimeLink {
  ZeTimeLink._();
  static final ZeTimeLink instance = ZeTimeLink._();

  /// The most recent battery reading, or null. Not written to `band_battery`
  /// for the same reason `OuraLink.batteryPct` is not: that table has no
  /// `device_id` and is read unfiltered, so a second device's cell would land
  /// in the primary band's own pack-health series.
  int? get batteryPct => _batteryPct;
  int? _batteryPct;

  BluetoothDevice? _device;
  GattBandLink? _link;
  BandHost? _host;
  bool _busy = false;

  /// The `device` row for the paired watch, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kZeTime.id) return r;
    }
    return null;
  }

  /// Connect, ask the one device fact this session asks, disconnect.
  /// SERIALISED: a second call while one is in flight is a no-op.
  Future<bool> sync() {
    if (_busy) return Future.value(false);
    _busy = true;
    return _sync().whenComplete(() => _busy = false);
  }

  Future<bool> _sync() async {
    final row = await pairedRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      debugPrint('[zetime] refusing to sync: the row claims the primary '
          'device id — re-pair it with a minted id.');
      return false;
    }
    try {
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kZeTime,
            services: services,
            onLog: (m) => debugPrint('[zetime] $m'),
          );
          _link = link;
          final missing = link.missingCharacteristics(kZeTime.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[zetime] ${kZeTime.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: kZeTimeAdapter,
            deviceId: deviceId,
            onLog: (m) => debugPrint('[zetime] $m'),
            onNote: _handleNote,
            buildArchive: _buildArchiveRow,
          );
          _host = host;
          await host.run(link);
          return true;
        } finally {
          // Drop the link and disconnect before the slot is released — the
          // same ordering `oura_link.dart`'s `sync()` uses and for the same
          // reason: held in an outer `finally` it would run after the slot
          // had already been released, admitting one more live GATT link than
          // the cap allows.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[zetime] sync failed: $e');
      return false;
    }
  }

  /// Drop the link, flush what the session can still stamp, disconnect. Safe
  /// when nothing is connected.
  Future<void> stop() async {
    _link?.close();
    _link = null;
    await _host?.stop();
    _host = null;
    final d = _device;
    _device = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {/* already gone */}
    }
  }

  void _handleNote(String key, Object? value) {
    if (key == 'battery' && value is int) {
      _batteryPct = value;
    } else {
      debugPrint('[zetime] $key = $value');
    }
  }

  /// Bank one frame verbatim (owner rulings R1-R3): the battery reply is
  /// decoded above, and this is the copy of its bytes that survives even if
  /// the decode above is ever found wrong.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    if (bytes.isEmpty) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL, not 0: this band has no flash-record counter, and `counter` is
      // what `thinRawArchiveBefore` samples on — a 0 for every row would make
      // every ZeTime frame permanently exempt from thinning.
      counter: null,
      // The command byte — this file's own adapter only ever banks frames
      // `parseZeTimeFrame` already accepted, so index 1 is always present.
      packetType: bytes[1],
      recTs: null,
      capturedAt: capturedAtMs,
      reason: 'zetime_cmd_0x${bytes[1].toRadixString(16).padLeft(2, '0')}',
    );
  }

  /// Replay a scripted watch through the real [ZeTimeAdapter] and the real
  /// write path. The only way in: the entry point is a BLE notification and
  /// `flutter_blue_plus` has no simulator path.
  Future<ReplayBandLink> ingestForTest(
    String deviceId,
    List<List<int>> Function(int writeIndex, List<int> value) reply,
  ) async {
    final link = ReplayBandLink();
    final host = BandHost(
      adapter: kZeTimeAdapter,
      deviceId: deviceId,
      onLog: (m) => debugPrint('[zetime] $m'),
      onNote: _handleNote,
      buildArchive: _buildArchiveRow,
    );
    _host = host;
    var finished = false;
    final done = host.run(link).whenComplete(() => finished = true);
    var served = 0;
    for (var spin = 0; spin < 800 && !finished; spin++) {
      await Future<void>.delayed(Duration.zero);
      while (served < link.writes.length) {
        for (final f in reply(served, link.writes[served].$2)) {
          link.feed(kZeTimeNotifyChar, f, atSec: 0);
        }
        served++;
      }
    }
    await link.close();
    await done.timeout(const Duration(seconds: 6), onTimeout: () {});
    await host.stop();
    _host = null;
    return link;
  }
}
