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
    // Sanitize on read: drop any garbled value (e.g. "?*" junk persisted by an
    // older build's HELLO content-scan) so it can never reach the UI.
    return PairedDevice(id, cleanDeviceLabel(prefs.getString(_kSerial)));
  }

  static Future<void> save(String remoteId, String? serial) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRemoteId, remoteId);
    final clean = cleanDeviceLabel(serial);
    if (clean != null) {
      await prefs.setString(_kSerial, clean);
    } else {
      await prefs.remove(_kSerial); // never persist junk
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kRemoteId);
    await prefs.remove(_kSerial);
  }
}

/// A WHOOP serial ("4C2248092") or a user-set strap name ("Abdul's WHOOP") is
/// made of letters, digits, spaces and a little ordinary punctuation. Anything
/// containing other characters (the "?*"-style junk a bad HELLO parse produced)
/// is rejected → null. Gates what we persist and display as the device label.
String? cleanDeviceLabel(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.isEmpty) return null;
  if (!RegExp(r"^[A-Za-z0-9 '._-]+$").hasMatch(t)) return null; // safe charset
  if (!RegExp(r'[A-Za-z0-9]').hasMatch(t)) return null; // needs ≥1 alnum
  return t;
}
