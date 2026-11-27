// Weather, air quality and pollen around the user's days, so the coach can
// name a likely outside cause for an HRV dip or a rough night. Open-Meteo:
// no key, no account. Only a rounded location (~11 km) leaves the phone.
// Data by Open-Meteo.com, CC BY 4.0.

import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const kWeatherAttribution = 'Weather data by Open-Meteo.com (CC BY 4.0)';
const _kOn = 'integration_weather_on';

Future<bool> weatherEnabled() async =>
    (await SharedPreferences.getInstance()).getBool(_kOn) ?? false;

Future<void> setWeatherEnabled(bool on) async =>
    (await SharedPreferences.getInstance()).setBool(_kOn, on);

/// One decimal place: about 11 km, enough for weather, not enough to find a home.
double roundCoord(double v) => (v * 10).round() / 10;

Uri weatherUri(double lat, double lon, int pastDays) =>
    Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': '$lat',
      'longitude': '$lon',
      'daily': 'temperature_2m_max,temperature_2m_min,precipitation_sum,uv_index_max,sunrise,sunset',
      'past_days': '$pastDays',
      'forecast_days': '2',
      'timezone': 'auto',
    });

Uri airUri(double lat, double lon, int pastDays) =>
    Uri.https('air-quality-api.open-meteo.com', '/v1/air-quality', {
      'latitude': '$lat',
      'longitude': '$lon',
      'hourly': 'us_aqi,pm2_5,grass_pollen,birch_pollen,ragweed_pollen',
      'past_days': '$pastDays',
      'forecast_days': '2',
      'timezone': 'auto',
    });

/// Folds the two replies into one row per day. Hourly air values become the
/// day's maximum. A value the service has no reading for is left out, never
/// zeroed (pollen exists only for some regions).
List<Map<String, Object?>> summarizeWeather(Map forecast, Map? air) {
  final d = forecast['daily'] as Map? ?? const {};
  final dates = (d['time'] as List?)?.cast<String>() ?? const [];
  final airMax = <String, Map<String, num>>{};
  final h = air?['hourly'] as Map?;
  final hours = (h?['time'] as List?)?.cast<String>() ?? const [];
  for (final key in const ['us_aqi', 'pm2_5', 'grass_pollen', 'birch_pollen', 'ragweed_pollen']) {
    final vals = h?[key] as List?;
    if (vals == null) continue;
    for (var i = 0; i < hours.length && i < vals.length; i++) {
      final v = vals[i];
      if (v is! num) continue;
      final day = airMax.putIfAbsent(hours[i].substring(0, 10), () => {});
      if (v > (day[key] ?? double.negativeInfinity)) day[key] = v;
    }
  }
  Object? at(String key, int i) {
    final l = d[key] as List?;
    return l != null && i < l.length ? l[i] : null;
  }

  return [
    for (var i = 0; i < dates.length; i++)
      {
        'date': dates[i],
        'temp_max_c': ?at('temperature_2m_max', i),
        'temp_min_c': ?at('temperature_2m_min', i),
        'precip_mm': ?at('precipitation_sum', i),
        'uv_max': ?at('uv_index_max', i),
        'sunrise': ?at('sunrise', i),
        'sunset': ?at('sunset', i),
        for (final e in (airMax[dates[i]] ?? const <String, num>{}).entries) '${e.key}_max': e.value,
      },
  ];
}

/// The coach tool's reply: JSON, or a sentence saying why there is none.
Future<String> weatherForCoach({int pastDays = 7, http.Client? client}) async {
  if (!await weatherEnabled()) {
    return 'Weather is off. The user can turn it on in Profile > Connected apps.';
  }
  final perm = await Geolocator.checkPermission();
  if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) {
    return 'No location permission, so no weather. Do not guess the weather.';
  }
  // A cached fix from an earlier outing is the wrong place's weather.
  final last = await Geolocator.getLastKnownPosition();
  final recent = last != null && DateTime.now().difference(last.timestamp).inHours < 6;
  final pos = (recent ? last : null) ??
      await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.low, timeLimit: Duration(seconds: 10)));
  final lat = roundCoord(pos.latitude), lon = roundCoord(pos.longitude);
  final days = pastDays.clamp(1, 30);
  final c = client ?? http.Client();
  try {
    final f = await c.get(weatherUri(lat, lon, days)).timeout(const Duration(seconds: 20));
    if (f.statusCode != 200) return 'Weather service error ${f.statusCode}. Do not guess the weather.';
    Map? air;
    try {
      final a = await c.get(airUri(lat, lon, days)).timeout(const Duration(seconds: 20));
      if (a.statusCode == 200) air = jsonDecode(a.body) as Map;
    } catch (_) {} // weather alone is still worth answering with
    return jsonEncode({
      'days': summarizeWeather(jsonDecode(f.body) as Map, air),
      'location': 'rounded to about 11 km',
      'source': kWeatherAttribution,
    });
  } finally {
    if (client == null) c.close();
  }
}
