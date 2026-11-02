// Fail an actual preferences write without replacing PairedDevice.save.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class FailingPreferencesStore extends SharedPreferencesStorePlatform {
  FailingPreferencesStore(
    this.delegate, {
    required this.key,
    this.throws = true,
  });

  final SharedPreferencesStorePlatform delegate;
  final String key;
  final bool throws;
  var _failed = false;

  Future<bool> _write(String key, Future<bool> Function() write) async {
    if (!_failed && key == 'flutter.${this.key}') {
      _failed = true;
      // A platform failure can arrive after the value has already changed.
      await write();
      if (throws) throw StateError('preferences write failed');
      return false;
    }
    return write();
  }

  @override
  Future<Map<String, Object>> getAll() => delegate.getAll();

  @override
  Future<bool> clear() => delegate.clear();

  @override
  Future<bool> remove(String key) => _write(key, () => delegate.remove(key));

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      _write(key, () => delegate.setValue(valueType, key, value));
}
