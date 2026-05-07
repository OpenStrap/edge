import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => 'ApiException($status): $message';
}

class WhoopsieApi {
  static const _storage = FlutterSecureStorage();
  static const _kToken = 'whoopsie_token';
  String? _cachedToken;

  String get baseUrl => Config.apiBaseUrl;

  Future<String?> getToken() async => _cachedToken ??= await _storage.read(key: _kToken);
  Future<void> setToken(String? t) async {
    _cachedToken = t;
    if (t == null) {
      await _storage.delete(key: _kToken);
    } else {
      await _storage.write(key: _kToken, value: t);
    }
  }

  Map<String, String> _headers([String? token]) => {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authed = true,
  }) async {
    final token = authed ? await getToken() : null;
    final uri = Uri.parse('$baseUrl$path');
    final req = http.Request(method, uri)..headers.addAll(_headers(token));
    if (body != null) req.body = jsonEncode(body);
    final streamed = await req.send().timeout(const Duration(seconds: 20));
    final resp = await http.Response.fromStream(streamed);
    Map<String, dynamic> data;
    try {
      data = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(resp.statusCode, resp.body);
    }
    if (resp.statusCode >= 400) {
      throw ApiException(resp.statusCode, data['error']?.toString() ?? resp.body);
    }
    return data;
  }

  // ── Auth ────────────────────────────────────────────────────────────────
  Future<void> requestOtp(String email) =>
      _request('POST', '/auth/request-otp', body: {'email': email}, authed: false);

  Future<Map<String, dynamic>> verifyOtp(String email, String code, {String? displayName}) async {
    final data = await _request('POST', '/auth/verify-otp', body: {
      'email': email,
      'code': code,
      if (displayName != null) 'display_name': displayName,
    }, authed: false);
    await setToken(data['token'] as String);
    return data['user'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> me() async {
    try {
      final data = await _request('GET', '/auth/me');
      return data['user'] as Map<String, dynamic>?;
    } on ApiException catch (e) {
      if (e.status == 401) return null;
      rethrow;
    }
  }

  Future<void> signOut() async {
    await setToken(null);
  }

  // ── Devices ─────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> pairDevice({
    required String strapSerial,
    required String bleId,
    String? name,
  }) async {
    final data = await _request('POST', '/devices/pair', body: {
      'strap_serial': strapSerial,
      'ble_id': bleId,
      if (name != null) 'name': name,
    });
    return data['device'] as Map<String, dynamic>;
  }

  Future<List<dynamic>> listDevices() async {
    final data = await _request('GET', '/devices');
    return (data['devices'] as List<dynamic>?) ?? const [];
  }

  // ── Ingest ──────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> ingestBatch(Map<String, dynamic> batch) =>
      _request('POST', '/ingest/batch', body: batch);

  // ── Insights ────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> insightsToday() => _request('GET', '/insights/today');

  Future<Map<String, dynamic>> insightsSleep(String date) =>
      _request('GET', '/insights/sleep/$date');

  Future<Map<String, dynamic>> insightsRecovery(String date) =>
      _request('GET', '/insights/recovery/$date');
}

final apiProvider = Provider<WhoopsieApi>((_) => WhoopsieApi());
