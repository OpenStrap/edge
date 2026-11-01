// "Sign in with ChatGPT" plan usage: the OAuth round trip through a real
// loopback listener, token refresh, and the coach's one provider POST routed
// to OpenAI's streaming-only Responses route with the plan's access token.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:openstrap_edge/coach/coach_chatgpt.dart';
import 'package:openstrap_edge/coach/coach_chatgpt_jwks.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/sync/reset_gate.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Flutter's test binding fakes HttpClient; this one really reaches loopback.
class _RealHttpOverrides extends HttpOverrides {}

// A real RS256 key pair, so the ID token goes through the same signature
// check as OpenAI's. Generated once: 2048-bit generation is the slow part.
final AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _rsa = () {
  final rnd = FortunaRandom()
    ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (i) => i * 7 + 1))));
  final gen = RSAKeyGenerator()
    ..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), rnd));
  final pair = gen.generateKeyPair();
  return AsymmetricKeyPair(pair.publicKey as RSAPublicKey, pair.privateKey as RSAPrivateKey);
}();

const _kid = 'test-kid';

String _b64(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');

String _b64Int(BigInt v) {
  final bytes = <int>[];
  while (v > BigInt.zero) {
    bytes.insert(0, (v & BigInt.from(0xff)).toInt());
    v = v >> 8;
  }
  return base64Url.encode(bytes).replaceAll('=', '');
}

String _sign(String header, String claims, [RSAPrivateKey? key]) {
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(key ?? _rsa.privateKey));
  final sig = signer.generateSignature(Uint8List.fromList(ascii.encode('$header.$claims')));
  return base64Url.encode(sig.bytes).replaceAll('=', '');
}

String _jwt(Map<String, Object?> claims, {Map<String, Object?>? header}) {
  final h = _b64(header ?? {'alg': 'RS256', 'kid': _kid, 'typ': 'JWT'});
  final c = _b64(claims);
  return '$h.$c.${_sign(h, c)}';
}

String _jwksBody([String kid = _kid]) => jsonEncode({
      'keys': [
        {
          'kty': 'RSA',
          'kid': kid,
          'alg': 'RS256',
          'use': 'sig',
          'n': _b64Int(_rsa.publicKey.modulus!),
          'e': _b64Int(_rsa.publicKey.exponent!),
        },
      ],
    });

/// Serves OpenAI's discovery document and key set; null for anything else.
http.Response? _oidc(http.BaseRequest req, {String kid = _kid}) {
  final u = req.url.toString();
  if (u == '$kChatGptIssuer/.well-known/openid-configuration') {
    return http.Response(
        jsonEncode({'issuer': kChatGptIssuer, 'jwks_uri': '$kChatGptIssuer/.well-known/jwks.json'}),
        200);
  }
  if (u == '$kChatGptIssuer/.well-known/jwks.json') return http.Response(_jwksBody(kid), 200);
  return null;
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
            final oidc = _oidc(req);
            if (oidc != null) return oidc;
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

    /// A token endpoint that holds the code exchange until [gate] opens, and
    /// records every revocation.
    ChatGptAuth pendingExchange(Completer<void> gate, Completer<void> arrived,
            List<(String, String, String)> revoked, Uri Function() authorize,
            {bool signed = true}) =>
        ChatGptAuth(client: MockClient((req) async {
          final oidc = _oidc(req);
          if (oidc != null) return oidc;
          if (req.url.path.endsWith('/revoke')) {
            revoked.add((req.bodyFields['token']!, req.bodyFields['token_type_hint']!,
                req.bodyFields['client_id']!));
            return http.Response('', 200);
          }
          arrived.complete();
          await gate.future;
          var id = _idToken(req.bodyFields['client_id']!, authorize().queryParameters['nonce']!);
          if (!signed) id = '${id.substring(0, id.lastIndexOf('.'))}.AAAA';
          return http.Response(
              jsonEncode({
                'access_token': 'at-1',
                'refresh_token': 'rt-1',
                'id_token': id,
                'scope': _fullScope,
              }),
              200);
        }));

    const issued = [
      ('rt-1', 'refresh_token', 'oaiapp_1'),
      ('at-1', 'access_token', 'oaiapp_1'),
    ];

    for (final (what, end) in <(String, Future<void> Function(ChatGptAuth))>[
      ('sign-out', (a) => a.signOut()),
      ('cancel', (a) async => a.cancelSignIn()),
      ('reset', (a) => a.forgetAll()),
    ]) {
      test('a code exchange that lands after a $what revokes what it was issued', () async {
        final gate = Completer<void>(), arrived = Completer<void>();
        final revoked = <(String, String, String)>[];
        late Uri first;
        auth = pendingExchange(gate, arrived, revoked, () => first);
        final signIn = expectLater(
            auth.signIn((u) {
              first = u;
              return browser(u, clientId: 'oaiapp_1');
            }),
            throwsA(isA<ChatGptException>()));
        await arrived.future;
        await end(auth);
        gate.complete();
        await signIn;
        expect(auth.signedIn, isFalse);
        expect(keychain, isEmpty);
        // The reset deleted the saved client id; the revocation still has it.
        expect(revoked, issued);
      });
    }

    test('a sign-in does not start while a reset is running', () async {
      ResetGate.enter();
      addTearDown(ResetGate.resetForTest);
      auth = ChatGptAuth(client: MockClient((_) async => fail('no network')));
      await expectLater(
          auth.signIn((_) async => fail('no browser')),
          throwsA(isA<ChatGptException>().having((e) => e.message, 'message', contains('reset'))));
    });

    test('a code exchange that lands while a reset is running is revoked, not stored', () async {
      addTearDown(ResetGate.resetForTest);
      final gate = Completer<void>(), arrived = Completer<void>();
      final revoked = <(String, String, String)>[];
      late Uri first;
      auth = pendingExchange(gate, arrived, revoked, () => first);
      final signIn = expectLater(
          auth.signIn((u) {
            first = u;
            return browser(u, clientId: 'oaiapp_1');
          }),
          throwsA(isA<ChatGptException>()));
      await arrived.future;
      ResetGate.enter(); // the reset has started but not reached forgetAll yet
      gate.complete();
      await signIn;
      expect(auth.signedIn, isFalse);
      expect(keychain, isEmpty);
      expect(revoked, issued);
    });

    test('an ID token that fails its signature check is revoked, not stored', () async {
      final gate = Completer<void>()..complete(), arrived = Completer<void>();
      final revoked = <(String, String, String)>[];
      late Uri first;
      auth = pendingExchange(gate, arrived, revoked, () => first, signed: false);
      await expectLater(
          auth.signIn((u) {
            first = u;
            return browser(u, clientId: 'oaiapp_1');
          }),
          throwsA(isA<ChatGptException>().having((e) => e.message, 'message', contains('check out'))));
      expect(auth.signedIn, isFalse);
      expect(keychain, isEmpty);
      expect(revoked, issued);
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

  group('ID token signature', () {
    late int fetches;
    late String servedKid;
    late bool down;
    late ChatGptJwks jwks;
    setUp(() {
      fetches = 0;
      servedKid = _kid;
      down = false;
      jwks = ChatGptJwks(
        issuer: kChatGptIssuer,
        get: (u) async {
          if (down) throw const SocketException('offline');
          if (u.path.endsWith('jwks.json')) fetches++;
          return _oidc(http.Request('GET', u), kid: servedKid)!;
        },
      );
    });

    String claims() => _b64({'iss': kChatGptIssuer, 'sub': 'user-1'});

    test('a token signed by a published key verifies, and the keys are cached', () async {
      await jwks.verify(_idToken('oaiapp_1', 'n1'));
      await jwks.verify(_idToken('oaiapp_1', 'n2'));
      expect(fetches, 1);
    });

    test('a forged, re-signed or unsigned token is rejected', () async {
      final good = _idToken('oaiapp_1', 'n1').split('.');
      final h = _b64({'alg': 'RS256', 'kid': _kid});
      for (final token in [
        '${good[0]}.${claims()}.${good[2]}', // claims swapped under the old signature
        '${good[0]}.${good[1]}.${good[2].substring(0, good[2].length - 4)}AAAA',
        '${_b64({'alg': 'none', 'kid': _kid})}.${good[1]}.',
        '${_b64({'alg': 'HS256', 'kid': _kid})}.${good[1]}.${good[2]}',
        '${_b64({'alg': 'RS256'})}.${good[1]}.${good[2]}', // no kid
        '${_b64({'alg': 'RS256', 'kid': _kid, 'jwk': {'kty': 'RSA'}})}.${good[1]}.${good[2]}',
        '$h.${good[1]}',
        'garbage',
      ]) {
        await expectLater(jwks.verify(token), throwsA(isA<ChatGptSignatureException>()),
            reason: token);
      }
    });

    test('an unknown kid refetches once, then is rejected', () async {
      var now = DateTime(2026, 10, 1);
      await withClock(Clock(() => now), () async {
        await jwks.verify(_idToken('oaiapp_1', 'n1'));
        expect(fetches, 1);
        // A kid that is nowhere: rejected, and not a refetch per token.
        for (var i = 0; i < 3; i++) {
          await expectLater(
              jwks.verify(_jwt({'iss': kChatGptIssuer}, header: {'alg': 'RS256', 'kid': 'nope'})),
              throwsA(isA<ChatGptSignatureException>()));
        }
        expect(fetches, 1);
        // Rotated: the token's kid is not cached yet, the new key set has it.
        now = now.add(const Duration(minutes: 1));
        servedKid = 'rotated';
        await jwks.verify(_jwt({'iss': kChatGptIssuer}, header: {'alg': 'RS256', 'kid': 'rotated'}));
        expect(fetches, 2);
      });
    });

    test('keys that cannot be fetched fail closed', () async {
      down = true;
      await expectLater(
          jwks.verify(_idToken('oaiapp_1', 'n1')), throwsA(isA<ChatGptSignatureException>()));
    });

    test('short, non-RSA and encryption keys are not usable', () {
      final n = _b64Int(_rsa.publicKey.modulus!), e = _b64Int(_rsa.publicKey.exponent!);
      final keys = parseChatGptJwks(jsonEncode({
        'keys': [
          {'kty': 'RSA', 'kid': 'ok', 'n': n, 'e': e},
          {'kty': 'RSA', 'kid': 'enc', 'use': 'enc', 'n': n, 'e': e},
          {'kty': 'RSA', 'kid': 'ps', 'alg': 'PS256', 'n': n, 'e': e},
          {'kty': 'RSA', 'kid': 'short', 'n': _b64Int(BigInt.two.pow(1023) + BigInt.one), 'e': e},
          {'kty': 'EC', 'kid': 'ec', 'x': 'AA', 'y': 'AA'},
        ],
      }));
      expect(keys.keys, ['ok']);
    });
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

    test('a dead refresh token signs out even if the keychain delete fails', () async {
      final dead = await expired(
          MockClient((_) async => http.Response(jsonEncode({'error': 'invalid_grant'}), 400)));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'delete') throw PlatformException(code: 'boom', message: 'locked');
        fail('${call.method} must not run');
      });
      await expectLater(dead.accessToken(), throwsA(isA<ChatGptException>()));
      expect(dead.signedIn, isFalse);
      expect((await SharedPreferences.getInstance()).getBool('coach_chatgpt_present'), isFalse);
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

    test('function tools go in a namespace on this route, and history calls carry it', () async {
      final tool = {
        'type': 'function',
        'function': {
          'name': 'run_sql',
          'description': 'query',
          'parameters': {'type': 'object', 'properties': {}},
        },
      };
      late Map sent;
      final reply = await CoachEngine.postChat(cfg, {
        'model': 'gpt-6.1-sol',
        'messages': [
          {'role': 'user', 'content': 'hi'},
          {
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': 'c0',
                'type': 'function',
                'function': {'name': 'run_sql', 'arguments': '{}'},
              },
            ],
          },
          {'role': 'tool', 'tool_call_id': 'c0', 'content': '[]'},
        ],
        'tools': [tool],
        'tool_choice': 'auto',
      }, client: MockClient((req) async {
        sent = jsonDecode(req.body) as Map;
        return http.Response(
            _sse([
              {
                'type': 'response.completed',
                'response': {
                  'status': 'completed',
                  'output': [
                    {
                      'type': 'function_call',
                      'name': 'run_sql',
                      'namespace': kChatGptToolNamespace,
                      'call_id': 'c1',
                      'arguments': '{"sql":"SELECT 1"}',
                      'status': 'completed',
                    },
                  ],
                },
              },
            ]),
            200);
      }));
      final tools = sent['tools'] as List;
      expect(tools, hasLength(1));
      expect(tools.single['type'], 'namespace');
      expect(tools.single['name'], kChatGptToolNamespace);
      expect((tools.single['tools'] as List).single,
          allOf(containsPair('type', 'function'), containsPair('name', 'run_sql')));
      expect(sent['tool_choice'], 'auto');
      final call = (sent['input'] as List).firstWhere((i) => i['type'] == 'function_call');
      expect(call['namespace'], kChatGptToolNamespace);
      expect(call['name'], 'run_sql');
      final out = (reply['tool_calls'] as List).single;
      expect(out['function'], {'name': 'run_sql', 'arguments': '{"sql":"SELECT 1"}'});

      // The API-key route still sends bare top-level function tools.
      await cfg.save(useChatGpt: false, apiKey: 'sk-test');
      await CoachEngine.postChat(cfg, {
        'model': 'gpt-6.1-sol',
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
        'tools': [tool],
      }, client: MockClient((req) async {
        sent = jsonDecode(req.body) as Map;
        return http.Response(jsonEncode(_completed('ok')['response']), 200);
      }));
      expect((sent['tools'] as List).single['type'], 'function');
    });

    test('signed in without plan usage is not configured', () async {
      await cfg.chatgpt.debugSetSession(_session(scope: 'openid email profile offline_access'));
      expect(cfg.configured, isFalse);
    });

    test('a leftover API key does not schedule reminders for a signed-out ChatGPT coach', () async {
      await cfg.save(apiKey: 'sk-left-over');
      expect(cfg.remindersConfigured, isTrue);
      await cfg.chatgpt.signOut();
      expect(cfg.hasKey, isTrue);
      expect(cfg.remindersConfigured, isFalse);
      await cfg.save(useChatGpt: false);
      expect(cfg.remindersConfigured, isTrue, reason: 'the key route still counts its key');
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
      expect(revoked, ['rt-2', 'at-2'], reason: 'the rotated tokens are the live ones');
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
      // The reset revoked the rotated tokens; the sign-out revoked only its own.
      expect(revoked, ['rt-2', 'at-2', 'rt-new', 'at-new']);
    });

    test('a refresh that lands after a new sign-in is revoked, not left for its sign-out', () async {
      SharedPreferences.setMockInitialValues({'coach_chatgpt_client_id': 'oaiapp_1'});
      final oldGate = Completer<void>();
      final revoked = <String>[];
      final refreshed = <String>[];
      final auth = ChatGptAuth(client: MockClient((req) async {
        if (req.url.path.endsWith('/revoke')) {
          revoked.add(req.bodyFields['token']!);
          return http.Response('', 200);
        }
        final rt = req.bodyFields['refresh_token']!;
        refreshed.add(rt);
        if (rt == 'rt-1') await oldGate.future; // the old session's refresh hangs
        return http.Response(
            jsonEncode({
              'access_token': rt == 'rt-1' ? 'at-2' : 'at-new-2',
              'refresh_token': rt == 'rt-1' ? 'rt-2' : 'rt-new-2',
              'expires_in': 3600,
            }),
            200);
      }));
      await auth.debugSetSession(_session(expiresAt: DateTime.now()));
      final stale = expectLater(auth.accessToken(), throwsA(isA<ChatGptException>()));
      await pumpEventQueue();
      // Signed out with the refresh still out (revocation unconfirmed until it
      // lands), then signed straight back in.
      final out = auth.signOut();
      await pumpEventQueue();
      await auth.debugSetSession(ChatGptSession(
          sub: 'user-1',
          email: 'me@example.com',
          idToken: 'i',
          accessToken: 'at-new',
          refreshToken: 'rt-new',
          scope: _fullScope,
          expiresAt: DateTime.now()));
      // The new session refreshes on its own token, not through the old call.
      expect(await auth.accessToken(), 'at-new-2');
      oldGate.complete();
      await stale;
      expect(await out, isTrue);
      expect(revoked, ['rt-2', 'at-2'], reason: 'the old rotation is revoked as it lands');
      expect(auth.session!.refreshToken, 'rt-new-2');
      revoked.clear();
      await auth.signOut();
      expect(revoked, ['rt-new-2', 'at-new-2'], reason: "the sign-out revokes the current session's tokens");
      expect(refreshed, ['rt-1', 'rt-new']);
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

    for (final status in [200, 500]) {
      test('forgetAll revokes, then clears the session, registration and welcome flag; '
          'welcome shows once (revoke $status)', () async {
        SharedPreferences.setMockInitialValues({
          'coach_chatgpt_client_id': 'oaiapp_1',
          'coach_chatgpt_host_id': 'urn:uuid:h',
        });
        final revoked = <String>[];
        final auth = ChatGptAuth(client: MockClient((req) async {
          expect(req.url.path, endsWith('/revoke'));
          expect(req.bodyFields['client_id'], 'oaiapp_1');
          revoked.add(req.bodyFields['token']!);
          return http.Response('', status);
        }));
        await auth.debugSetSession(_session());
        expect(await auth.takeWelcome(), isTrue);
        expect(await auth.takeWelcome(), isFalse);
        expect(await auth.forgetAll(), status == 200,
            reason: 'reset reports a revocation it could not confirm');
        final prefs = await SharedPreferences.getInstance();
        expect(revoked, ['rt-1', 'at-1']);
        expect(auth.signedIn, isFalse);
        expect(keychain, isEmpty);
        expect(prefs.getKeys().where((k) => k.startsWith('coach_chatgpt_')), isEmpty);
        expect(await auth.takeWelcome(), isTrue);
      });
    }

    test('a refresh whose keychain write fails keeps the rotated token in memory', () async {
      SharedPreferences.setMockInitialValues({'coach_chatgpt_client_id': 'oaiapp_1'});
      final sent = <String>[];
      var n = 0;
      final auth = ChatGptAuth(client: MockClient((req) async {
        sent.add(req.bodyFields['refresh_token']!);
        n++;
        return http.Response(
            jsonEncode({'access_token': 'at-${n + 1}', 'refresh_token': 'rt-${n + 1}', 'expires_in': 1}),
            200);
      }));
      await auth.debugSetSession(_session(expiresAt: DateTime.now()));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'write') throw PlatformException(code: 'boom', message: 'disk full');
        fail('${call.method} must not run');
      });
      expect(await auth.accessToken(), 'at-2');
      expect(auth.session!.refreshToken, 'rt-2');
      // Still expiring (expires_in: 1), so the next call refreshes again.
      expect(await auth.accessToken(), 'at-3');
      expect(sent, ['rt-1', 'rt-2'], reason: 'the spent token is never sent again');
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
