// One browser sign-in for the integrations that hand back an auth code: PKCE,
// a state check, and a listener on this device's loopback for the redirect.
// The page must open in an in-app browser (SFSafariViewController / Custom
// Tab): with the system browser in front, iOS suspends the app and the
// listener dies.
//
// ponytail: the ChatGPT sign-in keeps its own copy of this loop because its
// flow (dynamic client registration, nonce, JWKS) is wired through it; move it
// over only when that file is next touched for another reason.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A sign-in failure worded for the user.
class OAuthException implements Exception {
  final String message;
  OAuthException(this.message);
  @override
  String toString() => message;
}

String oauthRandom() {
  final r = Random.secure();
  return base64Url.encode(List.generate(32, (_) => r.nextInt(256))).replaceAll('=', '');
}

/// RFC 7636 S256 challenge for [verifier].
String pkceChallenge(String verifier) =>
    base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');

/// What the provider sent back on the redirect.
class LoopbackResult {
  final Map<String, String> query;
  final String redirectUri;
  final String verifier;
  const LoopbackResult(this.query, this.redirectUri, this.verifier);
  String get code => query['code']!;
}

/// One sign-in attempt. [cancel] ends a [run] still waiting on the browser:
/// nothing tells the app when the user simply closes the in-app browser.
class LoopbackAuth {
  /// `localhost` for providers that only accept that host. The listener is
  /// then bound on both loopback families, because the browser may resolve
  /// `localhost` to either.
  final String host;
  final String path;
  final List<HttpServer> _servers = [];
  bool _cancelled = false;

  LoopbackAuth({this.host = '127.0.0.1', this.path = '/callback'});

  void cancel() {
    _cancelled = true;
    for (final s in _servers) {
      s.close(force: true);
    }
  }

  /// [authorize] builds the provider's page from the redirect URI, the state
  /// and the PKCE challenge; [open] shows it.
  Future<LoopbackResult> run({
    required Uri Function(String redirectUri, String state, String challenge) authorize,
    required Future<bool> Function(Uri) open,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final v4 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _servers.add(v4);
    if (host == 'localhost') {
      try {
        _servers.add(await HttpServer.bind(InternetAddress.loopbackIPv6, v4.port));
      } catch (_) {} // no IPv6 loopback: the browser falls back to IPv4
    }
    try {
      if (_cancelled) throw OAuthException('Sign-in was cancelled.');
      final redirectUri = 'http://$host:${v4.port}$path';
      final state = oauthRandom(), verifier = oauthRandom();
      final got = Completer<Map<String, String>>();
      // A cancel can fail this before the await below is reached; the await
      // still delivers the error, this only stops it counting as unhandled.
      got.future.ignore();
      var open_ = _servers.length;
      for (final s in _servers) {
        // Every listener closed (cancel) without a redirect.
        _listen(s, state, got, onDone: () {
          if (--open_ == 0 && !got.isCompleted) {
            got.completeError(OAuthException('Sign-in was cancelled.'));
          }
        });
      }
      // Listening BEFORE the browser opens: the redirect can beat open().
      if (!await open(authorize(redirectUri, state, pkceChallenge(verifier)))) {
        throw OAuthException('Could not open the browser.');
      }
      final q = await got.future.timeout(timeout, onTimeout: () => throw OAuthException('Sign-in timed out. Try again.'));
      if (q['error'] != null) {
        throw OAuthException(q['error'] == 'access_denied'
            ? 'Sign-in was cancelled.'
            : 'Sign-in failed: ${q['error_description'] ?? q['error']}');
      }
      if (q['code'] == null) throw OAuthException('Sign-in returned no code.');
      return LoopbackResult(q, redirectUri, verifier);
    } finally {
      for (final s in _servers) {
        await s.close(force: true);
      }
    }
  }

  void _listen(HttpServer server, String state, Completer<Map<String, String>> got,
      {required void Function() onDone}) {
    server.listen((req) async {
      final q = req.uri.queryParameters;
      final ours = req.uri.path == path && q['state'] == state;
      req.response
        ..statusCode = ours ? 200 : 400
        ..headers.contentType = ContentType.html
        ..write(ours
            ? '<!doctype html><meta name="viewport" content="width=device-width">'
                '<p style="font:16px system-ui;margin:2em">Done. You can close '
                'this page and go back to OpenStrap.</p>'
            : 'Bad request');
      await req.response.close();
      if (ours && !got.isCompleted) got.complete(q);
    }, onError: (_) {}, onDone: onDone);
  }
}
