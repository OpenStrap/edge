import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/integrations/oauth_loopback.dart';
import 'package:openstrap_edge/integrations/openrouter.dart';

void main() {
  test('authorize uri carries the S256 challenge and the loopback callback', () {
    final u = openRouterAuthorizeUri('http://localhost:5000/callback', 'st', 'ch');
    expect(u.host, 'openrouter.ai');
    expect(u.queryParameters['callback_url'], 'http://localhost:5000/callback');
    expect(u.queryParameters['code_challenge_method'], 'S256');
    expect(u.queryParameters['code_challenge'], 'ch');
    expect(u.queryParameters['state'], 'st');
  });

  test('key parse', () {
    expect(parseOpenRouterKey(200, '{"key":"sk-or-v1-abc"}'), 'sk-or-v1-abc');
    expect(() => parseOpenRouterKey(400, '{"error":"bad"}'), throwsA(isA<OAuthException>()));
    expect(() => parseOpenRouterKey(200, '{"key":""}'), throwsA(isA<OAuthException>()));
  });

  test('pkce challenge is RFC 7636 S256', () {
    // RFC 7636 appendix B vector.
    expect(pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });

  test('loopback returns the redirect query and closes', () async {
    final auth = LoopbackAuth(host: 'localhost');
    final r = await auth.run(
      authorize: (redirect, state, _) => Uri.parse('$redirect?code=c1&state=$state'),
      open: (uri) async {
        // Stand in for the browser following the redirect.
        final c = HttpClient();
        final res = await (await c.getUrl(uri)).close();
        c.close();
        return res.statusCode == 200;
      },
    );
    expect(r.code, 'c1');
    expect(r.redirectUri, startsWith('http://localhost:'));
  });

  test('cancel ends a waiting sign-in', () async {
    final auth = LoopbackAuth();
    final f = auth.run(authorize: (r, s, c) => Uri.parse(r), open: (_) async => true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    auth.cancel();
    await expectLater(f, throwsA(isA<OAuthException>()));
  });
}
