// The HOST for a paired Casio-class watch: connect to its stored remote id,
// drive [CasioAdapter] over the link, bank what comes back, disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). The registry entry stays
// EXPERIMENTAL, `CasioAdapter.signals` stays `const {}`, and nothing this
// file writes becomes a number — every row it commits carries a non-null
// `source`.
//
// THIN COUSIN OF `watch9_link.dart`. There is no drain cursor and no time
// anchor to hold, so this is the same one-shot `sync()` shape: connect,
// let the adapter's own probe run to completion (it has its own per-tag
// timeout — see `CasioAdapter.replyTimeout`), tear down.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/casio.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired Casio-class watch. One instance; two watches of
/// this family can be paired at once (`kMaxConcurrentSecondaryLinks`), so a
/// caller with more than one row on screen MUST pass the one it means —
/// [sync]'s `deviceId` is that selector, never a guess.
class CasioLink {
  CasioLink._();
  static final CasioLink instance = CasioLink._();

  /// The `device` row for the paired watch. With [deviceId] given, the row
  /// with that exact id (or null if it is gone / not this family). With none
  /// given, the first Casio row — a caller with only one paired watch, or
  /// none, has no id to pass.
  static Future<Map<String, Object?>?> pairedRow({String? deviceId}) async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] != kCasio.id) continue;
      if (deviceId == null || r['id'] == deviceId) return r;
    }
    return null;
  }

  GattBandLink? _link;
  BandHost? _host;
  bool _busy = false;

  /// How long one sync session waits for the adapter's own probe to finish
  /// before tearing down regardless. The probe already bounds itself (five
  /// tags at [CasioAdapter.replyTimeout] apiece), so this is a backstop, not
  /// the thing that decides when the session ends.
  static const Duration _listenWindow = Duration(seconds: 25);

  /// Connect, run the probe, disconnect.
  ///
  /// [deviceId] picks which paired row to sync when more than one Casio
  /// watch is paired — see [pairedRow]. Returns false when nothing is
  /// paired or the connect failed. Never throws. SERIALISED: a second call
  /// while one is in flight is a no-op rather than a second radio session
  /// over the same peripheral.
  Future<bool> sync({String? deviceId}) {
    if (_busy) return Future.value(false);
    _busy = true;
    return _sync(deviceId).whenComplete(() => _busy = false);
  }

  Future<bool> _sync(String? wantDeviceId) async {
    final row = await pairedRow(deviceId: wantDeviceId);
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      // The primary band's id, permanently. This watch writing under it
      // would interleave its (undecoded, sample-less) rows with the band's
      // own.
      debugPrint('[casio] refusing to sync: the row claims the primary '
          'device id — re-pair it with a minted id.');
      return false;
    }

    try {
      // A cap on concurrent SECONDARY links (never the primary band's own
      // connect — see ble_state.dart's kMaxConcurrentSecondaryLinks doc).
      return await withSecondaryLinkSlot(() async {
        final device = BluetoothDevice.fromId(remoteId);
        // `connected` gates the disconnect in `finally`: a throw BEFORE
        // `connect()` lands (or a failed connect) has no radio session to
        // tear down, and calling disconnect() anyway is what used to leak —
        // everything from here on, connect through the probe, is inside this
        // one try/finally so every exit path disconnects exactly once.
        var connected = false;
        try {
          await device.connect(timeout: const Duration(seconds: 20));
          connected = true;
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kCasio,
            services: services,
            onLog: (m) => debugPrint('[casio] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kCasio.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[casio] ${kCasio.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: const CasioAdapter(),
            deviceId: deviceId,
            onLog: (m) => debugPrint('[casio] $m'),
            buildArchive: _buildArchiveRow,
          );
          _host = host;
          final done = host.run(link);
          var timedOut = false;
          await done.timeout(_listenWindow, onTimeout: () => timedOut = true);
          if (timedOut) {
            // The probe never finished within the backstop window — distinct
            // from a completed session that simply got no replies, so this
            // is never reported as "Synced."
            debugPrint('[casio] probe window elapsed before the session '
                'finished.');
            return false;
          }
          return true;
        } catch (e) {
          debugPrint('[casio] connect failed: $e');
          return false;
        } finally {
          await stop();
          if (connected) {
            try {
              await device.disconnect();
            } catch (_) {/* already gone */}
          }
        }
      });
    } catch (e) {
      debugPrint('[casio] sync failed: $e');
      return false;
    }
  }

  /// Build this session's `raw_archive` row for one frame — the harmless
  /// probe replies AND the stray, unsolicited notifications the adapter's
  /// tag-matching loop banks but does not claim (see `casio.dart`'s `run`).
  /// Both start with a tag byte, so both get a reason from it; nothing here
  /// is decoded.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    if (bytes.isEmpty) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL, not 0. This wire has no flash-record counter, and `counter` is
      // what `thinRawArchiveBefore` samples on — a 0 for every row would make
      // every Casio frame `0 % 60 == 0`, i.e. permanently exempt, which is
      // accidental policy.
      counter: null,
      packetType: bytes[0],
      // NULL, and it stays NULL. This wire carries no wall-clock second.
      recTs: null,
      capturedAt: capturedAtMs,
      // ONE REASON PER TAG, so a decoder written later finds its records by
      // name instead of re-scanning the table.
      reason: 'casio_tag_0x${bytes[0].toRadixString(16).padLeft(2, '0')}',
    );
  }

  /// Drop the link, flush what has been buffered. Safe when nothing is
  /// connected.
  Future<void> stop() async {
    _link?.close();
    _link = null;
    await _host?.stop();
    _host = null;
  }
}
