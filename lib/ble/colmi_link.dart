// The HOST for a paired Colmi ring: hold the `device` row, connect, drive
// [ColmiAdapter] over the link, commit what it decodes and bank every reply
// verbatim, disconnect.
//
// THE SHAPE IS `OuraLink`'s, minus everything Oura needs that this ring does
// not: no pairing key (no handshake at all) and no drain cursor (the adapter
// re-walks a rolling 7-day window every connect; the ring never deletes on
// our say-so). One-shot [ColmiLink.sync]: read the `device` row, connect by
// `remote_id`, discover, check [GattBandLink.missingCharacteristics], drive
// `run()`, commit, disconnect.
//
// EXPERIMENTAL (ASSUMPTIONS R6). Decoded HR lands in `decoded_onehz` with
// `source = 'colmi'`. `kDerivableSources` keeps it off the primary band's
// read path; it derives only as the active wearable with its R6 flag on
// (`compute/inputs/colmi_inputs.dart`). The ring's own sleep stages and
// daily scalars land in their vendor tables.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show kColmiCmdBigData;

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

  /// The session's clock, read once (Unix seconds): the moment the ring's
  /// "N days ago" is counted from. Stamped on every big-data reply as
  /// `rec_ts`, so a sync that runs past midnight still resolves each reply
  /// to the day the adapter resolved it to.
  int? _anchorSec;

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
          final anchor = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          _anchorSec = anchor;
          final host = BandHost(
            adapter: ColmiAdapter(nowSeconds: () => anchor),
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

  /// Bank one reply verbatim (owner rulings R1-R3): a 16-byte Service A
  /// frame or a reassembled Service B big-data reply. `counter` stays NULL —
  /// this protocol has no flash-record counter. The time a slot belongs to is
  /// derived from its position, not carried per frame, so a big-data reply's
  /// `recTs` is the session's [_anchorSec], the clock its "days ago" counts
  /// from; a Service A frame's stays NULL.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    final big = bytes.length >= 6 && bytes[0] == kColmiCmdBigData;
    if (!big && bytes.length != 16) return null;
    String h(int b) => b.toRadixString(16).padLeft(2, '0');
    return ArchiveRecord(
      counter: null,
      hex: _hex(bytes),
      packetType: bytes[0],
      recTs: big ? _anchorSec : null,
      capturedAt: capturedAtMs,
      // ONE REASON PER COMMAND (or big-data type), so a re-decode finds its
      // frames by name. Deliberately not in `LocalDb.redrivableArchiveReasons`
      // — that list replays a row's `hex` through the WHOOP R24 chain, which
      // would run the wrong decoder over a Colmi frame.
      reason: big ? 'colmi_big_0x${h(bytes[1])}' : 'colmi_cmd_0x${h(bytes[0])}',
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
    _anchorSec = now();
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
    // A walk with no reply genuinely waits out its timeout in REAL wall-clock
    // time, so this spin has to let that time pass rather than just yield
    // microtasks.
    for (var spin = 0; spin < 4000 && !finished; spin++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      while (served < link.writes.length) {
        final (char, value) = link.writes[served];
        // A Service B request is answered on Service B's notify.
        final notify =
            char == kColmiCommandChar ? kColmiBigNotifyChar : kColmiNotifyChar;
        for (final f in reply(served, value)) {
          link.feed(notify, f, atSec: now());
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
