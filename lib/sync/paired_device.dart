// PairedDevice — the LOCAL record of the band the user paired (BLE remote id +
// optional serial). Persisted so we auto-reconnect on every launch.
//
// LOCAL ONLY — there is no server, no device table. This survived the cloud
// excision (it used to live alongside BackendConfig/Session in sync/config.dart,
// both of which were deleted).

import 'package:shared_preferences/shared_preferences.dart';

/// The band the user paired. Persisted so we auto-reconnect on every launch.
class PairedDevice {
  static const String _kRemoteId = 'paired_remote_id';
  static const String _kSerial = 'paired_serial';

  final String remoteId; // BLE remote id (iOS: per-install UUID; Android: MAC)
  final String? serial;
  PairedDevice(this.remoteId, this.serial);

  static Future<PairedDevice?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_kRemoteId);
    if (id == null || id.isEmpty) return null;
    return PairedDevice(id, prefs.getString(_kSerial));
  }

  static Future<void> save(String remoteId, String? serial) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRemoteId, remoteId);
    if (serial != null) await prefs.setString(_kSerial, serial);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kRemoteId);
    await prefs.remove(_kSerial);
  }
}
