// Signature check for the ChatGPT ID token: RS256 against the keys OpenAI
// publishes at the discovery document's `jwks_uri`. Everything here fails
// closed — a token is trusted only when its header, key and signature all
// check out, and any fetch or parse problem is a failed sign-in, never a skip.

import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

/// Raised for any ID token whose signature could not be verified.
class ChatGptSignatureException implements Exception {
  final String reason;
  ChatGptSignatureException(this.reason);
  @override
  String toString() => 'ID token signature not verified: $reason';
}

/// One RSA signing key from a JWKS.
class ChatGptJwk {
  final String kid;
  final RSAPublicKey key;
  const ChatGptJwk(this.kid, this.key);
}

BigInt _uint(String b64) {
  final bytes = base64Url.decode(base64Url.normalize(b64));
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

/// The usable RS256 signing keys in a JWKS document. Keys for another
/// algorithm, for encryption, or shorter than 2048 bits are left out.
Map<String, ChatGptJwk> parseChatGptJwks(String body) {
  final Object? j;
  try {
    j = jsonDecode(body);
  } catch (_) {
    throw ChatGptSignatureException('unreadable key set');
  }
  final keys = j is Map ? j['keys'] : null;
  if (keys is! List) throw ChatGptSignatureException('unreadable key set');
  final out = <String, ChatGptJwk>{};
  for (final k in keys) {
    if (k is! Map) continue;
    final kid = k['kid'], n = k['n'], e = k['e'];
    if (k['kty'] != 'RSA' || kid is! String || n is! String || e is! String) continue;
    if (k['alg'] != null && k['alg'] != 'RS256') continue;
    if (k['use'] != null && k['use'] != 'sig') continue;
    try {
      final modulus = _uint(n);
      if (modulus.bitLength < 2048) continue;
      out[kid] = ChatGptJwk(kid, RSAPublicKey(modulus, _uint(e)));
    } catch (_) {
      continue;
    }
  }
  return out;
}

/// The `kid` of an RS256 JWT, after checking the header asks for exactly
/// that algorithm (no `none`, no HMAC, no key embedded in the token).
String chatGptIdTokenKid(String jwt) {
  final parts = jwt.split('.');
  if (parts.length != 3) throw ChatGptSignatureException('not a signed JWT');
  final Object? header;
  try {
    header = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))));
  } catch (_) {
    throw ChatGptSignatureException('unreadable header');
  }
  if (header is! Map) throw ChatGptSignatureException('unreadable header');
  if (header['alg'] != 'RS256') {
    throw ChatGptSignatureException('unexpected alg ${header['alg']}');
  }
  if (header.containsKey('jwk') || header.containsKey('jku') || header.containsKey('x5u')) {
    throw ChatGptSignatureException('token names its own key');
  }
  if (header['crit'] != null) throw ChatGptSignatureException('unsupported crit header');
  final kid = header['kid'];
  if (kid is! String || kid.isEmpty) throw ChatGptSignatureException('no kid');
  return kid;
}

/// True when [jwt]'s RS256 signature verifies under [key].
bool chatGptVerifyRs256(String jwt, RSAPublicKey key) {
  final parts = jwt.split('.');
  if (parts.length != 3) return false;
  final Uint8List sig;
  try {
    sig = Uint8List.fromList(base64Url.decode(base64Url.normalize(parts[2])));
  } catch (_) {
    return false;
  }
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(false, PublicKeyParameter<RSAPublicKey>(key));
  try {
    return signer.verifySignature(
      Uint8List.fromList(ascii.encode('${parts[0]}.${parts[1]}')),
      RSASignature(sig),
    );
  } catch (_) {
    return false;
  }
}

/// OpenAI's published signing keys, fetched from the discovery document's
/// `jwks_uri` and cached for the life of the object. A token signed with a
/// `kid` not in the cache triggers one refetch (key rotation); a `kid` still
/// missing after that is rejected.
class ChatGptJwks {
  ChatGptJwks({required this.issuer, required this.get});

  final String issuer;

  /// Runs one request with the caller's client.
  final Future<http.Response> Function(Uri) get;

  Map<String, ChatGptJwk>? _keys;
  DateTime? _fetchedAt;

  /// Refetching on every unknown kid would let a stream of forged tokens turn
  /// into a stream of requests; one sign-in only ever needs one refetch.
  static const _minRefetch = Duration(seconds: 30);

  Future<Map<String, ChatGptJwk>> _fetch() async {
    final discovery = await get(Uri.parse('$issuer/.well-known/openid-configuration'));
    if (discovery.statusCode != 200) {
      throw ChatGptSignatureException('discovery returned ${discovery.statusCode}');
    }
    final Object? d;
    try {
      d = jsonDecode(discovery.body);
    } catch (_) {
      throw ChatGptSignatureException('unreadable discovery document');
    }
    if (d is! Map || d['issuer'] != issuer || d['jwks_uri'] is! String) {
      throw ChatGptSignatureException('unexpected discovery document');
    }
    final jwksUri = Uri.tryParse(d['jwks_uri'] as String);
    if (jwksUri == null || jwksUri.scheme != 'https' || jwksUri.host.isEmpty) {
      throw ChatGptSignatureException('jwks_uri is not https');
    }
    final r = await get(jwksUri);
    if (r.statusCode != 200) throw ChatGptSignatureException('jwks returned ${r.statusCode}');
    final keys = parseChatGptJwks(r.body);
    _keys = keys;
    _fetchedAt = clock.now();
    return keys;
  }

  /// Throws [ChatGptSignatureException] unless [jwt] is RS256-signed by one of
  /// the issuer's current keys.
  Future<void> verify(String jwt) async {
    final kid = chatGptIdTokenKid(jwt);
    var keys = _keys;
    if (keys == null || !keys.containsKey(kid)) {
      final last = _fetchedAt;
      if (keys == null || last == null || clock.now().difference(last) >= _minRefetch) {
        try {
          keys = await _fetch();
        } on ChatGptSignatureException {
          rethrow;
        } catch (e) {
          throw ChatGptSignatureException('could not fetch keys: $e');
        }
      }
    }
    final jwk = keys[kid];
    if (jwk == null) throw ChatGptSignatureException('unknown kid');
    if (!chatGptVerifyRs256(jwt, jwk.key)) throw ChatGptSignatureException('bad signature');
  }
}
