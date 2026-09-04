// The HOST for a Lefun-protocol ring/band: connect, drive [LefunAdapter] over
// the link, bank what comes back, disconnect.
//
// NOTHING HERE HAS MET HARDWARE. The registry entry stays EXPERIMENTAL,
// [LefunAdapter.signals] stays `const {}`, and nothing this file writes
// becomes a number: its rows carry a non-null `source`, and every
// derive/export read filters `source IS NULL`.
//
// THE SHAPE IS OURA'S, MINUS THE STATE OURA NEEDS AND THIS DEVICE DOES NOT.
// There is no pairing key, no drain cursor and no time anchor to persist —
// the envelope carries no clock and nothing here authenticates — so pairing
// is the plain notify-class flow (`HrsLink.pairNotifySensor`) and this file
// owns only the connect/run/disconnect a one-shot poll needs.
//
// NO DESTRUCTIVE COMMAND IS REACHABLE FROM HERE. This file writes nothing it
// did not get from a builder in `protocol`'s `lefun.dart`, and that module
// builds exactly one request (battery).

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/lefun.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired Lefun-protocol device. One instance; a second
/// concurrent ring is not a thing anyone asked for.
class LefunLink {
  LefunLink._();
  static final LefunLink instance = LefunLink._();

  /// The `device` row for the paired ring, or null.
  static Future<Map<String, Object?>?> pairedRowFor(String deviceId) async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['id'] == deviceId) return r;
    }
    return null;
  }

  BluetoothDevice? _device;

  /// Kept only so teardown can [GattBandLink.close] it — stops a write the
  /// adapter queued before teardown from landing on a LATER connection to the
  /// same device.
  GattBandLink? _link;

  /// The session driving [LefunAdapter] over [_link]. See `adapters/host.dart`.
  BandHost? _host;

  /// `device.id` of whichever paired row is CURRENTLY connected, or null
  /// between syncs. This is a singleton session over potentially several
  /// paired rows (`_sync` loops them one at a time), so a caller tearing down
  /// one specific row — `HrsLink.forgetDevice`'s Lefun branch — must check
  /// this before calling [stop]: stopping unconditionally would drop
  /// whichever OTHER row's sync happened to be live at that moment.
  ///
  /// ponytail: not exercised by a test — reaching the race this guards
  /// requires a genuinely concurrent forget-during-sync, which
  /// `flutter_blue_plus` has no simulator path to construct deterministically
  /// (the same reason `ingestForTest` below drives one session start to
  /// finish rather than leaving it live). Add one if this ever gets a second,
  /// non-radio way to hold a session open across an await.
  String? get currentDeviceId => _host?.deviceId;

  bool _busy = false;

  /// Connect to every paired Lefun-family device, poll battery, drain the
  /// bounded window each one's [LefunAdapter] opens, disconnect.
  ///
  /// Returns false when nothing is paired or every connect failed. Multiple
  /// paired rings are not a thing anyone asked for, but nothing here assumes
  /// there is exactly one, unlike `OuraLink`'s single ring.
  Future<bool> sync() {
    if (_busy) return Future.value(false);
    _busy = true;
    return _sync().whenComplete(() => _busy = false);
  }

  Future<bool> _sync() async {
    final rows = (await LocalDb.deviceRows())
        .where((r) => r['adapter_id'] == kLefun.id)
        .toList();
    if (rows.isEmpty) return false;
    var any = false;
    for (final row in rows) {
      if (await _syncOne(row)) any = true;
    }
    return any;
  }

  Future<bool> _syncOne(Map<String, Object?> row) async {
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      // The primary band's id, permanently. A ring writing under it would
      // interleave its seconds with the band's in one REPLACE-keyed table.
      debugPrint('[lefun] refusing to sync: the row claims the primary '
          'device id — re-pair it with a minted id.');
      return false;
    }
    try {
      // A cap on concurrent SECONDARY links (never the band's own connect —
      // see ble_state.dart's kMaxConcurrentSecondaryLinks doc). Connect,
      // drain and disconnect all complete inside this one call, so the
      // simple scoped form is correct here.
      //
      // THE TEARDOWN IS INSIDE THE CLOSURE, deliberately — held in an outer
      // `finally` it would run AFTER the slot had already been released, so
      // the next queued link could connect while this one was still
      // disconnecting.
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kLefun,
            services: services,
            onLog: (m) => debugPrint('[lefun] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kLefun.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[lefun] ${kLefun.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: LefunAdapter(),
            deviceId: deviceId,
            onLog: (m) => debugPrint('[lefun] $m'),
            onNote: (key, value) => debugPrint('[lefun] $key = $value'),
            buildArchive: _buildArchiveRow,
          );
          _host = host;
          await host.run(link);
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[lefun] sync failed: $e');
      return false;
    }
  }

  /// Drop the link, flush what the session can still stamp, disconnect.
  /// Safe to call when nothing is connected.
  Future<void> stop() async {
    // Before the host's run subscription is cancelled: an adapter's `finally`
    // can still write on the way out, and that write must not reach the radio.
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

  /// Bank one frame verbatim, decoded or not (owner rulings R1-R3): steps,
  /// sleep and PPG all ride this envelope undecoded, and the bytes are
  /// banked now so a decoder written later can be run over them.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    final f = parseLefunFrame(bytes);
    if (f == null) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL, not 0. This device has no flash-record counter in the envelope
      // itself, and `counter` is what `thinRawArchiveBefore` samples on — a 0
      // for every row would make every Lefun frame `0 % 60 == 0`, i.e.
      // permanently exempt, which is accidental policy.
      counter: null,
      packetType: f.report,
      // NULL, and it stays NULL. The envelope carries no clock.
      recTs: null,
      capturedAt: capturedAtMs,
      reason: 'lefun_report_0x${f.report.toRadixString(16).padLeft(2, '0')}',
    );
  }

  /// Replay a scripted device through the REAL [LefunAdapter] and the real
  /// write path. The only way in: the entry point is a BLE notification and
  /// `flutter_blue_plus` has no simulator path.
  @visibleForTesting
  Future<ReplayBandLink> ingestForTest(
    String deviceId,
    List<List<int>> Function(int writeIndex, List<int> value) reply, {
    Duration replyTimeout = const Duration(milliseconds: 50),
  }) async {
    final link = ReplayBandLink();
    final host = BandHost(
      adapter: LefunAdapter(replyTimeout: replyTimeout),
      deviceId: deviceId,
      onLog: (m) => debugPrint('[lefun] $m'),
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
          link.feed(kLefunNotifyChar, f, atSec: 0);
        }
        served++;
      }
    }
    await link.close();
    await done.timeout(const Duration(seconds: 2), onTimeout: () {});
    await host.stop();
    _host = null;
    return link;
  }
}
