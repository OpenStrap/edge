// The HOST for Withings Steel HR / Activité: read the per-device
// `firstConnect` flag, connect, drive [WithingsSteelHrAdapter] over the
// link, archive verbatim, flip the flag off after the first successful
// session, disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). The registry entry stays
// EXPERIMENTAL, `WithingsSteelHrAdapter.signals` stays `const {}`, and
// nothing this file writes becomes a number.
//
// NO KEY, NO CURSOR, NO ANCHOR — the things `oura_link.dart` owns that this
// file does not need. The SHA1 secret is a fixed constant, not a per-device
// credential (see `withings_steel_hr.dart`), and there is no history to
// bookmark: every reassembled message after the handshake is archived, and
// the device is never asked for anything past that.
//
// THE FIRST-CONNECT FLAG is the one piece of session state this band needs
// persisted. It lives in `sync_cursor`, not the `device` row, because it is
// exactly that: a bookmark, one bit wide. It starts true on a fresh pairing
// and flips false only once a session has actually reached the point of
// being considered authenticated (the adapter's own `withings_session_ready`
// note) — never merely because a connection was attempted.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import '../sync/paired_device.dart' show cleanDeviceLabel;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/withings_steel_hr.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;
import 'hrs_link.dart' show HrsLink;

/// `sync_cursor` name for one device's first-connect flag.
String _firstConnectItem(String deviceId) =>
    'withings_steel_hr_first_connect:$deviceId';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired Steel HR / Activité. One instance; a second
/// concurrent device of this kind is not a thing anyone asked for.
class WithingsSteelHrLink {
  WithingsSteelHrLink._();
  static final WithingsSteelHrLink instance = WithingsSteelHrLink._();

  /// The `device` row for the paired watch, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kWithingsSteelHr.id) return r;
    }
    return null;
  }

  /// Forget a paired watch: drop its `device` row. There is no stored
  /// secret to drop alongside it — see the file header.
  static Future<bool> forgetDevice(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[withings_steel_hr] refusing to forget the primary band '
          'from here.');
      return false;
    }
    if (instance._deviceId == id) await instance.stop();
    await LocalDb.deleteDevice(id);
    return true;
  }

  BluetoothDevice? _device;
  GattBandLink? _link;
  BandHost? _host;
  String? _deviceId;
  bool _busy = false;

  /// Set by the adapter's `withings_session_ready` note. Read once, right
  /// after `host.run()` returns, to decide whether THIS session earns the
  /// `firstConnect` flag being cleared — never on the strength of merely
  /// having attempted a connection.
  bool _sessionReady = false;

  /// Connect to the paired watch, run the handshake, archive whatever
  /// arrives until the link ends, disconnect.
  ///
  /// SERIALISED: a second call while one is in flight is a no-op rather than
  /// a second radio session over the same peripheral.
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
      // The primary band's id, permanently. A secondary device writing under
      // it would interleave its rows with the band's in one REPLACE-keyed
      // table.
      debugPrint('[withings_steel_hr] refusing to sync: the row claims the '
          'primary device id — re-pair it with a minted id.');
      return false;
    }
    _deviceId = deviceId;
    _sessionReady = false;
    final firstConnect =
        (await LocalDb.getCursor(_firstConnectItem(deviceId))) != '0';

    try {
      // A cap on concurrent SECONDARY links (never the band's own connect —
      // see ble_state.dart's kMaxConcurrentSecondaryLinks doc). Connect,
      // drain and disconnect all complete inside this one call, so the
      // simple scoped form is correct here.
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kWithingsSteelHr,
            services: services,
            onLog: (m) => debugPrint('[withings_steel_hr] $m'),
          );
          _link = link;
          final missing = link.missingCharacteristics(
              kWithingsSteelHr.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[withings_steel_hr] ${kWithingsSteelHr.label}: '
                'missing required characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = _makeHost(
              deviceId, WithingsSteelHrAdapter(firstConnect: firstConnect));
          _host = host;
          await host.run(link);
          if (firstConnect && _sessionReady) {
            await LocalDb.setCursor(_firstConnectItem(deviceId), '0');
          }
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[withings_steel_hr] sync failed: $e');
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

  BandHost _makeHost(String deviceId, WithingsSteelHrAdapter adapter) =>
      BandHost(
        adapter: adapter,
        deviceId: deviceId,
        onLog: (m) => debugPrint('[withings_steel_hr] $m'),
        onNote: (key, value) {
          if (key == 'withings_session_ready') _sessionReady = true;
        },
        buildArchive: _buildArchiveRow,
      );

  /// Bank one reassembled message verbatim, undecoded (owner rulings
  /// R1-R3): every activity/sleep/heart-rate/workout structure is out of
  /// scope for this device, and the bytes are banked now so a decoder
  /// written when someone owns one can be run over them.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    final msg = parseWithingsMessage(Uint8List.fromList(bytes));
    if (msg == null) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL, not 0. This band has no flash-record counter of its own, and
      // `counter` is what `thinRawArchiveBefore` samples on — a 0 for every
      // row would make every one of this band's frames permanently exempt.
      counter: null,
      packetType: msg.type,
      // NULL: nothing here decodes a record time out of the payload.
      recTs: null,
      capturedAt: capturedAtMs,
      // ONE REASON PER MESSAGE TYPE, so a decoder written later finds its
      // records by name. NOT in `LocalDb.redrivableArchiveReasons`,
      // deliberately and permanently — that redrive path replays a row's hex
      // through the WHOOP R24 chain, which would be the wrong decoder over
      // the right bytes.
      reason: 'withings_msg_0x${msg.type.toRadixString(16).padLeft(2, '0')}',
    );
  }

  /// Replay a scripted watch through the REAL [WithingsSteelHrAdapter] and
  /// the real write path. The only way in: the entry point is a BLE
  /// notification and `flutter_blue_plus` has no simulator path.
  @visibleForTesting
  Future<ReplayBandLink> ingestForTest(
    String deviceId,
    bool firstConnect,
    List<List<int>> Function(int writeIndex, List<int> value) reply, {
    Duration timeouts = const Duration(milliseconds: 50),
  }) async {
    _deviceId = deviceId;
    _sessionReady = false;
    final link = ReplayBandLink();
    final host = _makeHost(
      deviceId,
      WithingsSteelHrAdapter(firstConnect: firstConnect, replyTimeout: timeouts),
    );
    _host = host;
    var finished = false;
    final done = host.run(link).whenComplete(() => finished = true);
    var served = 0;
    for (var spin = 0; spin < 800 && !finished; spin++) {
      await Future<void>.delayed(Duration.zero);
      while (served < link.writes.length) {
        for (final f in reply(served, link.writes[served].$2)) {
          link.feed(kWithingsWriteChar, f, atSec: 1786000000);
        }
        served++;
      }
    }
    await link.close();
    await done.timeout(const Duration(seconds: 2), onTimeout: () {});
    if (firstConnect && _sessionReady) {
      await LocalDb.setCursor(_firstConnectItem(deviceId), '0');
    }
    await host.stop();
    _host = null;
    _deviceId = null;
    return link;
  }
}

/// Pair [device] as a Steel HR / Activité: connect, discover, run the
/// no-auth first-connect init, upsert the `device` row with `firstConnect`
/// true. No key round trip — there is nothing to store — so this is simpler
/// than `pairOuraRing`.
Future<String?> pairWithingsSteelHr(BluetoothDevice device) async {
  final deviceId = HrsLink.mintDeviceId(kWithingsSteelHr, device.remoteId.str);
  GattBandLink? link;
  try {
    return await withSecondaryLinkSlot<String?>(
      timeout: const Duration(seconds: 30),
      onTimeout: () => 'Another sensor is using this phone’s Bluetooth right '
          'now. Try pairing again in a moment.',
      () async {
        try {
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final localLink = GattBandLink(
            entry: kWithingsSteelHr,
            services: services,
            onLog: (m) => debugPrint('[withings_steel_hr pair] $m'),
          );
          link = localLink;
          final missing = localLink.missingCharacteristics(
              kWithingsSteelHr.requiredCharacteristics);
          if (missing.isNotEmpty) {
            return 'That device does not expose the service this app speaks.';
          }
          final ok = await localLink.write(
            kWithingsWriteChar,
            buildWithingsMessage(kWithingsMsgInitialConnect, const []),
          );
          if (!ok) {
            return 'That device would not accept a command. Try again with '
                'it on the charger and next to the phone.';
          }
          await LocalDb.upsertDevice(
            id: deviceId,
            adapterId: kWithingsSteelHr.id,
            remoteId: device.remoteId.str,
            label:
                cleanDeviceLabel(device.platformName) ?? kWithingsSteelHr.label,
          );
          return null;
        } finally {
          link?.close();
          try {
            await device.disconnect();
          } catch (_) {/* already gone */}
        }
      },
    );
  } catch (e) {
    debugPrint('[withings_steel_hr pair] failed: $e');
    return 'Could not connect to that device.';
  }
}
