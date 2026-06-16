// device_alerts.dart — turns the band's battery/charging state into OS alerts.
//
// Fed the latest DeviceState on every BLE update (AppState._onEngineState), but
// it is EDGE-TRIGGERED and de-duped, so it fires at most once per real event —
// never on every tick:
//   • Low battery (< 15%, not charging): once per drain. Re-arms only after the
//     battery recovers past 25% (hysteresis) or goes back on the charger.
//   • Charging started: once per plug-in (false/unknown → true).
//
// Presentation goes through NotificationService, the single display layer that a
// future FCM/server-push system also uses — so adding push later doesn't touch
// this file or risk colliding with these alerts.

import 'notification_service.dart';

class DeviceAlerts {
  static const double _lowPct = 15;
  static const double _rearmPct = 25; // hysteresis so we don't re-fire near 15%

  bool _lowArmed = true; // may we raise a low-battery alert?
  bool? _wasCharging; // previous charging state (null = not seen yet)

  final NotificationService _notes;
  DeviceAlerts([NotificationService? notes])
      : _notes = notes ?? NotificationService.instance;

  /// Call with the latest device state. Cheap and safe to call on every update.
  void onDeviceState({double? batteryPct, bool? charging}) {
    // Charging just started → notify once; clear any stale low alert and re-arm
    // so the next drain can alert again.
    if (charging == true && _wasCharging != true) {
      _notes.showDevice(
        id: NotificationService.idCharging,
        title: 'Charging',
        body: 'Your band is on the charger.',
      );
      _notes.cancel(NotificationService.idLowBattery);
      _lowArmed = true;
    }
    if (charging != null) _wasCharging = charging;

    if (batteryPct == null) return;
    if (batteryPct >= _rearmPct) _lowArmed = true; // recovered → arm for next time
    if (charging != true && batteryPct < _lowPct && _lowArmed) {
      _notes.showDevice(
        id: NotificationService.idLowBattery,
        title: 'Low battery',
        body: 'Your band is at ${batteryPct.round()}%. Charge it soon.',
      );
      _lowArmed = false;
    }
  }
}
