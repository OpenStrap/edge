// AppMode — the single local/cloud toggle (LOCAL_FIRST_DESIGN §2/§3).
// Local: compute on-device (Rust core via FFI), no account, data stays put.
// Cloud: results computed/synced server-side, account (email+OTP), cross-device.
// "Mode is plumbing, not data" — screens read a DataSource, never the mode directly.
import 'package:shared_preferences/shared_preferences.dart';

enum AppMode { local, cloud }

class AppModeStore {
  static const _key = 'app_mode';

  static Future<AppMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key) == 'cloud' ? AppMode.cloud : AppMode.local;
  }

  /// Null until the user picks one in onboarding (drives mode-select screen).
  static Future<AppMode?> loadOrNull() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    if (v == null) return null;
    return v == 'cloud' ? AppMode.cloud : AppMode.local;
  }

  static Future<void> save(AppMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode == AppMode.cloud ? 'cloud' : 'local');
  }
}
