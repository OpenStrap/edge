// The HOST for a paired Garmin watch: connect, drive [GarminAdapter] over
// the link for one bounded session, bank what comes back, disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). `GarminAdapter.signals`
// declares `hrSparse` (monitoring HR, about once a minute) and `garmin` is
// absent from `kDerivableSources` — every row this file writes carries a
// non-null `source`, and none of it feeds a derived number.
//
// THE SESSION: the adapter reads the watch's file directory, downloads every
// health FIT file (monitoring, sleep, HRV status) it has not read yet, and
// decodes them into sparse HR samples, the watch's hypnogram, daily steps
// and attributed vendor observations. What it has read is kept per file
// (index, timestamp, size) in `sync_cursor` under [_cursorItem], so a file
// that grew is read again and one that failed is retried. The session ends
// when the queue drains, or at the adapter's bounded window. The numbered
// real-time streams stay untouched.
//
// PAIRING IS THE WATCH'S OWN MENU, NOT A KEY THIS FILE INSTALLS. Unlike the
// Oura ring, GFDI has no pairing-time credential exchange this pass
// implements — the watch has to be put into its own Settings -> Sensors &
// Accessories -> Phone -> Pair Phone screen before the OS-level bond this
// app's ordinary connect triggers will be accepted at all. That precondition
// is stated in the picker's blurb (`devices.dart`), the same way Oura's
// factory-reset precondition is — surfaced before the user commits, not
// discovered after a silent timeout.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart' show ReplayBandLink;
import 'adapters/garmin.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// `sync_cursor` name for the health FIT files already read.
String _cursorItem(String deviceId) => 'garmin_fit_files:$deviceId';

/// Every characteristic under the multi-link service, as lowercase 128-bit
/// UUIDs — what `garminMlPair` chooses from. Empty when the service is
/// absent.
List<String> garminMlCharsOf(List<BluetoothService> services) => [
      for (final s in services)
        if (s.uuid == Guid(kGarminService))
          for (final c in s.characteristics) c.uuid.str128,
    ];

/// The live link to a paired Garmin watch. One instance; a second concurrent
/// one is not a thing anyone asked for.
class GarminLink {
  GarminLink._();
  static final GarminLink instance = GarminLink._();

  /// The `device` row for the paired watch, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kGarmin.id) return r;
    }
    return null;
  }

  /// Forget a paired watch: drop its `device` row. No key to drop — this
  /// family's session has no pairing-time credential this app installs.
  static Future<bool> forget(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[garmin] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) await instance.stop();
    await LocalDb.deleteDevice(id);
    return true;
  }

  /// The most recent battery reading the watch reported, or null. Not
  /// written to `band_battery` — same reasoning as `OuraLink`'s own doc:
  /// that table has no `device_id` and is read unfiltered, so a second
  /// device's cell voltage would land in the primary band's own series.
  int? get batteryPct => _batteryPct;
  int? _batteryPct;

  String? get model => _model;
  String? get firmware => _firmware;
  String? _model;
  String? _firmware;

  BluetoothDevice? _device;

  /// Kept only so teardown can [GattBandLink.close] it — that is what stops a
  /// write the adapter queued before teardown from landing on a LATER
  /// connection to the same watch.
  GattBandLink? _link;

  /// The session driving [GarminAdapter] over [_link] — see `adapters/host.dart`.
  BandHost? _host;

  /// `device.id` of the paired watch. Never [LocalDb.kPrimaryDeviceId].
  String? _deviceId;

  bool _busy = false;

  /// Connect to the paired watch, hold the session for its bounded window,
  /// disconnect.
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
    final row = await pairedRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      debugPrint('[garmin] refusing to sync: the row claims the primary '
          'device id — re-pair it with a minted id.');
      return false;
    }
    _deviceId = deviceId;

    try {
      // A cap on concurrent SECONDARY links (never the band's own connect —
      // see ble_state.dart's kMaxConcurrentSecondaryLinks doc). This sync's
      // connect, session and disconnect all complete inside this one call, so
      // the simple scoped form is correct here.
      //
      // THE TEARDOWN IS INSIDE THE CLOSURE, deliberately — held in an outer
      // `finally` it would run AFTER `withSecondaryLinkSlot` had already
      // released the slot, letting the next queued link connect while this
      // one was still disconnecting.
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kGarmin,
            services: services,
            onLog: (m) => debugPrint('[garmin] $m'),
          );
          _link = link;
          final ml = garminMlCharsOf(services);
          if (garminMlPair(ml) == null) {
            debugPrint('[garmin] ${kGarmin.label}: no multi-link data '
                'characteristic under ${kGarminService.substring(0, 8)}.');
            return false;
          }
          final host = _makeHost(
              deviceId,
              GarminAdapter(
                readFiles: await LocalDb.getCursor(_cursorItem(deviceId)) ?? '',
                mlChars: ml,
                maxWrite: device.mtuNow - 3,
              ));
          _host = host;
          await host.run(link);
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[garmin] sync failed: $e');
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
    _readFiles = null;
    _deviceId = null;
    final d = _device;
    _device = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {/* already gone */}
    }
  }

  BandHost _makeHost(String deviceId, GarminAdapter adapter) => BandHost(
        adapter: adapter,
        deviceId: deviceId,
        onLog: (m) => debugPrint('[garmin] $m'),
        onNote: _handleNote,
        buildArchive: _buildArchiveRow,
        // The read-file list is folded into the SAME commit transaction as
        // the samples decoded from those files, so a file can never be
        // recorded as read by a commit its own rows did not survive.
        extraCursors: () => _readFiles == null
            ? const {}
            : {_cursorItem(deviceId): _readFiles!},
      );

  /// The adapter's latest read-file list; written only by a host commit.
  String? _readFiles;

  void _handleNote(String key, Object? value) {
    switch (key) {
      case 'garmin_fit_files':
        // Read back by `_makeHost`'s `extraCursors` at the next commit,
        // never written on its own.
        if (value is String) _readFiles = value;
      case 'battery':
        if (value is int) _batteryPct = value;
      case 'model':
        if (value is String) _model = value;
      case 'firmware':
        if (value is String) _firmware = value;
      default:
        debugPrint('[garmin] $key = $value');
    }
  }

  /// Replay a scripted watch through the REAL [GarminAdapter], host and
  /// sqlite. [reply] answers each write on the write characteristic with
  /// notifications on the notify characteristic.
  @visibleForTesting
  Future<ReplayBandLink> ingestForTest(
    String deviceId,
    List<List<int>> Function(List<int> written) reply, {
    required int Function() nowSeconds,
  }) async {
    _deviceId = deviceId;
    final link = ReplayBandLink();
    final host = _makeHost(
        deviceId,
        GarminAdapter(
          nowSeconds: nowSeconds,
          handshakeTimeout: const Duration(milliseconds: 200),
          configWait: const Duration(milliseconds: 50),
          sessionWindow: const Duration(seconds: 10),
          registerTimeout: const Duration(milliseconds: 200),
          notReadyDelay: const Duration(milliseconds: 10),
          readFiles: await LocalDb.getCursor(_cursorItem(deviceId)) ?? '',
        ));
    _host = host;
    var finished = false;
    final done = host.run(link).whenComplete(() => finished = true);
    var served = 0;
    for (var spin = 0; spin < 4000 && !finished; spin++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      while (served < link.writes.length) {
        for (final n in reply(link.writes[served++].$2)) {
          link.feed(kGarminNotifyChar, n, atSec: nowSeconds());
        }
      }
    }
    await link.close();
    await done.timeout(const Duration(seconds: 5), onTimeout: () {});
    await host.stop();
    _host = null;
    _readFiles = null;
    _deviceId = null;
    return link;
  }

  /// Bank one frame verbatim, decoded or not — every GFDI frame and every
  /// control frame this session sees, so what the adapter does not decode
  /// is archived rather than guessed at.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    if (bytes.isEmpty) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL: this band has no flash-record counter this project reads, and
      // `counter` is what `thinRawArchiveBefore` samples on — a constant 0
      // would make every one of this family's frames permanently exempt
      // from thinning, which is accidental policy.
      counter: null,
      packetType: bytes[0],
      recTs: null,
      capturedAt: capturedAtMs,
      reason: 'garmin_frame',
    );
  }
}
