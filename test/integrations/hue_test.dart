import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/integrations/hue.dart';

void main() {
  test('localtime format', () {
    expect(hueLocaltime(DateTime(2026, 1, 5, 6, 7, 8)), '2026-01-05T06:07:08');
  });

  test('transitiontime caps at 65535', () {
    expect(hueTransitionTime(const Duration(minutes: 30)), 18000);
    expect(hueTransitionTime(const Duration(hours: 5)), 65535);
    expect(hueTransitionTime(const Duration(seconds: -1)), 0);
  });

  test('command bodies', () {
    final s = sunriseBody(const Duration(minutes: 30));
    expect(s, {'on': true, 'bri': 254, 'ct': 366, 'transitiontime': 18000});
    final w = windDownBody();
    expect(w.containsKey('on'), isFalse);
    expect(w['transitiontime'], 9000);
    final b = scheduleBody(
        name: 'n', user: 'u', groupId: '3', action: w, at: DateTime(2026, 1, 1, 22));
    expect((b['command'] as Map)['address'], '/api/u/groups/3/action');
    expect(b['localtime'], '2026-01-01T22:00:00');
  });

  test('response parsing', () {
    final err = jsonDecode('[{"error":{"type":101,"address":"","description":"link button not pressed"}}]');
    expect(hueErrorType(err), 101);
    final ok = jsonDecode('[{"success":{"username":"abc"}}]');
    expect(hueSuccess(ok, 'username'), 'abc');
    expect(hueErrorType(ok), isNull);
  });

  test('link polls past 101 then succeeds', () async {
    var n = 0;
    final c = MockClient((r) async {
      n++;
      return http.Response(
          n < 3 ? '[{"error":{"type":101,"description":"x"}}]' : '[{"success":{"username":"tok"}}]', 200);
    });
    // storage plugin is absent in unit tests, so only the polling is checked
    try {
      await HueBridge.link('192.0.2.1', every: Duration.zero, client: c);
    } catch (_) {}
    expect(n, 3);
  });

  test('link times out on 101', () async {
    final c = MockClient((r) async => http.Response('[{"error":{"type":101,"description":"x"}}]', 200));
    expect(
      HueBridge.link('192.0.2.1', wait: const Duration(milliseconds: 20), every: const Duration(milliseconds: 10), client: c),
      throwsA(isA<HueException>()),
    );
  });

  test('bridge clock offset rounds to a quarter hour', () {
    expect(hueBridgeOffset(const Duration(minutes: 330, seconds: 40)), const Duration(minutes: 330));
    expect(hueBridgeOffset(const Duration(seconds: 50)), Duration.zero);
    expect(hueBridgeOffset(const Duration(minutes: -300, seconds: -20)), const Duration(minutes: -300));
  });
}
