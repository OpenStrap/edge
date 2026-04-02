import 'package:shared_preferences/shared_preferences.dart';

class LocalStorageService {
  static const String _lastDeviceKeyKey = 'last_device_key';
  static const String _lastDeviceNameKey = 'last_device_name';

  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  /// Save the last connected device (MAC address / device key)
  Future<void> saveLastDevice(String deviceKey, String deviceName) async {
    await _prefs.setString(_lastDeviceKeyKey, deviceKey);
    await _prefs.setString(_lastDeviceNameKey, deviceName);
  }

  /// Get the last connected device key
  String? getLastDeviceKey() {
    return _prefs.getString(_lastDeviceKeyKey);
  }

  /// Get the last connected device name
  String? getLastDeviceName() {
    return _prefs.getString(_lastDeviceNameKey);
  }

  /// Clear saved device
  Future<void> clearLastDevice() async {
    await _prefs.remove(_lastDeviceKeyKey);
    await _prefs.remove(_lastDeviceNameKey);
  }
}
