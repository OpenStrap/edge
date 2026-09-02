part of 'ble_engine.dart';

// M2 §15: the device-blind radio half of `BleEngine`, extracted verbatim
// (bodies and comments unchanged — a move, not a rewrite). A `part of` file
// rather than a standalone library so these methods keep reading BleEngine's
// existing private fields/methods exactly as they did inside the class body;
// Dart privacy is per-library, not per-class, so this is a real code motion
// with zero behavior change, not a reimplementation.
//
// Extends [BleEngine] via an extension rather than reopening the class body
// (Dart does not allow splitting one class's declaration across files) — the
// methods below are still `BleEngine` instance methods in every way that
// matters to a caller.
extension BleEngineTransport on BleEngine {
  // ── scan ─────────────────────────────────────────────────────────────────────
  /// Service-filtered scan (mandatory on iOS/macOS — passive scans hide the UUID).
  /// Start ONE scan, stop early on a match, otherwise let the timeout stop it.
  /// NEVER rapid start/stop (Android throttles → SCANNING_TOO_FREQUENTLY).
  ///
  /// Serialised process-wide through [withScanLock]: the HR-sensor scan shares
  /// this one radio scanner, and the `isScanning == false` await below is
  /// satisfied by ITS `stopScan` too — an unserialised scan silently ends
  /// having seen nothing and reports "No band found".
  Future<BluetoothDevice?> scan({
    Duration timeout = const Duration(seconds: 12),
  }) =>
      withScanLock(() => _scanLocked(timeout));

  Future<BluetoothDevice?> _scanLocked(Duration timeout) async {
    // A phone-level blocker is NOT "nothing answered". Returning null for a
    // revoked Bluetooth permission classified it as `notFound` upstream, which
    // told the user to walk closer to a band that was never the problem — the
    // one fix that cannot work. Check the adapter BEFORE scanning and throw,
    // so the reason reaches the caller instead of being flattened into a null.
    final pre = await _detectBlocker();
    if (pre != null) {
      _noteBlocker(pre);
      _setPhase(BleConnState.idle);
      throw BleUnavailableException(pre);
    }
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    _setPhase(BleConnState.scanning);
    // Advertise-filter on every FRAMED band's service UUID plus the 16-bit
    // WHOOP member UUID fallback. This is an OS-LEVEL filter: a device whose
    // service is not in this list is invisible to the callback below, so the
    // registry — not a literal here — is what decides which bands can be seen
    // at all. The actual band is pinned later at discovery.
    //
    // [kFramedBands], not the whole registry: this is the "find my band" scan,
    // and a notify-only sensor that matched here would be handed to
    // `_doConnect`, which would then talk WHOOP at it.
    //
    // The 16-bit member UUID (kWhoopMemberUuid16) is a WHOOP-only fallback for
    // a 128-bit vendor UUID hidden in the scan-response overflow area — see
    // [whoopScanServiceUuids] / [advertisementLooksLikeWhoop]'s doc comment.
    final wanted = [
      for (final e in kFramedBands) Guid(e.service),
      Guid(kWhoopMemberUuid16),
    ];
    // ACCEPTANCE stays broad (#255) — the match below. The GENERATION HINT is
    // narrower: only an advertised 128-bit service names a generation
    // ([ScanAcceptPolicy]); a name-only or 16-bit-only match records no hint,
    // and the connect path then probes the official gen5 order first and lets
    // GATT discovery pin the truth.
    BluetoothDevice? found;
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName.toLowerCase();
        final advNames = r.advertisementData.serviceUuids.map(
          (g) => g.str.toLowerCase(),
        );
        // A per-entry name matcher (`BandEntry.nameMatcher`) is the registry
        // sweep replacing the old single `name.contains('whoop')` literal —
        // WHOOP 4 supplies one because it sometimes advertises its name but
        // not a matchable service UUID; WHOOP 5's `fd4b` member UUID needs no
        // such fallback, so it supplies none.
        if (found == null &&
            (kFramedBands.any((e) => e.nameMatcher?.call(name) ?? false) ||
                advNames.any((s) =>
                    s == kWhoopMemberUuid16 ||
                    s.startsWith('0000fd4b') ||
                    kFramedBands.any((e) => s.startsWith(e.servicePrefix))))) {
          found = r.device;
          final adv = ScanAcceptPolicy.accepts(
            r.advertisementData.serviceUuids.map((g) => g.str),
          );
          if (adv != null) {
            _advertisedGeneration[r.device.remoteId.str] = adv;
          }
          unawaited(
            FlutterBluePlus.stopScan().catchError(
              (Object e) => _log('stopScan after match failed: $e'),
            ),
          );
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(withServices: wanted, timeout: timeout);
      await FlutterBluePlus.isScanning.where((on) => on == false).first;
    } catch (e) {
      // Android reports a missing runtime permission by throwing here rather
      // than through the adapter state, so the pre-check above cannot catch it.
      final blocker = classifyBleBlocker(error: e);
      if (blocker != null) {
        _noteBlocker(blocker);
        await sub.cancel();
        _setPhase(BleConnState.idle);
        throw BleUnavailableException(blocker);
      }
      _log('scan error: $e');
    } finally {
      await sub.cancel();
    }
    if (found == null) {
      _setPhase(BleConnState.idle);
      // The remedy in this line is still WHOOP-specific ("the official app").
      // Per-band copy needs the per-entry discovery/label of D9; the registry
      // does not make it fixable on its own.
      _log('No band found (force-quit the official app; band must be free).');
    } else {
      _clearBlocker();
    }
    return found;
  }
}
