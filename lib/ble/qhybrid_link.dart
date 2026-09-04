// Fossil/Skagen Q Hybrid: pairing IS the one session this band gets.
//
// WHY THIS FILE EXISTS. A heart-rate strap is driven by `HrsLink.arm()`,
// which a workout starts and stops. Oura has its own background sync,
// re-runnable from the ring's own page (`OuraLink`). This band has neither —
// nothing derives from it (`QHybridAdapter.signals` is empty) so there is no
// workout to arm it for, and no ongoing number to keep fresh so there is
// nothing to "sync". Writing only the `device` row (what
// `HrsLink.pairNotifySensor` does on its own) would leave `QHybridAdapter`
// undriven from the moment that row exists: `BandHost` never archives a byte
// without a `buildArchive` callback (`adapters/host.dart`'s own
// `_bufferArchive`), and nothing else in this app ever constructs a
// `BandHost` for this adapter. So pairing has to be the session, or the
// adapter this file exists to drive never actually runs.
//
// BEST-EFFORT, AND BOUNDED. [pairQHybrid] returns as soon as the `device` row
// is written — the same promise `pairNotifySensor` already makes elsewhere —
// and the drain that follows cannot fail that promise: nothing here can
// un-pair a device that answered the moment ago. The drain itself is capped
// at [_kDrainWindow]; an unbounded live link nobody is watching a spinner for
// is a battery cost and a scan/connect fight with the primary band, the same
// reason `HrsLink` disarms the moment a workout ends.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;

import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart' show kQHybrid;
import 'adapters/gatt_link.dart';
import 'adapters/host.dart';
import 'adapters/qhybrid.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;
import 'hrs_link.dart' show HrsLink;

/// How long the post-pairing session stays connected banking notifications.
const Duration _kDrainWindow = Duration(seconds: 10);

/// Pair a Fossil/Skagen Q Hybrid, then drive one bounded session over it so
/// pairing means more than a `device` row — see this file's own header.
Future<String?> pairQHybrid(BluetoothDevice device, {String? label}) async {
  final failure =
      await HrsLink.pairNotifySensor(kQHybrid, device, label: label);
  if (failure != null) return failure;
  unawaited(_drainOnce(device));
  return null;
}

Future<void> _drainOnce(BluetoothDevice device) async {
  try {
    await withSecondaryLinkSlot<void>(
      () async {
        await device.connect(timeout: const Duration(seconds: 12));
        GattBandLink? link;
        try {
          final services = await device.discoverServices();
          final localLink = GattBandLink(
            entry: kQHybrid,
            services: services,
            onLog: (m) => debugPrint('[qhybrid] $m'),
          );
          link = localLink;
          if (localLink
              .missingCharacteristics(kQHybrid.requiredCharacteristics)
              .isNotEmpty) {
            return;
          }
          final host = BandHost(
            adapter: kQHybridAdapter,
            deviceId: HrsLink.mintDeviceId(kQHybrid, device.remoteId.str),
            onLog: (m) => debugPrint('[qhybrid] $m'),
            buildArchive: _buildArchiveRow,
          );
          final runFuture = host.run(localLink);
          // Whichever finishes first: the adapter abstaining on its own (no
          // probe reply) or the bounded window running out on a confirmed,
          // still-open session. `stop()` is safe either way — `BandHost`'s
          // own doc says so, and it is what flushes whatever this drain
          // banked before the link goes down.
          await Future.any(
              [runFuture, Future<void>.delayed(_kDrainWindow)]);
          await host.stop();
          await runFuture;
        } finally {
          link?.close();
          try {
            await device.disconnect();
          } catch (_) {
            // already gone
          }
        }
      },
      timeout: const Duration(seconds: 5),
      onTimeout: () => debugPrint(
          '[qhybrid] another sensor held the radio; skipping this drain.'),
    );
  } catch (e) {
    // Best-effort, and the pairing above already succeeded regardless — see
    // the header. A watch out of range a moment after pairing is not an
    // error the person who just paired it needs to see.
    debugPrint('[qhybrid] post-pair drain did not complete: $e');
  }
}

/// Bank one frame verbatim, undecoded (owner rulings R1-R3).
///
/// `reason` names the BAND, not the characteristic: six of them share this
/// one archive path and, unlike Oura's frames (which carry their own type
/// byte — see `oura_link.dart`'s `_buildArchiveRow`), qhybrid's do not
/// self-identify which characteristic produced them. Recovering that per
/// frame needs a source tag threaded through `SampleBatch`/`BandHost` itself
/// — a shared-seam change every multi-characteristic notify adapter would
/// benefit from, not something this one band's archive builder can invent on
/// its own — so it is left for that change rather than guessed at here.
ArchiveRecord _buildArchiveRow(List<int> bytes, int capturedAtMs) =>
    ArchiveRecord(
      hex: _hex(bytes),
      counter: null,
      packetType: bytes.isNotEmpty ? bytes[0] : 0,
      recTs: null,
      capturedAt: capturedAtMs,
      reason: 'qhybrid_raw',
    );

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
