// Philips Hue, local bridge API v1 (no cloud account). Schedules live on the
// bridge, so they fire even when the app is closed.
//
// ponytail: v1 API only (bridge Pro/v2 still serves it); no event stream.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HueException implements Exception {
  HueException(this.message);
  final String message;
  @override
  String toString() => message;
}

class HueRoom {
  const HueRoom(this.id, this.name);
  final String id;
  final String name;
}

// ---- pure helpers (unit-tested) -------------------------------------------

/// Bridge schedule time, "YYYY-MM-DDTHH:MM:SS". ponytail: assumes phone and
/// bridge share a timezone (bridge localtime has no zone); wrong if travelling.
String hueLocaltime(DateTime t) {
  String p(int n) => n.toString().padLeft(2, '0');
  final l = t.toLocal();
  return '${l.year.toString().padLeft(4, '0')}-${p(l.month)}-${p(l.day)}'
      'T${p(l.hour)}:${p(l.minute)}:${p(l.second)}';
}

/// Deciseconds, capped at the v1 maximum of 65535 (~109 min).
int hueTransitionTime(Duration d) {
  final ds = d.inMilliseconds ~/ 100;
  return ds < 0 ? 0 : (ds > 65535 ? 65535 : ds);
}

Map<String, Object> sunriseBody(Duration ramp) => {
      'on': true,
      'bri': 254,
      'ct': 366, // ~2700 K, warm-ish
      'transitiontime': hueTransitionTime(ramp),
    };

/// No "on" key: lights that are off stay off.
Map<String, Object> windDownBody() =>
    {'bri': 76, 'ct': 454, 'transitiontime': 9000}; // ~30%, 15 min

Map<String, Object> scheduleBody({
  required String name,
  required String user,
  required String groupId,
  required Map<String, Object> action,
  required DateTime at,
}) =>
    {
      'name': name,
      'command': {
        'address': '/api/$user/groups/$groupId/action',
        'method': 'PUT',
        'body': action,
      },
      'localtime': hueLocaltime(at),
      'autodelete': true,
    };

/// First v1 error type in a response, or null.
int? hueErrorType(Object? decoded) {
  if (decoded is List) {
    for (final e in decoded) {
      if (e is Map && e['error'] is Map) {
        final t = (e['error'] as Map)['type'];
        if (t is int) return t;
      }
    }
  }
  return null;
}

/// First `success[key]` in a v1 response (e.g. username, id), or null.
String? hueSuccess(Object? decoded, String key) {
  if (decoded is List) {
    for (final e in decoded) {
      if (e is Map && e['success'] is Map) {
        final v = (e['success'] as Map)[key];
        if (v != null) return '$v';
      }
    }
  }
  return null;
}

String _errText(Object? decoded) {
  if (decoded is List) {
    for (final e in decoded) {
      if (e is Map && e['error'] is Map) {
        return '${(e['error'] as Map)['description']}';
      }
    }
  }
  return 'unexpected reply';
}

// ---- bridge ----------------------------------------------------------------

class HueBridge {
  HueBridge(this.ip, this.user, {http.Client? client}) : _c = client ?? _pinned(ip);

  final String ip;
  final String user;
  final http.Client _c;

  static const _apple = IOSOptions(accessibility: KeychainAccessibility.first_unlock);
  static const _store = FlutterSecureStorage();
  static const _kBridge = 'hue.bridge';
  static const _kSched = 'hue.schedules';

  /// Self-signed bridge cert: accepted for this one host only.
  static http.Client _pinned(String ip) => IOClient(
        HttpClient()
          ..connectionTimeout = const Duration(seconds: 8)
          ..badCertificateCallback = (_, host, _) => host == ip,
      );

  static Future<List<String>> discover({http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final r = await c.get(Uri.parse('https://discovery.meethue.com/')).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) throw HueException('Hue discovery is unavailable. Enter the bridge IP by hand.');
      return [
        for (final b in jsonDecode(r.body) as List)
          if (b is Map && b['internalipaddress'] is String) b['internalipaddress'] as String,
      ];
    } on HueException {
      rethrow;
    } catch (_) {
      throw HueException('Could not look up bridges. Enter the bridge IP by hand.');
    } finally {
      if (client == null) c.close();
    }
  }

  static Future<HueBridge> link(
    String ip, {
    Duration wait = const Duration(seconds: 30),
    Duration every = const Duration(seconds: 2),
    http.Client? client,
  }) async {
    final c = client ?? _pinned(ip);
    final end = DateTime.now().add(wait);
    try {
      while (true) {
        Object? d;
        try {
          final r = await c
              .post(Uri.parse('https://$ip/api'), body: jsonEncode({'devicetype': 'openstrap#phone'}))
              .timeout(const Duration(seconds: 8));
          d = jsonDecode(r.body);
        } catch (_) {
          throw HueException('Could not reach the bridge at $ip. Check the address and that you are on the same Wi-Fi.');
        }
        final u = hueSuccess(d, 'username');
        if (u != null) {
          final b = HueBridge(ip, u);
          await _store.write(key: _kBridge, value: jsonEncode({'ip': ip, 'user': u}), iOptions: _apple);
          return b;
        }
        if (hueErrorType(d) != 101) throw HueException('The bridge refused to link: ${_errText(d)}');
        if (DateTime.now().add(every).isAfter(end)) {
          throw HueException('Press the round link button on the bridge, then try again.');
        }
        await Future<void>.delayed(every);
      }
    } finally {
      if (client == null) c.close();
    }
  }

  static Future<HueBridge?> load() async {
    final s = await _store.read(key: _kBridge, iOptions: _apple);
    if (s == null) return null;
    final m = jsonDecode(s) as Map;
    return HueBridge(m['ip'] as String, m['user'] as String);
  }

  Future<void> forget() async {
    await _store.delete(key: _kBridge, iOptions: _apple);
    await _store.delete(key: _kSched, iOptions: _apple);
  }

  Uri _u(String p) => Uri.parse('https://$ip/api/$user$p');

  Future<Object?> _send(String method, String path, [Object? body]) async {
    try {
      final req = http.Request(method, _u(path));
      if (body != null) req.body = jsonEncode(body);
      final r = await http.Response.fromStream(await _c.send(req).timeout(const Duration(seconds: 10)));
      final d = jsonDecode(r.body);
      final t = hueErrorType(d);
      if (t == 1) throw HueException('Hue link expired. Link the bridge again.');
      if (t != null) throw HueException('Hue bridge error: ${_errText(d)}');
      return d;
    } on HueException {
      rethrow;
    } catch (_) {
      throw HueException('Could not reach the Hue bridge. Are you on the same Wi-Fi?');
    }
  }

  Future<List<HueRoom>> rooms() async {
    final g = await _send('GET', '/groups') as Map;
    return [
      const HueRoom('0', 'All lights'),
      for (final e in g.entries)
        if (e.value is Map && const {'Room', 'Zone'}.contains((e.value as Map)['type']))
          HueRoom(e.key as String, '${(e.value as Map)['name']}'),
    ];
  }

  Future<Map<String, String>> _ids() async {
    final s = await _store.read(key: _kSched, iOptions: _apple);
    return s == null ? {} : Map<String, String>.from(jsonDecode(s) as Map);
  }

  Future<void> _schedule(String kind, DateTime at, String groupId, Map<String, Object> action) async {
    await _drop(kind);
    if (!at.isAfter(DateTime.now())) return; // already past
    final d = await _send('POST', '/schedules',
        scheduleBody(name: 'openstrap $kind', user: user, groupId: groupId, action: action, at: at));
    final id = hueSuccess(d, 'id');
    if (id == null) throw HueException('The bridge did not accept the schedule.');
    final ids = await _ids()..[kind] = id;
    await _store.write(key: _kSched, value: jsonEncode(ids), iOptions: _apple);
  }

  Future<void> _drop(String kind) async {
    final ids = await _ids();
    final id = ids.remove(kind);
    if (id == null) return;
    try {
      await _send('DELETE', '/schedules/$id');
    } on HueException {
      // gone already (autodelete after firing) or bridge unreachable; forget it
    }
    await _store.write(key: _kSched, value: jsonEncode(ids), iOptions: _apple);
  }

  Future<void> scheduleSunrise({
    required DateTime wake,
    required String groupId,
    Duration ramp = const Duration(minutes: 30),
  }) =>
      _schedule('sunrise', wake.subtract(ramp), groupId, sunriseBody(ramp));

  Future<void> scheduleWindDown({required DateTime at, required String groupId}) =>
      _schedule('winddown', at, groupId, windDownBody());

  Future<void> clearSunrise() => _drop('sunrise');

  Future<void> clearSchedules() async {
    await _drop('sunrise');
    await _drop('winddown');
  }
}

// ── glue the alarm and wind-down call ──────────────────────────────────────

const _kRoom = 'hue_room';

Future<String?> hueRoom() async => (await SharedPreferences.getInstance()).getString(_kRoom);

Future<void> setHueRoom(String? id) async {
  final prefs = await SharedPreferences.getInstance();
  id == null ? await prefs.remove(_kRoom) : await prefs.setString(_kRoom, id);
}

/// Best effort, both of these: a bridge that is off, moved or unpaired must
/// never get in the way of the alarm or the reminder that called it.
Future<void> hueSunriseFor(DateTime? wake) async {
  try {
    final b = await HueBridge.load();
    final room = await hueRoom();
    if (b == null || room == null) return;
    wake == null ? await b.clearSunrise() : await b.scheduleSunrise(wake: wake, groupId: room);
  } catch (e) {
    debugPrint('[hue] sunrise: $e');
  }
}

Future<void> hueWindDownAt(DateTime at) async {
  try {
    final b = await HueBridge.load();
    final room = await hueRoom();
    if (b == null || room == null) return;
    await b.scheduleWindDown(at: at, groupId: room);
  } catch (e) {
    debugPrint('[hue] wind-down: $e');
  }
}
