// Localized [BandStatus] copy, kept out of `ble_state.dart` on purpose: that
// file is pure transport-layer logic (no Flutter, no BuildContext) and is
// unit-tested directly against its literal English text in
// `test/ble_state_test.dart`. This is the render-time wrapper every UI call
// site (devices.dart, pairing.dart, pair_sensor.dart) should use instead of
// reading `.title`/`.reason`/`.fix` straight off a `BandStatus` — same split
// as `sourceState`/`_localizedSourceState` in devices.dart.

import 'package:flutter/widgets.dart' show BuildContext;

import '../l10n/app_localizations.dart';
import 'ble_state.dart' show BandCondition, BandStatus;

BandStatus localizedBandStatus(BuildContext c, BandStatus s) {
  final l = AppLocalizations.of(c);
  switch (s.condition) {
    case BandCondition.bluetoothDenied:
      return BandStatus(
        s.condition,
        l?.bandStatusBluetoothDeniedTitle ?? s.title,
        l?.bandStatusBluetoothDeniedReason ?? s.reason,
        fix: l?.bandStatusBluetoothDeniedFix ?? s.fix,
      );
    case BandCondition.bluetoothOff:
      return BandStatus(
        s.condition,
        l?.bandStatusBluetoothOffTitle ?? s.title,
        l?.bandStatusBluetoothOffReason ?? s.reason,
        fix: l?.bandStatusBluetoothOffFix ?? s.fix,
      );
    case BandCondition.bluetoothUnsupported:
      return BandStatus(
        s.condition,
        l?.bandStatusBluetoothUnsupportedTitle ?? s.title,
        l?.bandStatusBluetoothUnsupportedReason ?? s.reason,
      );
    case BandCondition.reconnectPaused:
      return BandStatus(
        s.condition,
        l?.bandStatusReconnectPausedTitle ?? s.title,
        l?.bandStatusReconnectPausedReason(s.bondRefusals ?? 0) ?? s.reason,
        fix: l?.bandStatusReconnectPausedFix ?? s.fix,
        bondRefusals: s.bondRefusals,
      );
    case BandCondition.repairNeeded:
      return BandStatus(
        s.condition,
        l?.bandStatusRepairNeededTitle ?? s.title,
        l?.bandStatusRepairNeededReason ?? s.reason,
        fix: l?.bandStatusRepairFix ?? s.fix,
      );
    case BandCondition.syncStuck:
      return BandStatus(
        s.condition,
        l?.bandStatusSyncStuckTitle ?? s.title,
        l?.bandStatusSyncStuckReason ?? s.reason,
        fix: l?.bandStatusSyncStuckFix ?? s.fix,
      );
    case BandCondition.strapUnresponsive:
      return BandStatus(
        s.condition,
        l?.bandStatusStrapUnresponsiveTitle ?? s.title,
        l?.bandStatusStrapUnresponsiveReason ?? s.reason,
        fix: l?.bandStatusStrapUnresponsiveFix ?? s.fix,
      );
    case BandCondition.clockLost:
      return BandStatus(
        s.condition,
        l?.bandStatusClockLostTitle ?? s.title,
        l?.bandStatusClockLostReason ?? s.reason,
        fix: l?.bandStatusClockLostFix ?? s.fix,
      );
    case BandCondition.connected:
      return BandStatus(
        s.condition,
        l?.devicesConnected ?? s.title,
        l?.bandStatusConnectedReason ?? s.reason,
      );
    case BandCondition.connecting:
      return BandStatus(
        s.condition,
        l?.bandStatusConnectingTitle ?? s.title,
        l?.bandStatusConnectingReason ?? s.reason,
      );
    case BandCondition.scanning:
      return BandStatus(
        s.condition,
        l?.bandStatusScanningTitle ?? s.title,
        l?.bandStatusScanningReason ?? s.reason,
      );
    case BandCondition.disconnected:
      return BandStatus(
        s.condition,
        l?.devicesNotConnected ?? s.title,
        l?.bandStatusDisconnectedReason ?? s.reason,
        fix: l?.bandStatusDisconnectedFix ?? s.fix,
      );
  }
}
