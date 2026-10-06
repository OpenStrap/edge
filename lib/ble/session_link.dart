// THE HOST for a short-session notify device — connect by stored remote id,
// drive its adapter once, commit what it decoded and bank every frame
// verbatim, disconnect. One class instead of a copy per device: the
// thermometer and the Mi scales differ only in their [BandEntry] and adapter.
//
// Same ordering as every per-family link (`colmi_link.dart`,
// `pebble_link.dart`): refuse the primary device id, take the secondary-link
// slot, check required characteristics, run, and disconnect BEFORE the slot
// is released.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart' show BandAdapter, ReplayBandLink;
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/miscale.dart';
import 'adapters/thermometer.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

class SessionLink {
  SessionLink._(this.entry, this._adapter);

  static final SessionLink thermometer = SessionLink._(
      kThermometer, (now) => ThermometerAdapter(nowSeconds: now));
  static final SessionLink miScaleComposition = SessionLink._(
      kMiScaleComposition, (now) => MiScaleAdapter(kMiScaleComposition, nowSeconds: now));
  static final SessionLink miScale2 = SessionLink._(
      kMiScale2, (now) => MiScaleAdapter(kMiScale2, nowSeconds: now));

  /// Every short-session device, for the background pass and the forget path.
  static final List<SessionLink> all = [thermometer, miScaleComposition, miScale2];

  /// The link for a registry id, or null.
  static SessionLink? forId(String? adapterId) {
    for (final l in all) {
      if (l.entry.id == adapterId) return l;
    }
    return null;
  }

  final BandEntry entry;
  final BandAdapter Function(int Function() now) _adapter;

  /// Upper bound on one session, whatever the adapter waits for.
  static const Duration window = Duration(seconds: 60);

  bool _busy = false;
  BandHost? _host;
  GattBandLink? _link;

  String get _tag => '[${entry.id}]';

  int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == entry.id) return r;
    }
    return null;
  }

  /// Forget a paired device: stop any live session, drop its `device` row.
  Future<bool> forget(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) return false;
    await stop();
    await LocalDb.deleteDevice(id);
    return true;
  }

  /// One session with the paired device. False when nothing is paired, the
  /// connect failed, or a session is already running.
  Future<bool> sync() {
    if (_busy) return Future.value(false);
    _busy = true;
    return _sync().whenComplete(() => _busy = false);
  }

  Future<bool> _sync() async {
    try {
      final row = await pairedRow();
      final deviceId = row?['id'] as String?;
      final remoteId = row?['remote_id'] as String?;
      if (deviceId == null || remoteId == null || remoteId.isEmpty) {
        return false;
      }
      if (deviceId == LocalDb.kPrimaryDeviceId) {
        debugPrint('$_tag refusing to sync: the row claims the primary id.');
        return false;
      }
      return await withSecondaryLinkSlot(() async {
        final device = BluetoothDevice.fromId(remoteId);
        try {
          await device.connect(timeout: const Duration(seconds: 20));
          final link = GattBandLink(
            entry: entry,
            services: await device.discoverServices(),
            onLog: (m) => debugPrint('$_tag $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(entry.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('$_tag missing required characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = _makeHost(deviceId, _now);
          _host = host;
          await host.run(link).timeout(window, onTimeout: () {});
          return true;
        } catch (e) {
          debugPrint('$_tag session failed: $e');
          return false;
        } finally {
          await stop();
          try {
            await device.disconnect();
          } catch (_) {/* already gone */}
        }
      });
    } catch (e) {
      debugPrint('$_tag sync failed: $e');
      return false;
    }
  }

  Future<void> stop() async {
    _link?.close();
    _link = null;
    await _host?.stop();
    _host = null;
  }

  BandHost _makeHost(String deviceId, int Function() now) => BandHost(
        adapter: _adapter(now),
        deviceId: deviceId,
        onLog: (m) => debugPrint('$_tag $m'),
        buildArchive: (bytes, capturedAtMs) => ArchiveRecord(
          hex: bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
          counter: null,
          packetType: bytes.isNotEmpty ? bytes[0] : 0,
          recTs: null,
          capturedAt: capturedAtMs,
          reason: '${entry.id}_frame',
        ),
        nowSeconds: now,
      );

  /// Replay a scripted device through the REAL adapter, host and sqlite.
  /// [pushes] are notifications the device sends unprompted, delivered after
  /// the session starts; [reply] answers each write with notifications.
  @visibleForTesting
  Future<ReplayBandLink> ingestForTest(
    String deviceId, {
    required int Function() nowSeconds,
    List<(String uuid, List<int> value)> pushes = const [],
    List<(String uuid, List<int> value)> Function(String uuid, List<int> value)?
        reply,
  }) async {
    final link = ReplayBandLink();
    final host = _makeHost(deviceId, nowSeconds);
    _host = host;
    var finished = false;
    final done = host.run(link).whenComplete(() => finished = true);
    var served = 0, pushed = false;
    for (var spin = 0; spin < 4000 && !finished; spin++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!pushed) {
        for (final (uuid, v) in pushes) {
          link.feed(uuid, v, atSec: nowSeconds());
        }
        pushed = true;
      }
      while (served < link.writes.length) {
        final (uuid, value) = link.writes[served++];
        final answers = reply?.call(uuid, value) ??
            const <(String, List<int>)>[];
        for (final (u, v) in answers) {
          link.feed(u, v, atSec: nowSeconds());
        }
      }
    }
    await link.close();
    await done.timeout(const Duration(seconds: 5), onTimeout: () {});
    await host.stop();
    _host = null;
    return link;
  }
}
