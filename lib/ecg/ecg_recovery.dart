// Retained-guard recovery, controller-free so the headless background
// drainer can run it too. Physical MG firmware keeps generation, raw-save
// and the live filtered publisher active through process death until a
// client sends the cleanup triplet — so on the next READY, before history or
// another reading, a retained guard gets the transport first.

import 'ecg_guard_store.dart';
import 'ecg_transport.dart';

enum EcgRecoveryOutcome {
  /// No guard for this band; nothing to do.
  noGuard,

  /// All three cleanup members succeeded; the guard was cleared.
  cleared,

  /// A cleanup member failed (or the guard write did not land); the guard
  /// stays set and the next READY tries again.
  retained,

  /// No serial to look the guard up under.
  noSerial,
}

Future<EcgRecoveryOutcome> ecgRecoverRetainedGuard({
  required EcgGuardStore guard,
  required String? serial,
  required Future<EcgCommandListResult> Function() cleanup,
  required void Function(String) log,
}) async {
  if (serial == null || serial.isEmpty) return EcgRecoveryOutcome.noSerial;
  if (!await guard.isActive(serial)) return EcgRecoveryOutcome.noGuard;
  log(
    '[ECG] retained may-be-active guard for $serial — sending the cleanup '
    'triplet before history.',
  );
  final res = await cleanup();
  if (res.allSucceeded && await guard.clear(serial)) {
    log('[ECG] recovery cleanup succeeded — guard cleared.');
    return EcgRecoveryOutcome.cleared;
  }
  log(
    '[ECG] recovery cleanup incomplete ($res) — guard retained; the next '
    'connection tries again.',
  );
  return EcgRecoveryOutcome.retained;
}
