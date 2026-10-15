// "Sign in with ChatGPT" plan usage: the OAuth round trip through a real
// loopback listener, token refresh, and the coach's one provider POST routed
// to OpenAI's streaming-only Responses route with the plan's access token.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:openstrap_edge/coach/coach_chatgpt.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Flutter's test binding fakes HttpClient; this one really reaches loopback.
class _RealHttpOverrides extends HttpOverrides {}

String _jwt(Map<String, Object?> claims) {
  String b64(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b64({'alg': 'RS256'})}.${b64(claims)}.sig';
}

String _idToken(String clientId, String nonce, {String iss = kChatGptIssuer, int? exp}) =>
    _jwt({
      'iss': iss,
      'aud': clientId,
      'sub': 'user-1',
      'email': 'me@example.com',
      'nonce': nonce,
      'exp': exp ?? DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
    });

const _fullScope = 'chatgpt.tokens.use.direct email offline_access openid profile resource.invoke';

ChatGptSession _session({DateTime? expiresAt, String scope = _fullScope}) => ChatGptSession(
      sub: 'user-1',
      email: 'me@example.com',
      idToken: 'old-id-token',
      accessToken: 'at-1',
      refreshToken: 'rt-1',
      scope: scope,
      expiresAt: expiresAt ?? DateTime.now().add(const Duration(hours: 1)),
    );

String _sse(List<Map<String, Object?>> events) =>
    events.map((e) => 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n').join();

Map<String, Object?> _completed(String text) => {
      'type': 'response.completed',
      'response': {
        'status': 'completed',
        'output': [
          {
            'type': 'message',
            'status': 'completed',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': text, 'annotations': []},
            ],
          },
        ],
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> keychain;
  Completer<void>? writeGate; // hangs keychain writes until completed

  setUp(() {
    keychain = {};
    writeGate = null;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'read':
          return keychain[args['key']];
        case 'write':
          await writeGate?.future;
          keychain[args['key'] as String] = args['value'] as String;
        case 'delete':
          keychain.remove(args['key']);
        case 'containsKey':
          return keychain.containsKey(args['key']);
      }
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('PKCE challenge is the RFC 7636 S256 transform', () {
    expect(chatGptCodeChallenge('dBjftJeZ4CVP-mJ92K9qn6MWHFJM1yN_GgcsRmJN0_w'),
        'BCCYQ8sMKFQG5yknl8BJ9-8mva0FhJQJZSboXfUVfsc');
  });

  group('sign-in', () {
    late List<Map<String, String>> tokenForms;
    late ChatGptAuth auth;
    late http.Client loopback;

    setUp(() {
      tokenForms = [];
      loopback = IOClient(_RealHttpOverrides().createHttpClient(null));
      addTearDown(loopback.close);
    });

    /// Plays the browser: first a stray hit with the wrong state, which must
    /// not end the sign-in, then the real redirect.
    Future<bool> browser(Uri authorize, {String? clientId, String? error}) async {
      final q = authorize.queryParameters;
      final redirect = Uri.parse(q['redirect_uri']!);
      expect(redirect.host, '127.0.0.1');
      expect(redirect.path, '/auth/callback');
      final stray = await loopback.get(redirect.replace(queryParameters: {'state': 'nope', 'code': 'x'}));
      expect(stray.statusCode, 400);
      unawaited(loopback.get(redirect.replace(queryParameters: {
        'state': q['state']!,
        if (error != null) 'error': error else 'code': 'code-1',
        'client_id': ?clientId,
      })));
      return true;
    }

    ChatGptAuth makeAuth(String Function() nonce) => ChatGptAuth(
          client: MockClient((req) async {
            expect(req.url.toString(), '$kChatGptIssuer/api/accounts/oauth/token');
            tokenForms.add(req.bodyFields);
            if (req.bodyFields['grant_type'] == 'authorization_code') {
              expect(req.bodyFields['code'], 'code-1');
            }
            return http.Response(
              jsonEncode({
                'access_token': 'at-1',
                'refresh_token': 'rt-1',
                'id_token': _idToken(req.bodyFields['client_id']!, nonce()),
                'scope': _fullScope,
                'expires_in': 3600,
              }),
              200,
            );
          }),
        );

    test('registers, exchanges the code, and signs back in to the same registration', () async {
      late Uri first, second;
      auth = makeAuth(() => (second.hasQuery ? second : first).queryParameters['nonce']!);
      second = Uri();
      await auth.signIn((u) {
        first = u;
        return browser(u, clientId: 'oaiapp_1');
      });
      final q = first.queryParameters;
      expect(q['client_id'], 'dynamic_agent_client');
      expect(q['agent_name_hint'], 'OpenStrap Edge');
      expect(q['ext_agent_host_id'], startsWith('urn:uuid:'));
      expect(q['scope']!.split(' '), containsAll(['offline_access', 'resource.invoke', kChatGptPlanScope]));
      expect(q['resource'], kChatGptApiBase);
      expect(q['code_challenge_method'], 'S256');
      expect(tokenForms.single, containsPair('client_id', 'oaiapp_1'));
      expect(tokenForms.single, containsPair('grant_type', 'authorization_code'));
      expect(tokenForms.single, containsPair('redirect_uri', q['redirect_uri']));
      expect(chatGptCodeChallenge(tokenForms.single['code_verifier']!), q['code_challenge']);
      expect(auth.sharing, isTrue);
      expect(auth.session!.email, 'me@example.com');

      // Returning sign-in: the saved client id and host id, no name hint.
      await auth.signIn((u) {
        second = u;
        return browser(u);
      });
      expect(second.queryParameters['client_id'], 'oaiapp_1');
      expect(second.queryParameters['ext_agent_host_id'], q['ext_agent_host_id']);
      expect(second.queryParameters.containsKey('agent_name_hint'), isFalse);
      expect(second.queryParameters['id_token_hint'], isNotNull);
    });

    test('sign-out while the code exchange is pending leaves nothing stored', () async {
      final gate = Completer<void>(), arrived = Completer<void>();
      late Uri first;
      auth = ChatGptAuth(client: MockClient((req) async {
        arrived.complete();
        await gate.future;
        return http.Response(
            jsonEncode({
              'access_token': 'at-1',
              'refresh_token': 'rt-1',
              'id_token': _idToken(req.bodyFields['client_id']!, first.queryParameters['nonce']!),
              'scope': _fullScope,
            }),
            200);
      }));
      final signIn = expectLater(
          auth.signIn((u) {
            first = u;
            return browser(u, clientId: 'oaiapp_1');
          }),
          throwsA(isA<ChatGptException>()));
      await arrived.future;
      await auth.signOut();
      gate.complete();
      await signIn;
      expect(auth.signedIn, isFalse);
      expect(keychain, isEmpty);
    });

    test('a sign-in already writing when sign-out starts is cleared afterwards', () async {
      writeGate = Completer<void>();
      final auth = ChatGptAuth();
      final store = expectLater(auth.debugSetSession(_session()), throwsA(isA<ChatGptException>()));
      await pumpEventQueue();
      final out = auth.signOut();
      await pumpEventQueue();
      writeGate!.complete();
      await out;
      await store;
      expect(auth.signedIn, isFalse);
      expect(keychain, isEmpty);
      expect((await SharedPreferences.getInstance()).getBool('coach_chatgpt_present'), isFalse);
    });

    test('a declined consent ends sign-in without a token exchange', () async {
      auth = makeAuth(() => '');
      await expectLater(
        auth.signIn((u) => browser(u, error: 'access_denied')),
        throwsA(isA<ChatGptException>().having((e) => e.message, 'message', contains('cancelled'))),
      );
      expect(tokenForms, isEmpty);
      expect(auth.signedIn, isFalse);
    });
  });

  test('closing the browser can be cancelled instead of waiting it out', () async {
    final auth = ChatGptAuth(client: MockClient((_) async => fail('no token exchange')));
    await expectLater(
      auth.signIn((_) async {
        auth.cancelSignIn(); // the user gave up while the page was up
        return true;
      }),
      throwsA(isA<ChatGptException>().having((e) => e.message, 'message', contains('cancelled'))),
    );
  });

  test('ID token claims are checked', () {
    final good = _idToken('oaiapp_1', 'n1');
    expect(chatGptIdentity(good, clientId: 'oaiapp_1', nonce: 'n1').sub, 'user-1');
    for (final (token, client, nonce) in [
      (good, 'oaiapp_1', 'other-nonce'),
      (good, 'oaiapp_2', 'n1'),
      (_idToken('oaiapp_1', 'n1', iss: 'https://evil.example'), 'oaiapp_1', 'n1'),
      (_idToken('oaiapp_1', 'n1', exp: 1), 'oaiapp_1', 'n1'),
      ('garbage', 'oaiapp_1', 'n1'),
    ]) {
      expect(() => chatGptIdentity(token, clientId: client, nonce: nonce),
          throwsA(isA<ChatGptException>()));
    }
  });

  group('refresh', () {
    Future<ChatGptAuth> expired(http.Client c) async {
      SharedPreferences.setMockInitialValues({'coach_chatgpt_client_id': 'oaiapp_1'});
      final auth = ChatGptAuth(client: c);
      await auth.debugSetSession(_session(expiresAt: DateTime.now()));
      return auth;
    }

    test('concurrent callers share one rotation', () async {
      final forms = <Map<String, String>>[];
      final auth = await expired(MockClient((req) async {
        forms.add(req.bodyFields);
        return http.Response(
            jsonEncode({'access_token': 'at-2', 'refresh_token': 'rt-2', 'expires_in': 3600}), 200);
      }));
      final tokens = await Future.wait([auth.accessToken(), auth.accessToken()]);
      expect(tokens, ['at-2', 'at-2']);
      expect(forms.single, {
        'grant_type': 'refresh_token',
        'client_id': 'oaiapp_1',
        'refresh_token': 'rt-1',
        'resource': kChatGptApiBase,
      });
      expect(auth.session!.refreshToken, 'rt-2');
      expect(auth.sharing, isTrue, reason: 'scope carried over when not re-sent');
    });

    test('a dead refresh token signs out; a server hiccup does not', () async {
      final hiccup = await expired(MockClient((_) async => http.Response('oops', 502)));
      await expectLater(hiccup.accessToken(), throwsA(isA<ChatGptException>()));
      expect(hiccup.signedIn, isTrue);

      final dead = await expired(
          MockClient((_) async => http.Response(jsonEncode({'error': 'invalid_grant'}), 400)));
      await expectLater(dead.accessToken(), throwsA(isA<ChatGptException>()));
      expect(dead.signedIn, isFalse);
    });
  });

  group('coach requests on the ChatGPT plan', () {
    late CoachConfig cfg;
    setUp(() async {
      cfg = CoachConfig();
      await cfg.chatgpt.debugSetSession(_session());
      await cfg.save(useChatGpt: true, model: 'gpt-6.1-sol');
    });

    Future<Map<String, dynamic>> post(http.Client c) => CoachEngine.postChat(cfg, {
          'model': 'gpt-6.1-sol',
          'messages': [
            {'role': 'system', 'content': 'be brief'},
            {'role': 'user', 'content': 'hi'},
          ],
          'temperature': 0.3,
        }, client: c);

    test('streams to the public Responses API with the plan token', () async {
      expect(cfg.configured, isTrue);
      expect(cfg.isPrivateEndpoint, isFalse, reason: 'health data leaving the phone still asks first');
      late http.Request sent;
      final reply = await post(MockClient((req) async {
        sent = req;
        return http.Response(
          _sse([
            {'type': 'response.output_text.delta', 'delta': 'hel'},
            _completed('hello'),
          ]),
          200,
        );
      }));
      expect(sent.url.toString(), '$kChatGptApiBase/responses');
      expect(sent.headers['Authorization'], 'Bearer at-1');
      final body = jsonDecode(sent.body) as Map;
      expect(body['stream'], isTrue);
      expect(body['store'], isFalse);
      expect(body.containsKey('temperature'), isFalse);
      expect([for (final i in body['input'] as List) i['role']], ['developer', 'user']);
      expect(reply['content'], 'hello');
    });

    test('output comes from output_item.done when completed.output is empty', () async {
      Map<String, Object?> done(int i, Map<String, Object?> item) =>
          {'type': 'response.output_item.done', 'output_index': i, 'item': item};
      Map<String, Object?> empty() => {
            'type': 'response.completed',
            'response': {'status': 'completed', 'output': []},
          };
      final message = (_completed('hello')['response'] as Map)['output'][0] as Map<String, Object?>;
      var reply = await post(MockClient(
          (_) async => http.Response(_sse([done(0, message), empty()]), 200)));
      expect(reply['content'], 'hello');
      reply = await post(MockClient((_) async => http.Response(
          _sse([
            done(1, {'type': 'function_call', 'call_id': 'c1', 'name': 'f', 'arguments': '{}', 'status': 'completed'}),
            done(0, message),
            empty(),
          ]),
          200)));
      expect(reply['content'], 'hello');
      expect((reply['tool_calls'] as List).single['id'], 'c1');
    });

    test('usage limit, mid-stream failure and a cut-off stream are errors, never a fallback', () async {
      await cfg.save(apiKey: 'sk-test');
      for (final (status, body, expected) in [
        (
          429,
          jsonEncode({'error': {'code': 'subscription_sharing_usage_limit_exceeded'}}),
          'Usage limit reached'
        ),
        (
          200,
          _sse([
            {
              'type': 'response.failed',
              'response': {'error': {'code': 'subscription_sharing_usage_limit_exceeded'}},
            },
          ]),
          'Usage limit reached'
        ),
        (200, _sse([{'type': 'response.output_text.delta', 'delta': 'he'}]), 'ended early'),
      ]) {
        final sent = <http.Request>[];
        await expectLater(
          post(MockClient((req) async {
            sent.add(req);
            return http.Response(body, status);
          })),
          throwsA(isA<CoachException>().having((e) => e.message, 'message', contains(expected))),
        );
        expect(sent, hasLength(1), reason: 'no fallback request');
        expect(sent.single.headers['Authorization'], 'Bearer at-1');
      }
    });

    test('signed in without plan usage is not configured', () async {
      await cfg.chatgpt.debugSetSession(_session(scope: 'openid email profile offline_access'));
      expect(cfg.configured, isFalse);
    });
  });

  group('session lifecycle', () {
    test('sign-out during an in-flight refresh does not resurrect the session', () async {
      SharedPreferences.setMockInitialValues({'coach_chatgpt_client_id': 'oaiapp_1'});
      final gate = Completer<void>();
      final revoked = <String>[];
      final auth = ChatGptAuth(client: MockClient((req) async {
        if (req.url.path.endsWith('/revoke')) {
          revoked.add(req.bodyFields['token']!);
          return http.Response('', 200);
        }
        await gate.future;
        return http.Response(
            jsonEncode({'access_token': 'at-2', 'refresh_token': 'rt-2', 'expires_in': 3600}), 200);
      }));
      await auth.debugSetSession(_session(expiresAt: DateTime.now()));
      final refresh = auth.accessToken();
      final refreshed = expectLater(refresh, throwsA(isA<ChatGptException>()));
      await pumpEventQueue();
      final out = auth.signOut();
      await pumpEventQueue();
      gate.complete();
      expect(await out, isTrue);
      await refreshed;
      expect(auth.signedIn, isFalse);
      expect(keychain, isEmpty);
      expect(revoked, ['rt-2'], reason: 'the rotated token is the live one');
    });

    test('a reset during a refresh does not make a later sign-out revoke the stale token', () async {
      SharedPreferences.setMockInitialValues({'coach_chatgpt_client_id': 'oaiapp_1'});
      final gate = Completer<void>();
      final revoked = <String>[];
      final auth = ChatGptAuth(client: MockClient((req) async {
        if (req.url.path.endsWith('/revoke')) {
          revoked.add(req.bodyFields['token']!);
          return http.Response('', 200);
        }
        await gate.future;
        return http.Response(
            jsonEncode({'access_token': 'at-2', 'refresh_token': 'rt-2', 'expires_in': 3600}), 200);
      }));
      await auth.debugSetSession(_session(expiresAt: DateTime.now()));
      final refreshed = expectLater(auth.accessToken(), throwsA(isA<ChatGptException>()));
      await pumpEventQueue();
      final reset = auth.forgetAll();
      gate.complete();
      await reset;
      await refreshed;
      // Signed in again, then out: the new session's token is the one revoked.
      (await SharedPreferences.getInstance()).setString('coach_chatgpt_client_id', 'oaiapp_2');
      await auth.debugSetSession(ChatGptSession(
          sub: 'user-1',
          email: 'me@example.com',
          idToken: 'i',
          accessToken: 'at-new',
          refreshToken: 'rt-new',
          scope: _fullScope,
          expiresAt: DateTime.now().add(const Duration(hours: 1))));
      await auth.signOut();
      expect(revoked, ['rt-new']);
    });

    test('a sign-in during a slow sign-out survives it', () async {
      SharedPreferences.setMockInitialValues({'coach_chatgpt_client_id': 'oaiapp_1'});
      final gate = Completer<void>();
      final auth = ChatGptAuth(client: MockClient((req) async {
        await gate.future; // revocation still out
        return http.Response('', 200);
      }));
      await auth.debugSetSession(_session());
      final out = auth.signOut();
      await pumpEventQueue();
      await auth.debugSetSession(_session(scope: '$_fullScope x')); // signed back in
      gate.complete();
      await out;
      expect(auth.signedIn, isTrue);
      expect(keychain, isNotEmpty);
      expect((await SharedPreferences.getInstance()).getBool('coach_chatgpt_present'), isTrue);
    });

    test('a non-duplicate keychain write failure leaves the stored session alone', () async {
      final auth = ChatGptAuth();
      await auth.debugSetSession(_session());
      final stored = keychain.values.single;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'write') throw PlatformException(code: 'boom', message: 'disk full');
        fail('${call.method} must not run');
      });
      await expectLater(
          auth.debugSetSession(ChatGptSession(
              sub: 'user-1',
              email: 'me@example.com',
              idToken: 'i',
              accessToken: 'at-9',
              refreshToken: 'rt-9',
              scope: _fullScope,
              expiresAt: DateTime.now().add(const Duration(hours: 1)))), throwsA(isA<PlatformException>()));
      expect(auth.session!.accessToken, 'at-1');
      expect(keychain.values.single, stored);
    });

    for (final prefs in [<String, Object>{'coach_chatgpt_present': false}, <String, Object>{}]) {
      test('load drops a keychain record the present marker does not vouch for ($prefs)', () async {
        SharedPreferences.setMockInitialValues(prefs);
        keychain['coach_chatgpt_session'] = jsonEncode(_session().toJson());
        final auth = ChatGptAuth();
        await auth.load(trusted: true);
        expect(auth.signedIn, isFalse);
        expect(keychain, isEmpty);
      });
    }

    test('forgetAll clears the session, registration and welcome flag; welcome shows once', () async {
      SharedPreferences.setMockInitialValues({
        'coach_chatgpt_client_id': 'oaiapp_1',
        'coach_chatgpt_host_id': 'urn:uuid:h',
      });
      final auth = ChatGptAuth();
      await auth.debugSetSession(_session());
      expect(await auth.takeWelcome(), isTrue);
      expect(await auth.takeWelcome(), isFalse);
      await auth.forgetAll();
      final prefs = await SharedPreferences.getInstance();
      expect(auth.signedIn, isFalse);
      expect(keychain, isEmpty);
      expect(prefs.getKeys().where((k) => k.startsWith('coach_chatgpt_')), isEmpty);
      expect(await auth.takeWelcome(), isTrue);
    });
  });

  test('model list keeps listed slugs in server order', () async {
    final auth = ChatGptAuth(
      client: MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer at-1');
        return http.Response(
          jsonEncode({
            'models': [
              {'slug': 'gpt-6.1-sol', 'visibility': 'list'},
              {'slug': 'hidden', 'visibility': 'hide'},
              {'slug': 'gpt-5.6-terra', 'visibility': 'list'},
            ],
          }),
          200,
        );
      }),
    );
    await auth.debugSetSession(_session());
    expect(await auth.listModels(), ['gpt-6.1-sol', 'gpt-5.6-terra']);
  });
}
