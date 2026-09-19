// CoachEngine.postChat — the ONE provider call every LLM feature in the app
// goes through (coach tool loop, briefings, journal chat).
//
//  • Every failure must surface as the documented CoachException. Reaching for
//    `choices.first['message'] as Map<String, dynamic>` unchecked meant any
//    OpenAI-compatible proxy returning a streaming (`delta`) or legacy (`text`)
//    shape blew up with a raw TypeError, and the user was shown
//    "type 'Null' is not a subtype of type 'Map<String, dynamic>'".
//  • The request has a hard size ceiling. The coach's tools read the on-device
//    health database and every result is resent on every later turn, so without
//    a ceiling a runaway tool loop could serialize the whole database into a
//    prompt bound for a third-party endpoint. The ceiling is FAIL-CLOSED: the
//    request is refused, never truncated and sent anyway.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';

http.Client _json(Object body, {int status = 200}) => MockClient(
      (_) async => http.Response(
        body is String ? body : jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );

Future<Map<String, dynamic>> _post(CoachConfig cfg, http.Client c) =>
    CoachEngine.postChat(cfg, {
      'model': 'gpt-4o-mini',
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ],
    }, client: c);

void main() {
  late CoachConfig cfg;
  setUp(() => cfg = CoachConfig());

  group('postChat response shapes', () {
    test('standard message shape is returned', () async {
      final msg = await _post(
        cfg,
        _json({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'hello'}
            }
          ]
        }),
      );
      expect(msg['content'], 'hello');
    });

    test('a streaming-style `delta` chunk is accepted, not a TypeError',
        () async {
      final msg = await _post(
        cfg,
        _json({
          'choices': [
            {
              'delta': {'role': 'assistant', 'content': 'partial'}
            }
          ]
        }),
      );
      expect(msg['content'], 'partial');
    });

    test('a legacy completions `text` choice is accepted', () async {
      final msg = await _post(
        cfg,
        _json({
          'choices': [
            {'text': 'legacy'}
          ]
        }),
      );
      expect(msg['content'], 'legacy');
    });

    for (final entry in <String, Object>{
      'choice with neither message nor delta': {
        'choices': [<String, dynamic>{}]
      },
      'choice that is not an object': {
        'choices': ['just a string']
      },
      'message that is not an object': {
        'choices': [
          {'message': 'oops'}
        ]
      },
      'no choices key at all': <String, dynamic>{},
      'empty choices list': {'choices': <dynamic>[]},
      'top-level JSON array': <dynamic>[1, 2, 3],
    }.entries) {
      test('throws CoachException (never a TypeError) for ${entry.key}',
          () async {
        await expectLater(
          _post(cfg, _json(entry.value)),
          throwsA(isA<CoachException>()),
        );
      });
    }

    test('a non-JSON body (an HTML error page / wrong base URL) is a '
        'CoachException', () async {
      await expectLater(
        _post(cfg, _json('<html>502 Bad Gateway</html>')),
        throwsA(isA<CoachException>()),
      );
    });

    test('a non-200 is a CoachException carrying the provider message',
        () async {
      await expectLater(
        _post(
          cfg,
          _json({
            'error': {'message': 'invalid api key'}
          }, status: 401),
        ),
        throwsA(isA<CoachException>().having(
            (e) => e.toString(), 'message', contains('invalid api key'))),
      );
    });
  });

  group('postChat request size ceiling', () {
    test('refuses an oversized request WITHOUT contacting the provider',
        () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      });
      final huge = 'x' * (CoachEngine.kMaxRequestBytes + 1024);
      await expectLater(
        CoachEngine.postChat(cfg, {
          'model': 'gpt-4o-mini',
          'messages': [
            {'role': 'user', 'content': huge}
          ],
        }, client: client),
        throwsA(isA<CoachException>()),
      );
      expect(called, isFalse,
          reason: 'health data must never leave the device once over the cap');
    });

    test('a request just under the ceiling still goes out', () async {
      final body = 'y' * (CoachEngine.kMaxRequestBytes ~/ 2);
      final msg = await CoachEngine.postChat(cfg, {
        'model': 'gpt-4o-mini',
        'messages': [
          {'role': 'user', 'content': body}
        ],
      }, client: _json({
        'choices': [
          {
            'message': {'content': 'ok'}
          }
        ]
      }));
      expect(msg['content'], 'ok');
    });

    test('the ceilings are ordered so history can never exceed one request', () {
      expect(CoachEngine.kMaxToolResultChars,
          lessThan(CoachEngine.kMaxHistoryChars));
      expect(CoachEngine.kMaxHistoryChars,
          lessThan(CoachEngine.kMaxRequestBytes));
    });

    test('a keyless config (local Ollama/LM Studio) sends no Authorization '
        'header at all — never the literal "Bearer null"', () async {
      expect(cfg.hasKey, isFalse, reason: 'default cfg carries no API key');
      Map<String, String>? sentHeaders;
      final client = MockClient((req) async {
        sentHeaders = req.headers;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'}
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      await _post(cfg, client);
      expect(sentHeaders!.containsKey('Authorization'), isFalse);
    });
  });
}
