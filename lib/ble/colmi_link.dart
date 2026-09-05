// The HOST for a paired Colmi ring: hold the `device` row, connect, drive
// [ColmiAdapter] over the link, bank the raw frames it yields, disconnect.
//
// THE SHAPE IS `OuraLink`'s, minus everything Oura needs that this ring does
// not. No pairing key (this protocol has no handshake at all — see
// `adapters/colmi.dart`'s header), no drain cursor and no time anchor (the
// adapter walks the same small rolling window every connect; there is
// nothing on the ring to resume from and nothing here ever computes a
// timestamp from ring bytes). So this is a plain one-shot [ColmiLink.sync]:
// read the `device` row, connect by `remote_id`, discover, check
// [GattBandLink.missingCharacteristics], drive `run()`, bank, disconnect —
// the same host work Oura does, in the same order, with the two Oura-only
// concerns (keychain, cursor/anchor persistence) simply absent.
//
// NOTHING HERE HAS MET HARDWARE (owner ruling R6). `ColmiAdapter.signals`
// stays `const {}`, so every batch this host commits carries samples: []
// and only the raw frames — there is no decoded number to gate behind a
// `source` filter because none is written.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart' show ReplayBandLink;
import 'adapters/colmi.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired Colmi ring. One instance; a second concurrent
/// ring is not a thing anyone asked for (same call as `OuraLink`).
class ColmiLink {
  ColmiLink._();
  static final ColmiLink instance = ColmiLink._();

  /// The `device` row for the paired ring, or null.
  static Future<Map<String, Object?>?> pairedRingRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kColmi.id) return r;
    }
    return null;
  }

  /// Forget a paired ring: stop any live session, drop its `device` row.
  /// No stored secret to drop — that is the whole difference from
  /// [OuraLink.forgetRing].
  static Future<bool> forgetRing(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[colmi] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) await instance.stop();
    await LocalDb.deleteDevice(id);
    return true;
  }

  int? get batteryPct => _batteryPct;
  int? _batteryPct;

  BluetoothDevice? _device;
  GattBandLink? _link;
  BandHost? _host;
  String? _deviceId;
  bool _busy = false;

  /// Connect to the paired ring, walk its rolling history window, disconnect.
  ///
  /// Returns false when nothing is paired or the connect failed. SERIALISED:
  /// a second call while one is in flight is a no-op rather than a second
  /// radio session over the same peripheral.
  Future<bool> sync() {
    if (_busy) return Future.value(false);
    _busy = true;
    return _sync().whenComplete(() => _busy = false);
  }

  Future<bool> _sync() async {
    final row = await pairedRingRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      debugPrint('[colmi] refusing to sync: the ring row claims the primary '
          'device id — re-pair it with a minted id.');
      return false;
    }
    _deviceId = deviceId;
    try {
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kColmi,
            services: services,
            onLog: (m) => debugPrint('[colmi] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kColmi.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[colmi] ${kColmi.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: kColmiAdapter,
            deviceId: deviceId,
            onLog: (m) => debugPrint('[colmi] $m'),
            onNote: _handleNote,
            buildArchive: _buildArchiveRow,
          );
          _host = host;
          await host.run(link);
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released — same
          // ordering `OuraLink._sync` uses and for the same reason: held in
          // an outer `finally` this would run after the slot had already
          // been released, letting the next queued link connect while this
          // one was still disconnecting.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[colmi] sync failed: $e');
      return false;
    }
  }

  /// Drop the link, flush what the session banked, disconnect. Safe to call
  /// when nothing is connected.
  Future<void> stop() async {
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

  void _handleNote(String key, Object? value) {
    if (key == 'battery' && value is int) _batteryPct = value;
  }

  /// Bank one command's reply frame verbatim, undecoded (owner rulings
  /// R1-R3). `counter` and `recTs` stay NULL: this protocol has neither a
  /// flash-record counter nor a record time survives the wire — see
  /// `ArchiveRecord.counter`'s own doc on why NULL, not 0, is what a band
  /// with no counter needs.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    if (bytes.length != 16) return null;
    return ArchiveRecord(
      counter: null,
      hex: _hex(bytes),
      packetType: bytes[0],
      recTs: null,
      capturedAt: capturedAtMs,
      // ONE REASON PER COMMAND ID, so a decoder written later finds its
      // frames by name. Deliberately not in `LocalDb.redrivableArchiveReasons`
      // — that list replays a row's `hex` through the WHOOP R24 chain, which
      // would run the wrong decoder over a Colmi frame.
      reason: 'colmi_cmd_0x${bytes[0].toRadixString(16).padLeft(2, '0')}',
    );
  }

  /// Replay a scripted ring through the REAL [ColmiAdapter] and the real
  /// write path. The only way in: the entry point is a BLE notification and
  /// `flutter_blue_plus` has no simulator path. Same shape as
  /// `OuraLink.ingestForTest`, minus the key/cursor/anchor Colmi has none of.
  @visibleForTesting
  Future<ReplayBandLink> ingestForTest(
    String deviceId,
    List<List<int>> Function(int writeIndex, List<int> value) reply, {
    int Function()? nowSeconds,
    // Short, not `kColmiAdapter`'s real 5 s / 800 ms: a test drives the
    // adapter's own real timers, and this file's `_replay` spins on
    // `Duration.zero` rather than advancing a fake clock, so the real
    // timeouts have to be short enough for that spin to actually outlast
    // them.
    Duration firstReplyTimeout = const Duration(milliseconds: 100),
    Duration quietTimeout = const Duration(milliseconds: 20),
  }) async {
    _deviceId = deviceId;
    final link = ReplayBandLink();
    final now = nowSeconds ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final host = BandHost(
      adapter: ColmiAdapter(
        nowSeconds: now,
        firstReplyTimeout: firstReplyTimeout,
        quietTimeout: quietTimeout,
      ),
      deviceId: deviceId,
      onLog: (m) => debugPrint('[colmi] $m'),
      onNote: _handleNote,
      buildArchive: _buildArchiveRow,
      nowSeconds: now,
    );
    _host = host;
    var finished = false;
    final done = host.run(link).whenComplete(() => finished = true);
    var served = 0;
    // Each of the (up to) 29 commands genuinely waits out `quietTimeout` of
    // REAL wall-clock time before its collection ends, so — unlike Oura's
    // handful of writes — this spin has to actually let that much real time
    // pass rather than just yield microtasks.
    for (var spin = 0; spin < 4000 && !finished; spin++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      while (served < link.writes.length) {
        for (final f in reply(served, link.writes[served].$2)) {
          link.feed(kColmiNotifyChar, f, atSec: now());
        }
        served++;
      }
    }
    await link.close();
    await done.timeout(const Duration(seconds: 5), onTimeout: () {});
    await host.stop();
    _host = null;
    _deviceId = null;
    return link;
  }
}
