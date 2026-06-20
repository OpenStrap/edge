// CoachConfig — local, BYOK settings for the AI coach. The API key is stored in
// the platform keychain/keystore (flutter_secure_storage); base URL + model in
// SharedPreferences. NOTHING here ever touches our backend — the key stays on the
// device and the app calls the OpenAI-compatible provider directly.

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CoachConfig extends ChangeNotifier {
  static const _kBaseUrl = 'coach_base_url';
  static const _kModel = 'coach_model';
  static const _kKey = 'coach_api_key'; // secure storage

  static const String defaultBaseUrl = 'https://api.openai.com/v1';

  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  String _baseUrl = defaultBaseUrl;
  String _model = '';
  String? _key; // cached in-memory after load

  String get baseUrl => _baseUrl;
  String get model => _model;
  String? get apiKey => _key;
  bool get hasKey => _key != null && _key!.isNotEmpty;
  bool get configured => hasKey && _baseUrl.isNotEmpty && _model.isNotEmpty;

  /// Normalised base, no trailing slash.
  String get apiBase {
    var b = _baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString(_kBaseUrl) ?? defaultBaseUrl;
    _model = prefs.getString(_kModel) ?? '';
    try {
      _key = await _secure.read(key: _kKey);
    } catch (_) {
      _key = null;
    }
    notifyListeners();
  }

  Future<void> save({String? baseUrl, String? model, String? apiKey}) async {
    final prefs = await SharedPreferences.getInstance();
    if (baseUrl != null) {
      _baseUrl = baseUrl.trim().isEmpty ? defaultBaseUrl : baseUrl.trim();
      await prefs.setString(_kBaseUrl, _baseUrl);
    }
    if (model != null) {
      _model = model.trim();
      await prefs.setString(_kModel, _model);
    }
    if (apiKey != null) {
      final k = apiKey.trim();
      _key = k.isEmpty ? null : k;
      if (k.isEmpty) {
        await _secure.delete(key: _kKey);
      } else {
        await _secure.write(key: _kKey, value: k);
      }
    }
    notifyListeners();
  }
}
