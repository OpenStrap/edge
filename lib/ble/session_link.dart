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
import '../sync/reset_gate.dart';

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

  /// Bumped by every [stop]. A sync reads it before its first await and gives
  /// up once it has moved: [stop] can only reach a link and host that already
  /// exist, so a [forget] landing while the sync waits for a secondary-link
  /// slot, or while it connects, would otherwise let it connect afterwards and
  /// bank the forgotten device's readings under an id with no device row.
  int _stopGen = 0;
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
  /// A forgotten scale holds its weighing no more, so the profile weight it
  /// handed over goes back (rule R6) through the same hook.
  Future<bool> forget(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) return false;
    await stop();
    await LocalDb.deleteDevice(id);
    if (entry.category == DeviceCategory.healthMeasurement) {
      await onSessionDone?.call();
    }
    return true;
  }

  /// Run after a health-measurement device's session that connected (the app
  /// adopts a new weighing into the profile). Null in tests and headless runs.
  static Future<void> Function()? onSessionDone;

  /// Fires [onSessionDone] unless a reset started after [resetGen] was read:
  /// the reset that ended the session must not have it adopt a weighing from
  /// the deleted store back into the profile. A profile-side failure must not
  /// fail the device's session, and its re-derive does not hold the session
  /// open, so it is not awaited.
  @visibleForTesting
  static bool runSessionDone(int resetGen, {String tag = ''}) {
    if (ResetGate.changedSince(resetGen)) {
      debugPrint('$tag reset since the session started; no session-done hook.');
      return false;
    }
    unawaited(Future(() => onSessionDone?.call()).catchError(
        (Object e) => debugPrint('$tag session-done hook failed: $e')));
    return true;
  }

  /// One session with the paired device. False when nothing is paired, the
  /// connect failed, or a session is already running.
  Future<bool> sync() async {
    if (_busy) return false;
    _busy = true;
    // Read before the session: a reset stops it, and a stopped session still
    // returns true once it had connected.
    final resetGen = ResetGate.generation;
    try {
      final ok = await _sync();
      if (ok && entry.category == DeviceCategory.healthMeasurement) {
        runSessionDone(resetGen, tag: _tag);
      }
      return ok;
    } finally {
      _busy = false;
    }
  }

  Future<bool> _sync() async {
    // Read before any await: [stop] only reaches a link and host that already
    // exist, so a connect still in flight when "delete everything" stopped
    // this session would otherwise finish later and bank the deleted device's
    // frames into the fresh store.
    final resetGen = ResetGate.generation;
    final stopGen = _stopGen;
    bool stopped() => ResetGate.changedSince(resetGen) || _stopGen != stopGen;
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
        if (stopped()) {
          debugPrint('$_tag stopped while waiting for a link slot; not syncing.');
          return false;
        }
        final device = BluetoothDevice.fromId(remoteId);
        try {
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          if (stopped()) {
            debugPrint('$_tag stopped during connect; not syncing.');
            return false;
          }
          final link = GattBandLink(
            entry: entry,
            services: services,
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
          final host = _makeHost(deviceId, _now, resetGeneration: resetGen);
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
    _stopGen++;
    _link?.close();
    _link = null;
    await _host?.stop();
    _host = null;
  }

  BandHost _makeHost(String deviceId, int Function() now,
          {int? resetGeneration}) =>
      BandHost(
        adapter: _adapter(now),
        deviceId: deviceId,
        resetGeneration: resetGeneration,
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
