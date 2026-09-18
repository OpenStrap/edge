// postChat used to hardcode a 120s timeout regardless of CoachConfig, which
// made the value in coach_config_timeout_test.dart cosmetic — it had to
// actually reach the HTTP call for a configured timeout to mean anything.
//
// The configurable timeout only takes effect for a local endpoint (see
// coach_config_timeout_test.dart), so these exercise the HTTP path against a
// local baseUrl.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';

Future<Map<String, dynamic>> _post(CoachConfig cfg, http.Client c) =>
    CoachEngine.postChat(cfg, {
      'model': 'gpt-4o-mini',
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ],
    }, client: c);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a local endpoint slower than its configured timeout throws', () async {
    final cfg = CoachConfig();
    await cfg.save(baseUrl: 'http://localhost:11434/v1', timeoutSeconds: 1);
    final slow = MockClient((_) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      return http.Response('{}', 200);
    });

    await expectLater(_post(cfg, slow), throwsA(isA<TimeoutException>()));
  });

  test('a local endpoint within its configured timeout succeeds', () async {
    final cfg = CoachConfig();
    await cfg.save(baseUrl: 'http://localhost:11434/v1', timeoutSeconds: 2);
    final ok = MockClient((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'hi there'}
            }
          ]
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final msg = await _post(cfg, ok);
    expect(msg['content'], 'hi there');
  });

  test('a cloud endpoint ignores a short saved timeout', () async {
    final cfg = CoachConfig(); // default baseUrl is the cloud endpoint
    await cfg.save(timeoutSeconds: 1);
    final slowerThanSavedButUnderTwoMinutes = MockClient((_) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'hi there'}
            }
          ]
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final msg = await _post(cfg, slowerThanSavedButUnderTwoMinutes);
    expect(msg['content'], 'hi there',
        reason: 'the saved 1s timeout must not apply to a cloud endpoint');
  });
}
