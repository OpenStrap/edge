// One-tap OpenRouter: the user signs in on openrouter.ai and approves a key
// that belongs to their own account and credits. No client registration and
// no secret; the key lands in the coach's keychain slot like a pasted one.
// https://openrouter.ai/docs/guides/overview/auth/oauth

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'oauth_loopback.dart';

const kOpenRouterBaseUrl = 'https://openrouter.ai/api/v1';

Uri openRouterAuthorizeUri(String redirectUri, String state, String challenge) =>
    Uri.parse('https://openrouter.ai/auth').replace(queryParameters: {
      'callback_url': redirectUri,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
      'key_label': 'OpenStrap Edge',
    });

/// Runs the sign-in and returns the new key. [auth] is the caller's handle
/// for cancelling while the browser is up.
Future<String> openRouterSignIn(LoopbackAuth auth, Future<bool> Function(Uri) open,
    {http.Client? client}) async {
  final r = await auth.run(authorize: openRouterAuthorizeUri, open: open);
  final c = client ?? http.Client();
  try {
    final resp = await c
        .post(Uri.parse('https://openrouter.ai/api/v1/auth/keys'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'code': r.code,
              'code_verifier': r.verifier,
              'code_challenge_method': 'S256',
            }))
        .timeout(const Duration(seconds: 30));
    return parseOpenRouterKey(resp.statusCode, resp.body);
  } finally {
    if (client == null) c.close();
  }
}

String parseOpenRouterKey(int status, String body) {
  Object? j;
  try {
    j = jsonDecode(body);
  } catch (_) {}
  if (status == 200 && j is Map && j['key'] is String && (j['key'] as String).isNotEmpty) {
    return j['key'] as String;
  }
  throw OAuthException('OpenRouter sign-in failed ($status). Try again.');
}
