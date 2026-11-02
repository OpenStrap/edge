// "Sign in with ChatGPT" plan usage for the coach: the user's own ChatGPT plan
// pays for eligible requests instead of an API key. Open-source apps register
// themselves dynamically — no client secret, nothing of ours in the loop. The
// tokens live in the platform keychain beside the BYOK key and are only ever
// sent to auth.openai.com and api.openai.com.
// https://developers.openai.com/siwc/token-sharing-open-source

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../sync/reset_gate.dart';
import 'coach_chatgpt_jwks.dart';

const kChatGptIssuer = 'https://auth.openai.com';

/// Both the OAuth `resource` and the Responses API base requests go to.
const kChatGptApiBase = 'https://api.openai.com/v1';
const kChatGptUsageUrl = 'https://chatgpt.com/settings/usage';
const kOpenAiTermsUrl = 'https://openai.com/policies/terms-of-use/';
const kOpenAiUsagePoliciesUrl = 'https://openai.com/policies/usage-policies/';
const kChatGptPlanScope = 'chatgpt.tokens.use.direct';

// ponytail: endpoints copied from $kChatGptIssuer/.well-known/openid-configuration
// rather than discovered per sign-in; switch to discovery if they ever move.
const _authorizeUrl = '$kChatGptIssuer/api/accounts/authorize';
const _tokenUrl = '$kChatGptIssuer/api/accounts/oauth/token';
const _revokeUrl = '$kChatGptIssuer/api/accounts/oauth/revoke';
const _scopes =
    'openid profile email offline_access resource.invoke $kChatGptPlanScope';
const _agentName = 'OpenStrap Edge';

/// True for the iOS/macOS errSecDuplicateItem shape the plugin surfaces when
/// its own check-then-act (containsKey -> update, else add) still lands on
/// top of an item it did not find — a leftover from a prior install is the
/// reported real-world trigger, since Keychain items routinely outlive an app
/// uninstall while everything else this app stores does not.
bool isKeychainDuplicateItemError(Object e) {
  if (e is! PlatformException) return false;
  final details = e.details;
  if (details is int && details == -25299) return true;
  final text = '${e.message ?? ''} ${e.details ?? ''}';
  return text.contains('-25299') ||
      text.contains('already exists in the keychain');
}

/// A sign-in or token failure with a message fit to show the user.
class ChatGptException implements Exception {
  final String message;
  ChatGptException(this.message);
  @override
  String toString() => message;
}

/// The authorize URL. A null [clientId] registers this app on the account
/// (`dynamic_agent_client`); a saved one signs back in to that registration.
Uri chatGptAuthorizeUri({
  required String? clientId,
  required String hostId,
  required String redirectUri,
  required String state,
  required String nonce,
  required String codeVerifier,
  String? idTokenHint,
}) =>
    Uri.parse(_authorizeUrl).replace(queryParameters: {
      'client_id': clientId ?? 'dynamic_agent_client',
      if (clientId == null) 'agent_name_hint': _agentName,
      'ext_agent_host_id': hostId,
      'id_token_hint': ?idTokenHint,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'scope': _scopes,
      'resource': kChatGptApiBase,
      'state': state,
      'nonce': nonce,
      'code_challenge_method': 'S256',
      'code_challenge': chatGptCodeChallenge(codeVerifier),
    });

String chatGptCodeChallenge(String verifier) =>
    base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');

/// The ID token's `sub` and `email` once its claims check out. Only the
/// claims are checked here (iss/aud/exp/nonce); the caller verifies the
/// signature first with [ChatGptJwks.verify].
({String sub, String email}) chatGptIdentity(
  String idToken, {
  required String clientId,
  required String nonce,
  DateTime? now,
}) {
  final Map claims;
  try {
    final parts = idToken.split('.');
    claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    ) as Map;
  } catch (_) {
    throw ChatGptException('ChatGPT returned an unreadable sign-in.');
  }
  final aud = claims['aud'];
  final exp = claims['exp'];
  final ok = claims['iss'] == kChatGptIssuer &&
      (aud == clientId || (aud is List && aud.contains(clientId))) &&
      claims['nonce'] == nonce &&
      exp is num &&
      exp * 1000 > (now ?? clock.now()).millisecondsSinceEpoch &&
      claims['sub'] is String;
  if (!ok) throw ChatGptException('ChatGPT returned a sign-in that did not check out.');
  return (sub: claims['sub'] as String, email: (claims['email'] ?? '').toString());
}

/// The final `response` of a streamed Responses call. This route only
/// streams; the whole body is buffered and the completed response is handed
/// to the same parser as non-streamed replies. `response.completed` is the
/// success signal, but on this route its `output` can be empty — the items
/// arrive earlier as `response.output_item.done`, so they are taken from
/// there. Anything short of `response.completed` is a failure.
Map<String, dynamic> chatGptCompletedResponse(String sse) {
  final items = <(int, Map<String, dynamic>)>[];
  for (final line in const LineSplitter().convert(sse)) {
    if (!line.startsWith('data:')) continue;
    final Object? event;
    try {
      event = jsonDecode(line.substring(5).trim());
    } catch (_) {
      continue; // `[DONE]` and keep-alives
    }
    if (event is! Map) continue;
    switch (event['type']) {
      case 'response.output_item.done':
        final item = event['item'];
        if (item is Map) {
          final i = event['output_index'];
          items.add((i is int ? i : items.length, item.cast<String, dynamic>()));
        }
      case 'response.completed':
        final r = event['response'];
        if (r is! Map) break;
        final out = r['output'];
        if (out is List && out.isNotEmpty) return r.cast<String, dynamic>();
        items.sort((a, b) => a.$1.compareTo(b.$1));
        return {...r.cast<String, dynamic>(), 'output': [for (final e in items) e.$2]};
      case 'response.failed' || 'error':
        final err = (event['response'] is Map ? event['response']['error'] : null) ??
            event['error'] ??
            event;
        throw ChatGptException(chatGptErrorMessage(
          null,
          err is Map ? err['code']?.toString() : null,
          err is Map ? err['message']?.toString() : null,
        ));
      case 'response.incomplete':
        throw ChatGptException('ChatGPT stopped before finishing the reply.');
    }
  }
  throw ChatGptException('The ChatGPT reply ended early. Try again.');
}

/// A failed plan-usage request, worded for the user. Billing errors stop the
/// request — they never fall back to another way of paying.
String chatGptErrorMessage(int? status, String? code, String? detail) {
  switch (code) {
    case 'subscription_sharing_usage_limit_exceeded':
      return 'Usage limit reached. Review your plan or this app’s limit in '
          'ChatGPT settings: $kChatGptUsageUrl';
    case 'subscription_sharing_user_not_eligible':
      return 'This ChatGPT account can’t use its plan in other apps.';
    case 'subscription_sharing_usage_unavailable' ||
          'subscription_sharing_user_unavailable':
      return 'ChatGPT plan usage is unavailable right now. Try again later.';
    case 'subscription_sharing_unsupported_capability':
      return 'ChatGPT plan usage doesn’t support part of this request'
          '${detail == null ? '' : ': $detail'}';
    case 'subscription_sharing_invalid_user':
      return 'ChatGPT didn’t accept this sign-in. If you disconnected '
          'OpenStrap in ChatGPT settings, sign in again.';
  }
  if (status == 401) {
    return 'ChatGPT didn’t accept this sign-in. Sign in again from AI settings.';
  }
  if (status == 503) {
    return 'ChatGPT plan usage is unavailable right now. Try again later.';
  }
  final what = detail ?? code ?? 'unknown error';
  return status == null ? 'ChatGPT error: $what' : 'ChatGPT error ($status): $what';
}

/// [chatGptErrorMessage] for a non-200 body, which is either a Responses
/// `{"error": {...}}` or an admission `{"detail": "..."}`.
String chatGptHttpError(int status, String body) {
  try {
    final j = jsonDecode(body);
    final e = j is Map ? j['error'] : null;
    if (e is Map) {
      return chatGptErrorMessage(
          status, e['code']?.toString(), (e['param'] ?? e['message'])?.toString());
    }
    if (j is Map && j['detail'] != null) {
      return chatGptErrorMessage(status, null, j['detail'].toString());
    }
  } catch (_) {}
  return chatGptErrorMessage(
      status, null, body.length > 200 ? body.substring(0, 200) : body);
}

/// The namespace the coach's function tools are grouped under on the
/// ChatGPT-plan route.
const kChatGptToolNamespace = 'openstrap';

/// The Responses body this route accepts, from the coach's normal one: it
/// must stream, and rejects `system` input items (developer is the same thing
/// here). Sampling params are already never sent on Responses.
///
/// Function tools are only accepted here grouped in a namespace (or through
/// `additional_tools` input items), not as bare top-level tools, so they go
/// under [kChatGptToolNamespace]. The model's calls then carry that
/// namespace beside the bare function name, and a `function_call` replayed
/// from history without one gets it too, so it matches a declared tool.
/// https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
Map<String, dynamic> chatGptRequest(Map<String, dynamic> body) {
  final tools = body['tools'];
  final functions = <Map<String, dynamic>>[];
  final others = <Object?>[];
  if (tools is List) {
    for (final t in tools) {
      if (t is Map && t['type'] == 'function') {
        functions.add(t.cast<String, dynamic>());
      } else {
        others.add(t);
      }
    }
  }
  final names = {for (final f in functions) f['name']};
  return {
    ...body,
    'stream': true,
    'store': false,
    'input': [
      for (final item in body['input'] as List)
        if (item is Map && item['role'] == 'system')
          {...item, 'role': 'developer'}
        else if (item is Map &&
            item['type'] == 'function_call' &&
            item['namespace'] == null &&
            names.contains(item['name']))
          {...item, 'namespace': kChatGptToolNamespace}
        else
          item,
    ],
    if (tools is List)
      'tools': [
        if (functions.isNotEmpty)
          {
            'type': 'namespace',
            'name': kChatGptToolNamespace,
            'description': 'Read and present this person\'s OpenStrap health data.',
            'tools': functions,
          },
        ...others,
      ],
  };
}

class ChatGptSession {
  final String sub, email, idToken, accessToken, refreshToken, scope;
  final DateTime expiresAt;

  const ChatGptSession({
    required this.sub,
    required this.email,
    required this.idToken,
    required this.accessToken,
    required this.refreshToken,
    required this.scope,
    required this.expiresAt,
  });

  /// Signed in is not enough: the user can sign in and decline plan usage.
  bool get sharing => scope.split(' ').contains(kChatGptPlanScope);

  Map<String, dynamic> toJson() => {
        'sub': sub,
        'email': email,
        'id_token': idToken,
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'scope': scope,
        'expires_at': expiresAt.millisecondsSinceEpoch,
      };

  static ChatGptSession fromJson(Map j) => ChatGptSession(
        sub: j['sub'] as String,
        email: j['email'] as String,
        idToken: j['id_token'] as String,
        accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
        scope: j['scope'] as String,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(j['expires_at'] as int),
      );
}

/// One ChatGPT account per install. The issued client id and host id are kept
/// across sign-outs — OpenAI wants a returning sign-in to reuse both.
class ChatGptAuth extends ChangeNotifier {
  ChatGptAuth({http.Client? client}) : _client = client;

  static const _kClientId = 'coach_chatgpt_client_id';
  static const _kHostId = 'coach_chatgpt_host_id';
  static const _kPresent = 'coach_chatgpt_present';
  static const _kWelcomed = 'coach_chatgpt_welcomed';
  static const _kSession = 'coach_chatgpt_session'; // secure storage

  // Same first-unlock reasoning as CoachConfig's key: background relaunches
  // happen while the phone is locked.
  static const _apple = IOSOptions(accessibility: KeychainAccessibility.first_unlock);
  static const _macos = MacOsOptions(accessibility: KeychainAccessibility.first_unlock);
  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  final http.Client? _client;

  /// OpenAI's signing keys, cached for the life of this object.
  late final ChatGptJwks _jwks = ChatGptJwks(
    issuer: kChatGptIssuer,
    get: (u) => _http((c) => c.get(u).timeout(const Duration(seconds: 20))),
  );

  ChatGptSession? _session;
  bool _unreadable = false;
  HttpServer? _pending;

  /// A code exchange that is out: completes with whether every token it was
  /// issued is either stored or confirmed revoked. [forgetAll] waits on it so
  /// a reset cannot report a clean wipe while a late exchange still holds
  /// tokens it failed to revoke.
  Future<bool>? _exchanging;
  Future<String>? _refreshing;

  /// The [_generation] [_refreshing] was started under. A session that came
  /// after it never shares it: that refresh is spending another session's
  /// token.
  int _refreshingGeneration = -1;

  /// Bumped by every [signIn] and every [cancelSignIn]. A code exchange that
  /// finishes under an older value was cancelled (or replaced) while it was
  /// out, so its tokens are revoked rather than stored.
  int _attempt = 0;

  /// Bumped whenever a sign-in commits a session, and at the very start of
  /// [signOut]/[forgetAll]. A [load], [_refresh] or [signIn] that started under
  /// an older value must not apply its result — a slow keychain read or token call
  /// would otherwise bring back a session the user just ended (same idea as
  /// CoachConfig._generation).
  int _generation = 0;

  /// Keychain writes, deletes and the marker run one at a time, like
  /// CoachConfig._serialized: a sign-out can then never interleave with a
  /// store's awaits — it runs after one already writing, and ahead of any
  /// still queued (which see the new generation and are rejected).
  Future<void> _lock = Future.value();

  Future<void> _serialized(Future<void> Function() op) {
    final done = _lock.then((_) => op());
    // A failed operation must not wedge the queue.
    _lock = done.catchError((_) {});
    return done;
  }

  ChatGptSession? get session => _session;
  bool get signedIn => _session != null;
  bool get sharing => _session?.sharing ?? false;

  /// Signed in, but the keychain could not be read (locked phone). Fixes
  /// itself on the next foreground [load].
  bool get unreadable => _unreadable;

  Future<T> _http<T>(Future<T> Function(http.Client) f) async {
    final c = _client ?? http.Client();
    try {
      return await f(c);
    } finally {
      if (_client == null) c.close();
    }
  }

  Future<void> load({bool trusted = false}) async {
    final generation = _generation;
    final prefs = await SharedPreferences.getInstance();
    final present = prefs.getBool(_kPresent) ?? false;
    try {
      final raw = await _secure.read(key: _kSession, iOptions: _apple, mOptions: _macos);
      if (generation != _generation) return;
      if (raw != null && raw.isNotEmpty && !present) {
        // Fails closed: every store writes the marker, so a record without it
        // is one a sign-out could not delete (or a reinstall's leftover).
        await _serialized(() async {
          if (generation != _generation) return; // a sign-in just committed
          try {
            await _secure.delete(key: _kSession, iOptions: _apple, mOptions: _macos);
          } catch (_) {}
        });
        if (generation != _generation) return;
        _session = null;
        _unreadable = false;
      } else if (raw != null && raw.isNotEmpty) {
        _session = ChatGptSession.fromJson(jsonDecode(raw) as Map);
        _unreadable = false;
      } else if (trusted || !present) {
        _session = null;
        _unreadable = false;
        if (present) await prefs.setBool(_kPresent, false);
      } else {
        _unreadable = true;
      }
    } catch (_) {
      if (generation != _generation) return;
      _unreadable = present && _session == null;
    }
    notifyListeners();
  }

  /// Every caller passes the [generation] it started under, checked INSIDE the
  /// lock before any write: if the session was signed out or replaced since,
  /// the result is dropped. A sign-in or [debugSetSession] passes `commit` to
  /// start a new generation once its write lands.
  Future<void> _store(ChatGptSession? s,
          {required int generation, bool commit = false, int? attempt}) =>
      _serialized(() async {
        void current() {
          if (generation != _generation) throw ChatGptException('Signed out.');
          if (attempt != null && attempt != _attempt) {
            throw ChatGptException('Sign-in was cancelled.');
          }
          // A sign-in that lands during a reset is revoked, not stored (see [signIn]).
          if (commit && ResetGate.active) throw ChatGptException('Signed out.');
        }

        current();
        final prefs = await SharedPreferences.getInstance();
        if (s == null) {
          // Best effort: the marker below is what [load] trusts, and the spent
          // session must leave memory even if the keychain item lingers.
          try {
            await _secure.delete(key: _kSession, iOptions: _apple, mOptions: _macos);
          } catch (_) {}
        } else {
          final raw = jsonEncode(s.toJson());
          try {
            await _secure.write(key: _kSession, value: raw, iOptions: _apple, mOptions: _macos);
          } on Object catch (e) {
            // Only a leftover item from a previous install (see CoachConfig.save)
            // is worth deleting; any other failure leaves the stored session alone.
            if (!isKeychainDuplicateItemError(e)) rethrow;
            await _secure.delete(key: _kSession, iOptions: _apple, mOptions: _macos);
            await _secure.write(key: _kSession, value: raw, iOptions: _apple, mOptions: _macos);
          }
        }
        await prefs.setBool(_kPresent, s != null);
        // A sign-out that began mid-write clears the keychain right after us.
        current();
        if (commit) _generation++;
        _session = s;
        _unreadable = false;
        notifyListeners();
      });

  static String _random() {
    final r = Random.secure();
    return base64Url.encode(List.generate(32, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  /// Runs the browser sign-in. [open] shows the authorize page and must keep
  /// this app alive while it is up (an in-app browser), because the redirect
  /// lands on a listener on this device's loopback.
  Future<void> signIn(Future<bool> Function(Uri) open) async {
    // A reset does not block the UI, and it clears every preference after
    // [forgetAll]: a sign-in it overlapped would be left half-stored.
    if (ResetGate.active) {
      throw ChatGptException('Wait for the reset to finish, then sign in again.');
    }
    final generation = _generation;
    final attempt = ++_attempt;
    final prefs = await SharedPreferences.getInstance();
    final hostId = prefs.getString(_kHostId) ?? 'urn:uuid:${const Uuid().v4()}';
    await prefs.setString(_kHostId, hostId);
    final savedClientId = prefs.getString(_kClientId);
    final server = _pending = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Completer<bool>? exchanged;
    try {
      // Cancelled while the listener was binding: [cancelSignIn] had no
      // server to close yet, so this attempt would open the browser anyway.
      if (attempt != _attempt) throw ChatGptException('Sign-in was cancelled.');
      final redirectUri = 'http://127.0.0.1:${server.port}/auth/callback';
      final state = _random(), nonce = _random(), verifier = _random();
      final uri = chatGptAuthorizeUri(
        clientId: savedClientId,
        hostId: hostId,
        redirectUri: redirectUri,
        state: state,
        nonce: nonce,
        codeVerifier: verifier,
        idTokenHint: _session?.idToken,
      );
      // Listening BEFORE the browser opens: the redirect can beat [open]'s
      // own return. ignore() only keeps a failed open from leaving this
      // future's error unhandled; it is still awaited below.
      final callback = _callback(server, state)..ignore();
      if (!await open(uri)) throw ChatGptException('Could not open the browser.');
      final q = await callback.timeout(
        const Duration(minutes: 10),
        onTimeout: () => throw ChatGptException('Sign-in timed out. Try again.'),
      );
      if (q['error'] != null) {
        throw ChatGptException(q['error'] == 'access_denied'
            ? 'Sign-in was cancelled.'
            : 'ChatGPT sign-in failed: ${q['error_description'] ?? q['error']}');
      }
      final issued = q['client_id'];
      if (savedClientId != null && issued != null && issued != savedClientId) {
        throw ChatGptException('ChatGPT returned a different app registration.');
      }
      final clientId = savedClientId ?? issued;
      if (clientId == null || q['code'] == null) {
        throw ChatGptException('ChatGPT sign-in returned no code.');
      }
      // Registered before the first await from here on, so a reset that
      // starts while the client id is being written still waits for this
      // exchange (and deletes the client id only after it).
      exchanged = Completer<bool>();
      _exchanging = exchanged.future;
      // Saved BEFORE the exchange, so a retry after a failed one reuses it.
      await prefs.setString(_kClientId, clientId);
      if (generation != _generation) throw ChatGptException('Signed out.');
      if (attempt != _attempt) throw ChatGptException('Sign-in was cancelled.');
      final Map<String, dynamic> t;
      try {
        t = await _token({
          'grant_type': 'authorization_code',
          'client_id': clientId,
          'code': q['code']!,
          'code_verifier': verifier,
          'redirect_uri': redirectUri,
        });
      } on _TokenError catch (e) {
        throw ChatGptException(
            'ChatGPT sign-in failed (${e.code ?? e.status}). Try again.');
      }
      // From here on tokens exist on OpenAI's side. Any way this attempt ends
      // other than a stored session — a sign-out, reset or cancel that landed
      // while the exchange was out, or a token that does not check out —
      // revokes them, with the client id captured above (a reset deletes the
      // saved one).
      try {
        if (generation != _generation) throw ChatGptException('Signed out.');
        if (attempt != _attempt) throw ChatGptException('Sign-in was cancelled.');
        final idToken = t['id_token'] as String?;
        if (idToken == null) throw ChatGptException('ChatGPT returned no identity.');
        try {
          await _jwks.verify(idToken);
        } on ChatGptSignatureException catch (e) {
          debugPrint('[chatgpt] $e');
          throw ChatGptException('ChatGPT returned a sign-in that did not check out.');
        }
        final who = chatGptIdentity(idToken, clientId: clientId, nonce: nonce);
        await _store(
          _sessionFrom(t, sub: who.sub, email: who.email, idToken: idToken),
          generation: generation,
          commit: true,
          attempt: attempt,
        );
      } catch (_) {
        exchanged.complete(await _revokeIssued(
          refreshToken: t['refresh_token'] is String ? t['refresh_token'] as String : null,
          accessToken: t['access_token'] as String, // [_token] checked it
          clientId: clientId,
        ));
        rethrow;
      }
    } finally {
      // Stored, or no tokens were issued: nothing is left behind.
      if (exchanged != null && !exchanged.isCompleted) exchanged.complete(true);
      if (exchanged != null && identical(_exchanging, exchanged.future)) _exchanging = null;
      if (identical(_pending, server)) _pending = null;
      await server.close(force: true);
    }
  }

  /// Ends a [signIn] still waiting on the browser. Nothing tells the app when
  /// the user simply closes the in-app browser, so this is the way out.
  void cancelSignIn() {
    _attempt++;
    _pending?.close(force: true);
  }

  /// The first callback carrying our [state]. Anything else that reaches the
  /// loopback port is turned away without ending the sign-in.
  static Future<Map<String, String>> _callback(HttpServer server, String state) async {
    await for (final req in server) {
      final q = req.uri.queryParameters;
      final ours = req.uri.path == '/auth/callback' && q['state'] == state;
      req.response
        ..statusCode = ours ? 200 : 400
        ..headers.contentType = ContentType.html
        ..write(ours
            ? '<!doctype html><meta name="viewport" content="width=device-width">'
                '<p style="font:16px system-ui;margin:2em">Done. You can close '
                'this page and go back to OpenStrap.</p>'
            : 'Bad request');
      await req.response.close();
      if (ours) return q;
    }
    throw ChatGptException('Sign-in was cancelled.');
  }

  ChatGptSession _sessionFrom(Map t,
          {required String sub, required String email, required String idToken}) =>
      ChatGptSession(
        sub: sub,
        email: email,
        idToken: idToken,
        accessToken: t['access_token'] as String,
        refreshToken: t['refresh_token'] as String,
        scope: (t['scope'] ?? '').toString(),
        expiresAt: clock.now().add(Duration(seconds: (t['expires_in'] as num?)?.toInt() ?? 3600)),
      );

  Future<Map<String, dynamic>> _token(Map<String, String> form) async {
    final resp = await _http((c) => c
        .post(Uri.parse(_tokenUrl), body: {...form, 'resource': kChatGptApiBase})
        .timeout(const Duration(seconds: 30)));
    Object? j;
    try {
      j = jsonDecode(resp.body);
    } catch (_) {}
    if (resp.statusCode == 200 && j is Map && j['access_token'] is String) {
      return j.cast<String, dynamic>();
    }
    final err = j is Map ? j['error']?.toString() : null;
    throw _TokenError(resp.statusCode, err);
  }

  /// A current access token, refreshed when it is within five minutes of
  /// expiry. Concurrent callers share one refresh — the refresh token rotates,
  /// and a second refresh with the old one would be `refresh_token_reused`.
  Future<String> accessToken() {
    final s = _session;
    if (s == null) {
      return Future.error(ChatGptException(_unreadable
          ? 'Your ChatGPT sign-in could not be read while the phone was locked. Open the app and try again.'
          : 'Sign in with ChatGPT first.'));
    }
    if (s.expiresAt.isAfter(clock.now().add(const Duration(minutes: 5)))) {
      return Future.value(s.accessToken);
    }
    final pending = _refreshing;
    if (pending != null && _refreshingGeneration == _generation) return pending;
    _refreshingGeneration = _generation;
    late final Future<String> f;
    f = _refresh(s).whenComplete(() {
      if (identical(_refreshing, f)) _refreshing = null;
    });
    return _refreshing = f;
  }

  Future<String> _refresh(ChatGptSession s) async {
    final generation = _generation;
    final prefs = await SharedPreferences.getInstance();
    final clientId = prefs.getString(_kClientId);
    if (clientId == null) throw ChatGptException('Sign in with ChatGPT again.');
    final Map<String, dynamic> t;
    try {
      t = await _token({
        'grant_type': 'refresh_token',
        'client_id': clientId,
        'refresh_token': s.refreshToken,
      });
    } on _TokenError catch (e) {
      if (!e.terminal) {
        throw ChatGptException('Could not renew the ChatGPT sign-in (${e.status}). Try again.');
      }
      // Best effort: a failed clear (or a sign-out that got there first) must
      // not replace the message saying why the coach stopped.
      try {
        await _store(null, generation: generation);
      } catch (_) {}
      throw ChatGptException('Your ChatGPT sign-in has ended. Sign in again from AI settings.');
    } catch (e) {
      // A network hiccup is not a revoked session — the tokens stay.
      throw ChatGptException('Could not reach ChatGPT to renew the sign-in: $e');
    }
    final next = _sessionFrom(
      {'refresh_token': s.refreshToken, 'scope': s.scope, ...t},
      sub: s.sub,
      email: s.email,
      idToken: (t['id_token'] as String?) ?? s.idToken,
    );
    if (generation != _generation) {
      // Signed out (or replaced) while the call was out: the rotated tokens
      // belong to a session that has ended, so they are revoked here rather
      // than handed on — a later sign-out is about a later session.
      throw _StaleRefresh(await _revokeIssued(
          refreshToken: next.refreshToken, accessToken: next.accessToken, clientId: clientId));
    }
    try {
      await _store(next, generation: generation);
    } catch (_) {
      if (generation != _generation) {
        // Signed out while it was writing: same as above.
        throw _StaleRefresh(await _revokeIssued(
            refreshToken: next.refreshToken, accessToken: next.accessToken, clientId: clientId));
      }
      // The keychain write failed, but the old refresh token is already spent:
      // keep the rotated session in memory so the next refresh does not reuse it.
      _session = next;
    }
    return next.accessToken;
  }

  /// Revokes the refresh and access tokens and forgets the session. Returns false when
  /// revocation could not be confirmed; the tokens are cleared regardless, and
  /// the user can still disconnect the app in ChatGPT settings.
  Future<bool> signOut() async {
    final generation = ++_generation; // before any await: see [_generation]
    cancelSignIn();
    final s = _session;
    final refreshing = _refreshing;
    // Memory first, so nothing keeps using the session while revocation is out.
    _session = null;
    _unreadable = false;
    notifyListeners();
    // An in-flight refresh revokes what it rotated to itself; the token it
    // spent is then dead and there is nothing left to revoke here.
    final rotated = await _rotationOf(refreshing);
    final prefs = await SharedPreferences.getInstance();
    final clientId = prefs.getString(_kClientId);
    final token = s?.refreshToken;
    final revoked = rotated ??
        (s == null ||
            (clientId != null &&
                await _revokeIssued(
                    refreshToken: token, accessToken: s.accessToken, clientId: clientId)));
    // Signed out either way. If the delete fails the item may linger, but the
    // marker is cleared and [load] fails closed on a record without it, so it
    // is never restored (it is deleted then); the credential is not guaranteed
    // gone until that happens.
    await _serialized(() async {
      // The button to sign in again is back while revocation is out: a sign-in
      // that committed since (or a later sign-out) owns the keychain now.
      if (generation != _generation) return;
      try {
        await _secure.delete(key: _kSession, iOptions: _apple, mOptions: _macos);
      } catch (_) {}
      await prefs.setBool(_kPresent, false);
    });
    return revoked;
  }

  /// Waits out a refresh that was in flight when the session ended. Non-null
  /// when it had rotated the tokens (and so revoked them itself): whether that
  /// revocation was confirmed.
  static Future<bool?> _rotationOf(Future<String>? refreshing) async {
    if (refreshing == null) return null;
    try {
      await refreshing;
    } on _StaleRefresh catch (e) {
      return e.revoked;
    } catch (_) {}
    return null;
  }

  /// True when OpenAI confirmed [token] is revoked.
  Future<bool> _revoke(String token, String clientId,
      {String hint = 'refresh_token'}) async {
    try {
      final r = await _http((c) => c.post(Uri.parse(_revokeUrl), body: {
            'token': token,
            'token_type_hint': hint,
            'client_id': clientId,
          }).timeout(const Duration(seconds: 15)));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Revokes tokens this app holds but will not keep: the refresh token, which
  /// is what keeps the grant alive, and the access token so it does not stay
  /// usable for the rest of its hour. True only when both were confirmed.
  Future<bool> _revokeIssued(
      {required String? refreshToken,
      required String? accessToken,
      required String clientId}) async {
    // Both at once, so a dead network costs one request timeout, not two:
    // sign-out and "Reset all data" wait on this before clearing local state.
    final results = await Future.wait([
      if (refreshToken != null) _revoke(refreshToken, clientId),
      if (accessToken != null) _revoke(accessToken, clientId, hint: 'access_token'),
    ]);
    return results.every((ok) => ok);
  }

  /// "Reset all data": the session plus the registration and welcome flag.
  /// The session is revoked first, best effort, while the registration to
  /// revoke it with is still here.
  /// Returns false when a session may outlive the reset: revocation was not
  /// confirmed, or the keychain item could not be deleted.
  Future<bool> forgetAll() async {
    _generation++;
    cancelSignIn();
    final exchanging = _exchanging;
    var s = _session;
    final refreshing = _refreshing;
    _session = null;
    _unreadable = false;
    // As in [signOut]: an in-flight refresh revokes its own rotated tokens.
    final rotated = await _rotationOf(refreshing);
    final prefs = await SharedPreferences.getInstance();
    final clientId = prefs.getString(_kClientId);
    // [load] runs in the background at startup, so nothing in memory need not
    // mean nothing stored: read the keychain before deleting it, and do not
    // call a session revoked when it could not be read.
    var unreadable = false;
    if (s == null && rotated == null) {
      try {
        final raw = await _secure.read(key: _kSession, iOptions: _apple, mOptions: _macos);
        if (raw != null && raw.isNotEmpty) {
          s = ChatGptSession.fromJson(jsonDecode(raw) as Map);
        }
      } catch (_) {
        unreadable = prefs.getBool(_kPresent) ?? false;
      }
    }
    final token = s?.refreshToken;
    final revoked = !unreadable &&
        (rotated ??
            (s == null ||
                (clientId != null &&
                    await _revokeIssued(
                        refreshToken: token, accessToken: s.accessToken, clientId: clientId))));
    // A sign-in whose code exchange was out revokes what it was issued itself.
    final exchangeClean = exchanging == null || await exchanging;
    var deleted = true;
    await _serialized(() async {
      try {
        await _secure.delete(key: _kSession, iOptions: _apple, mOptions: _macos);
      } catch (_) {
        deleted = false;
      }
      final prefs = await SharedPreferences.getInstance();
      for (final k in [_kClientId, _kHostId, _kPresent, _kWelcomed]) {
        await prefs.remove(k);
      }
    });
    notifyListeners();
    return revoked && exchangeClean && deleted;
  }

  /// True exactly once, on the first sign-in that has plan usage.
  Future<bool> takeWelcome() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kWelcomed) ?? false) return false;
    await prefs.setBool(_kWelcomed, true);
    return true;
  }

  /// Model slugs this account may use, in the server's order.
  Future<List<String>> listModels() async {
    final token = await accessToken();
    final resp = await _http((c) => c.get(
          Uri.parse('$kChatGptApiBase/models'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 20)));
    if (resp.statusCode != 200) {
      throw ChatGptException(chatGptHttpError(resp.statusCode, resp.body));
    }
    final j = jsonDecode(resp.body);
    final models = j is Map ? j['models'] : null;
    return [
      if (models is List)
        for (final m in models)
          if (m is Map && m['visibility'] == 'list' && m['slug'] is String)
            m['slug'] as String,
    ];
  }

  @visibleForTesting
  Future<void> debugSetSession(ChatGptSession? s) =>
      _store(s, generation: _generation, commit: true);
}

/// A refresh that came back after its session ended. Its rotated tokens were
/// revoked on the spot; [revoked] says whether OpenAI confirmed it.
class _StaleRefresh extends ChatGptException {
  final bool revoked;
  _StaleRefresh(this.revoked) : super('Signed out.');
}

class _TokenError implements Exception {
  final int status;
  final String? code;
  _TokenError(this.status, this.code);

  /// The refresh token itself is dead, as opposed to a transient failure.
  bool get terminal =>
      const {
        'invalid_grant',
        'invalid_refresh_token',
        'token_expired',
        'refresh_token_expired',
        'refresh_token_invalidated',
        'refresh_token_reused',
      }.contains(code);
}
