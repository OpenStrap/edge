// The HOST for a paired DaFit/MOYOUNG-V2 clone watch: connect, hold the
// session open just long enough to run the handshake and catch whatever the
// band sends, bank it, disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). `DafitAdapter.signals` is
// `const {}` and `dafit` is absent from `kDerivableSources` — every row this
// file writes carries a non-null `source`, and nothing here becomes a number.
//
// WHY A BOUNDED WINDOW, NOT FETCH-BY-CURSOR OR ARM/DISARM. This family has no
// stored-history request this project decodes and no live-during-workout
// role, so there is no natural end-of-session signal the way Oura's
// `bytesLeft == 0` or a workout screen's stop button gives one — the adapter
// itself just holds the notify subscription open for as long as the link
// lives. A fixed window is the honest floor: long enough to run the eight-
// frame handshake and catch anything the band sends during it, short enough
// to fit inside the same background wake slot as the primary band's own
// sync, right after it.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show kDafitAckHeader;

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart' show ReplayBandLink;
import 'adapters/dafit.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired dafit/moyoung watch. One instance; a second
/// concurrent one is not a thing anyone asked for.
class DafitLink {
  DafitLink._();
  static final DafitLink instance = DafitLink._();

  /// How long one session holds the link open once connected. Bounded rather
  /// than open-ended — see the header note.
  static const Duration _sessionWindow = Duration(seconds: 8);

  /// The `device` row for the paired watch, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kDafit.id) return r;
    }
    return null;
  }

  /// Forget a paired watch: drop its `device` row. No key to drop — see the
  /// registry entry's own doc on why this family needs none.
  static Future<bool> forget(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[dafit] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) await instance.stop();
    await LocalDb.deleteDevice(id);
    return true;
  }

  BluetoothDevice? _device;

  /// Kept only so teardown can [GattBandLink.close] it — that is what stops a
  /// write the adapter queued before teardown from landing on a LATER
  /// connection to the same watch.
  GattBandLink? _link;

  /// The session driving [DafitAdapter] over [_link] — see `adapters/host.dart`.
  BandHost? _host;

  /// `device.id` of the paired watch. Never [LocalDb.kPrimaryDeviceId].
  String? _deviceId;

  bool _busy = false;

  /// Connect to the paired watch, hold the session for [_sessionWindow],
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
      debugPrint('[dafit] refusing to sync: the row claims the primary '
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
            entry: kDafit,
            services: services,
            onLog: (m) => debugPrint('[dafit] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kDafit.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[dafit] ${kDafit.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = _makeHost(deviceId, const DafitAdapter());
          _host = host;
          // The adapter holds this open for as long as the link lives — see
          // the header note — so this session is bounded here, not by
          // anything the band or the adapter itself signals.
          await host.run(link).timeout(_sessionWindow, onTimeout: () {});
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[dafit] sync failed: $e');
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

  /// Build this session's [BandHost]. One place, so `_sync()` and
  /// [ingestForTest] cannot drift on what each callback does.
  BandHost _makeHost(String deviceId, DafitAdapter adapter) => BandHost(
        adapter: adapter,
        deviceId: deviceId,
        onLog: (m) => debugPrint('[dafit] $m'),
        buildArchive: _buildArchiveRow,
      );

  /// Replay a scripted watch through the REAL [DafitAdapter] and the real
  /// write path, over the SAME [BandHost] wiring `_sync` uses. The only way
  /// in: the entry point is a BLE notification and `flutter_blue_plus` has no
  /// simulator path, so without this seam nothing below `sync()`'s connect
  /// call — `_buildArchiveRow`'s counter/reason mapping and the commit
  /// through [LocalDb.commitSyncBatch] — could be exercised at all.
  @visibleForTesting
  Future<ReplayBandLink> ingestForTest(
    String deviceId,
    DateTime Function() now,
    List<(int, List<int>)> notifications,
  ) async {
    _deviceId = deviceId;
    final link = ReplayBandLink();
    final host = _makeHost(
      deviceId,
      DafitAdapter(now: now, handshakePause: Duration.zero),
    );
    _host = host;
    final done = host.run(link);
    await Future<void>.delayed(Duration.zero); // let notify() subscribe
    for (final (atSec, value) in notifications) {
      link.feed(kDafitNotifyChar, value, atSec: atSec);
      // One microtask turn per notification, so each is fully archived
      // (and, where ackable, its ack write started) before the next is
      // delivered — feeding them back-to-back races the single-subscription
      // channel's own dispatch against the adapter's `archived`/`flush`
      // bookkeeping.
      await Future<void>.delayed(Duration.zero);
    }
    // Close, then wait for `run()` to actually finish, rather than guessing
    // at a delay: the adapter's `await for` is asynchronous and a flush
    // racing it would silently drop the tail.
    await link.close();
    await done;
    await host.stop();
    _host = null;
    return link;
  }

  /// Bank one frame verbatim, decoded or not — this family's decode coverage
  /// is deliberately zero (see `dafit.dart`'s own header), so the bytes are
  /// archived now rather than a guess being run over them today.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    if (bytes.isEmpty) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL, not 0. This band has no flash-record counter this project
      // reads, and `counter` is what `thinRawArchiveBefore` samples on — a
      // constant 0 would make every one of this family's frames `0 % 60 ==
      // 0`, i.e. permanently exempt from thinning, which is accidental policy.
      counter: null,
      packetType: bytes[0],
      recTs: null,
      capturedAt: capturedAtMs,
      // Two reasons, not one: an ack-shaped frame and a data frame are
      // different things to a future decoder, and splitting them now costs
      // nothing. Neither is in `LocalDb.redrivableArchiveReasons` — there is
      // no decoder for this family yet to redrive them through.
      reason: bytes[0] == kDafitAckHeader ? 'dafit_ack' : 'dafit_frame',
    );
  }
}
