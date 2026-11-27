import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/integrations/intervals_icu.dart';

void main() {
  test('wellness body omits absent fields and converts units', () {
    final b = intervalsWellnessBody('2026-11-20', {'rhr': 52.4, 'rmssd': 71.2, 'tst_min': 420});
    expect(b, {'id': '2026-11-20', 'restingHR': 52, 'hrv': 71.2, 'sleepSecs': 25200});
    expect(intervalsWellnessBody('2026-11-20', {}), {'id': '2026-11-20'});
  });

  test('api key uses Basic API_KEY:key', () {
    final a = IntervalsAuth('i123', 'k', apiKey: true);
    expect(a.header, 'Basic ${base64.encode(utf8.encode('API_KEY:k'))}');
  });

  test('token response parse', () {
    final a = parseIntervalsToken('{"access_token":"tok","token_type":"Bearer","scope":"x","athlete":{"id":"i42","name":"A"}}');
    expect((a.athleteId, a.secret, a.header), ('i42', 'tok', 'Bearer tok'));
    expect(() => parseIntervalsToken('{}'), throwsA(isA<IntervalsException>()));
  });

  test('saveApiKey rejects a 401 without storing', () async {
    final c = MockClient((r) async {
      expect(r.url.path, '/api/v1/athlete/i1');
      expect(r.headers['Authorization'], startsWith('Basic '));
      return http.Response('', 401);
    });
    final i = IntervalsIcu(client: c);
    await expectLater(i.saveApiKey('i1', 'bad'), throwsA(isA<IntervalsException>()));
    expect(i.signedIn, false);
  });

  const key = IntervalsAuth('i1', 'k', apiKey: true);

  test('wellness push: PUT to the day with the auth header and JSON body', () async {
    late http.Request got;
    final i = IntervalsIcu(client: MockClient((r) async {
      got = r;
      return http.Response('{}', 200);
    }), auth: key);
    await i.putWellness('2026-11-20', {'id': '2026-11-20', 'hrv': 70.5});
    expect(got.method, 'PUT');
    expect(got.url.path, '/api/v1/athlete/i1/wellness/2026-11-20');
    expect(got.headers['Authorization'], key.header);
    expect(jsonDecode(got.body), {'id': '2026-11-20', 'hrv': 70.5});
  });

  test('a 401 marks the sign-in dead and stops auto push', () async {
    var calls = 0;
    final i = IntervalsIcu(client: MockClient((r) async { calls++; return http.Response('', 401); }), auth: key);
    await expectLater(i.putWellness('2026-11-20', {'id': '2026-11-20'}), throwsA(isA<IntervalsException>()));
    expect(i.authFailed, true);
    await i.pushAfterDerive();
    expect(calls, 1);
  });

  test('a 500 is an error but not an auth failure', () async {
    final i = IntervalsIcu(client: MockClient((r) async => http.Response('', 500)), auth: key);
    await expectLater(i.putWellness('2026-11-20', {'id': 'x'}), throwsA(isA<IntervalsException>()));
    expect(i.authFailed, false);
  });

  test('workout upload: multipart TCX with external_id', () async {
    late http.BaseRequest got;
    final i = IntervalsIcu(client: MockClient.streaming((r, body) async {
      got = r;
      return http.StreamedResponse(const Stream.empty(), 200);
    }), auth: key);
    await i.uploadTcx('s9', '<x/>', name: 'Run');
    expect(got.method, 'POST');
    expect(got.url.path, '/api/v1/athlete/i1/activities');
    expect(got.url.queryParameters, {'name': 'Run', 'external_id': 'openstrap-s9'});
    expect(got.headers['Authorization'], key.header);
    expect(got.headers['content-type'], startsWith('multipart/form-data'));
  });

  test('client id defaults to the registered public client', () {
    expect(kIntervalsClientId, '2017');
  });

  test('every request names the app', () async {
    final seen = <String?>[];
    final i = IntervalsIcu(client: MockClient((r) async {
      seen.add(r.headers['User-Agent']);
      return http.Response('{}', 200);
    }), auth: key);
    await i.putWellness('2026-11-20', {'id': '2026-11-20'});
    await i.uploadTcx('s9', '<x/>');
    expect(seen, [kIntervalsUserAgent, kIntervalsUserAgent]);
  });

  test('automatic push can be turned off and sends nothing', () async {
    var calls = 0;
    final i = IntervalsIcu(client: MockClient((r) async { calls++; return http.Response('{}', 200); }), auth: key);
    i.autoPush = false;
    await i.pushAfterDerive();
    expect(calls, 0);
  });
}
