// The HOST for the Pebble 2 / Pebble 2 SE: hold the paired `device` row,
// connect, drive [PebbleAdapter] over the link for a bounded window, bank
// whatever PPoGATT frames land, disconnect.
//
// NOTHING HERE HAS MET HARDWARE. Nobody on this project owns a Pebble (owner
// ruling R6), so not one byte of this path has been exercised against one. The
// registry entry stays EXPERIMENTAL and `PebbleAdapter.signals` stays
// `const {}` — nothing this file writes becomes a decoded number.
//
// THE SHAPE, AND WHY IT IS NOT `OuraLink`'s. There is no key, no drain cursor,
// no time anchor: `pebble.dart` archives raw PPoGATT payloads verbatim and
// decodes nothing, so there is nothing this host needs to remember between
// sessions beyond the `device` row itself.
//
// THE ONE THING THIS HOST DOES OWN THAT OURA'S DOES NOT: the session window.
// `OuraLink.sync` drains to a natural end-of-history the ring itself reports;
// `PebbleAdapter.run` answers a keepalive protocol that has no such signal —
// it stays parked on the watch's notify stream for as long as the link is
// open. So this is a periodic connect-drain-disconnect over a fixed wall-clock
// window (a watch on the wrist is not a chest strap armed by a workout,
// hence no arm/disarm pair either) rather than a run that ends on its own.
// ponytail: a plain `Future.any([host.run(link), delayed(window)])` is the
// smallest correct thing here — the alternative is teaching the adapter to
// report an end-of-data signal the PPoGATT transport does not have.

import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart' show ReplayBandLink;
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/pebble.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired Pebble. One instance; a second concurrent watch
/// is not a thing anyone asked for.
class PebbleLink {
  PebbleLink._();
  static final PebbleLink instance = PebbleLink._();

  /// The `device` row for the paired watch, or null.
  static Future<Map<String, Object?>?> pairedWatchRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kPebble.id) return r;
    }
    return null;
  }

  /// Forget a paired Pebble: tear down a live session if this is it, drop the
  /// `device` row. No key to drop — see this file's header.
  static Future<bool> forgetPebble(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[pebble] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) {
      await instance.stop();
    }
    await LocalDb.deleteDevice(id);
    return true;
  }

  BluetoothDevice? _device;

  /// Kept only so teardown can [GattBandLink.close] it, same reason
  /// `OuraLink._link` is.
  GattBandLink? _link;

  /// The session driving [kPebbleAdapter] over [_link] — see `adapters/host.dart`.
  BandHost? _host;

  /// `device.id` of the paired watch. Never [LocalDb.kPrimaryDeviceId].
  String? _deviceId;

  bool _busy = false;

  /// How long one connect stays open before this host tears it down on its
  /// own — see the header on why the adapter's own stream never ends.
  static const Duration _defaultWindow = Duration(seconds: 20);

  /// Connect to the paired watch, drive [kPebbleAdapter] for [window], then
  /// disconnect. Returns false when nothing is paired or the connect failed.
  /// SERIALISED: a second call while one is in flight is a no-op rather than a
  /// second radio session over the same peripheral.
  Future<bool> sync({Duration window = _defaultWindow}) {
    if (_busy) return Future.value(false);
    _busy = true;
    return _sync(window).whenComplete(() => _busy = false);
  }

  Future<bool> _sync(Duration window) async {
    final row = await pairedWatchRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      debugPrint('[pebble] refusing to sync: the watch row claims the '
          'primary device id — re-pair it with a minted id.');
      return false;
    }

    _deviceId = deviceId;
    try {
      // A cap on concurrent SECONDARY links — see ble_state.dart's
      // kMaxConcurrentSecondaryLinks doc. Connect, drive and disconnect all
      // complete inside this one call, so the simple scoped form is correct.
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kPebble,
            services: services,
            onLog: (m) => debugPrint('[pebble] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kPebble.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[pebble] ${kPebble.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: kPebbleAdapter,
            deviceId: deviceId,
            onLog: (m) => debugPrint('[pebble] $m'),
            buildArchive: _buildArchiveRow,
          );
          _host = host;
          // The adapter's stream has no end of its own — see the header —
          // so the window is what ends this session, not `run()` completing.
          await Future.any([
            host.run(link),
            Future<void>.delayed(window),
          ]);
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[pebble] sync failed: $e');
      return false;
    }
  }

  /// Drop the link, flush what the session banked, disconnect. Safe to call
  /// when nothing is connected.
  Future<void> stop() async {
    // Before the host's run subscription is cancelled: an adapter's `finally`
    // can still write on the way out, and that write must not reach the radio.
    _link?.close();
    _link = null;
    await _host?.stop();
    _host = null;
    _deviceId = null;
    final d = _device;
    _device = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {/* already gone */}
    }
  }

  /// Bank one PPoGATT payload verbatim, undecoded — the whole of what
  /// `pebble.dart` promises. No inner frame tag survives this layer (SCOPE IS
  /// PPoGATT ONLY, see that file's header), so there is no per-tag `reason`
  /// to give it the way Oura's archive rows get one; every row here carries
  /// the same reason and `packetType: 0` because nothing decoded a type.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL, not 0: this watch has no flash-record counter reaching this
      // layer, and `counter` is what `thinRawArchiveBefore` samples on — a
      // constant 0 would make every frame permanently exempt from thinning.
      counter: null,
      packetType: 0,
      recTs: null,
      capturedAt: capturedAtMs,
      reason: 'pebble_ppogatt',
    );
  }

  /// Replay scripted PPoGATT bytes through the REAL [kPebbleAdapter] and the
  /// real write path. The only way in: the entry point is a BLE notification
  /// and `flutter_blue_plus` has no simulator path.
  @visibleForTesting
  Future<ReplayBandLink> ingestForTest(
    String deviceId,
    List<List<int>> arrivals,
  ) async {
    final link = ReplayBandLink();
    final host = BandHost(
      adapter: kPebbleAdapter,
      deviceId: deviceId,
      onLog: (m) => debugPrint('[pebble] $m'),
      buildArchive: _buildArchiveRow,
    );
    _host = host;
    final done = host.run(link);
    for (final value in arrivals) {
      link.feed(kPebblePpogattReadUuid, value, atSec: 1_800_000_000);
    }
    await link.close();
    await done;
    await host.stop();
    _host = null;
    return link;
  }
}
