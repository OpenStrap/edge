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
import 'package:openstrap_protocol/openstrap_protocol.dart'
    show PebbleFrameReassembler;

import 'adapters/pebble.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

/// `sync_cursor` name for the newest step minute already counted.
String _stepsHwItem(String deviceId) => 'pebble_steps_hw:$deviceId';

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
  static const Duration _defaultWindow = Duration(seconds: 60);

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
          final host = await _makeHost(deviceId,
              () => DateTime.now().millisecondsSinceEpoch ~/ 1000);
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

  /// This session's host: the adapter starts from the step totals already
  /// stored for this watch and the newest minute already counted, so a day's
  /// total carries forward across sessions (the watch never re-sends an
  /// ACKed minute).
  Future<BandHost> _makeHost(String deviceId, int Function() now) async {
    final hw = await LocalDb.getCursorInt(_stepsHwItem(deviceId)) ?? 0;
    final prior = <DateTime, int>{};
    if (hw > 0) {
      final t = DateTime.fromMillisecondsSinceEpoch(hw * 1000);
      final day = DateTime(t.year, t.month, t.day);
      final stored = await LocalDb.deviceObservationValues(deviceId, 'steps',
          fromMs: day.millisecondsSinceEpoch);
      stored.forEach((ts, v) =>
          prior[DateTime.fromMillisecondsSinceEpoch(ts)] = v.toInt());
    }
    return BandHost(
      adapter: PebbleAdapter(
          nowSeconds: now, priorSteps: prior, stepsHighWater: hw),
      deviceId: deviceId,
      onLog: (m) => debugPrint('[pebble] $m'),
      onNote: (key, value) {
        if (key == 'pebble_steps_hw' && value is int) {
          _hwWrites = _hwWrites
              .then((_) => LocalDb.setCursor(_stepsHwItem(deviceId), '$value'))
              .catchError((_) {});
        }
      },
      buildArchive: _buildArchiveRow,
      nowSeconds: now,
    );
  }

  Future<void> _hwWrites = Future.value();

  /// Replay a scripted watch through the REAL [PebbleAdapter], host and
  /// sqlite. [arrivals] are PPoGATT packets the watch sends unprompted;
  /// [reply] answers each inner frame the phone sends (endpoint, payload)
  /// with more PPoGATT packets.
  @visibleForTesting
  Future<ReplayBandLink> ingestForTest(
    String deviceId,
    List<List<int>> arrivals, {
    int Function()? nowSeconds,
    List<List<int>> Function(int endpoint, List<int> payload)? reply,
  }) async {
    final now = nowSeconds ?? () => 1800000000;
    final link = ReplayBandLink();
    final host = await _makeHost(deviceId, now);
    _host = host;
    var finished = false;
    final done = host.run(link).whenComplete(() => finished = true);
    for (final value in arrivals) {
      link.feed(kPebblePpogattReadUuid, value, atSec: now());
    }
    final frames = PebbleFrameReassembler();
    var served = 0;
    for (var spin = 0; spin < 400 && !finished; spin++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      while (served < link.writes.length) {
        final w = link.writes[served++].$2;
        if (w.isEmpty || (w[0] & 0x7) != 0) continue; // transport acks/resets
        for (final (endpoint, p) in frames.add(w.sublist(1))) {
          for (final packet in reply?.call(endpoint, p) ?? const <List<int>>[]) {
            link.feed(kPebblePpogattReadUuid, packet, atSec: now());
          }
        }
      }
    }
    await link.close();
    await done.timeout(const Duration(seconds: 5), onTimeout: () {});
    await host.stop();
    await _hwWrites;
    _host = null;
    return link;
  }
}
