import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';

import 'errors.dart';
import 'models.dart';

/// Trusted extension point. Implementations MUST verify the signature against
/// administrator-provisioned keys, never keys or URLs supplied in the token.
abstract interface class LtiTokenVerifier {
  /// Verifies the signature of [token] using the trusted [registration].
  ///
  /// Return decoded claims only after successful cryptographic verification.
  /// Issuer, audience, timestamps, nonce and LTI claims are validated separately
  /// by the tool. Report failures using [LtiException] without token contents.
  Future<Map<String, Object?>> verify(
    String token,
    LtiRegistration registration,
  );
}

/// RS256 verifier with a bounded, expiring cache of platform public keys.
/// The caller owns the supplied HTTP client and must close it at shutdown.
final class RemoteJwksVerifier implements LtiTokenVerifier {
  /// Creates an RS256 verifier using the caller-owned HTTP client.
  ///
  /// [clock] defaults to the current time. All limits must be positive or this
  /// throws [ArgumentError]. Requests go only to the configured JWKS endpoint
  /// and never follow redirects. Callers must close the supplied client.
  RemoteJwksVerifier({
    required this._client,
    DateTime Function()? clock,
    this.cacheLifetime = const Duration(minutes: 15),
    this.refreshInterval = const Duration(seconds: 30),
    this.timeout = const Duration(seconds: 10),
    this.maxCachedEndpoints = 100,
  }) : _clock = clock ?? DateTime.now {
    if (cacheLifetime <= Duration.zero ||
        refreshInterval <= Duration.zero ||
        timeout <= Duration.zero ||
        maxCachedEndpoints <= 0) {
      throw ArgumentError('Cache limits and timeouts must be positive.');
    }
  }

  final http.Client _client;
  final DateTime Function() _clock;

  /// Maximum cache age before platform keys are fetched again; default 15 minutes.
  final Duration cacheLifetime;

  /// Minimum cache age before an unknown key ID triggers refresh; default 30 seconds.
  final Duration refreshInterval;

  /// Deadline for loading a platform key set; default 10 seconds.
  final Duration timeout;

  /// Maximum JWKS endpoints retained in memory; default 100.
  final int maxCachedEndpoints;
  final _cache = <Uri, _KeySet>{};
  final _pending = <Uri, Future<_KeySet>>{};

  @override
  Future<Map<String, Object?>> verify(
    String token,
    LtiRegistration registration,
  ) async {
    try {
      if (token.length > 65536) throw const FormatException();
      final parts = token.split('.');
      if (parts.length != 3 || parts.any((p) => p.isEmpty)) {
        throw const FormatException();
      }
      final header = jsonObject(
        jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))),
        ),
      );
      if (header['alg'] != 'RS256' ||
          header.containsKey('crit') ||
          header.containsKey('b64')) {
        throw const FormatException();
      }
      final kid = requiredString(header, 'kid');
      var set = await _keys(registration.jwksUri);
      var key = set.keys[kid];
      // Refresh once for an unknown kid, with a cooldown against random-kid floods.
      if (key == null &&
          _clock().difference(set.fetchedAt) >= refreshInterval) {
        set = await _fetch(registration.jwksUri);
        key = set.keys[kid];
      }
      if (key == null) throw const FormatException();
      final jws = JsonWebSignature.fromCompactSerialization(token);
      final payload = await jws.getPayload(
        JsonWebKeyStore()..addKey(key),
        allowedAlgorithms: const ['RS256'],
      );
      return jsonObject(jsonDecode(payload.stringContent));
    } on LtiException catch (error) {
      if (error.code == LtiErrorCode.platformUnavailable) rethrow;
      throw const LtiException(
        LtiErrorCode.invalidToken,
        'Invalid platform token.',
      );
    } on Exception {
      throw const LtiException(
        LtiErrorCode.invalidToken,
        'Invalid platform token.',
      );
    }
  }

  Future<_KeySet> _keys(Uri uri) async {
    final entry = _cache[uri];
    if (entry != null && _clock().difference(entry.fetchedAt) < cacheLifetime) {
      return entry;
    }
    return _fetch(uri);
  }

  Future<_KeySet> _fetch(Uri uri) async {
    final pending = _pending[uri];
    if (pending != null) return pending;
    final future = _download(uri);
    _pending[uri] = future;
    try {
      final result = await future;
      _cache.remove(uri);
      if (_cache.length >= maxCachedEndpoints) _cache.remove(_cache.keys.first);
      _cache[uri] = result;
      return result;
    } finally {
      _pending.remove(uri);
    }
  }

  Future<_KeySet> _download(Uri uri) async {
    try {
      return await (() async {
        final request = http.Request('GET', uri)..followRedirects = false;
        request.headers['accept'] = 'application/json';
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          await response.stream.listen(null).cancel();
          throw const FormatException();
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          bytes.addAll(chunk);
          if (bytes.length > 1048576) throw const FormatException();
        }
        final document = jsonObject(jsonDecode(utf8.decode(bytes)));
        final entries = document['keys'];
        if (entries is! List || entries.length > 100) {
          throw const FormatException();
        }
        final keys = <String, JsonWebKey>{};
        for (final entry in entries) {
          final json = jsonObject(entry);
          if (json['kty'] != 'RSA' ||
              (json['use'] != null && json['use'] != 'sig') ||
              (json['alg'] != null && json['alg'] != 'RS256')) {
            continue;
          }
          if (json['key_ops'] != null &&
              !stringList(json['key_ops']).contains('verify')) {
            continue;
          }
          final kid = requiredString(json, 'kid');
          final n = requiredString(json, 'n');
          final modulus = base64Url.decode(base64Url.normalize(n));
          // Enforce at least 2048 significant bits; ignore unsuitable keys.
          if (modulus.isEmpty ||
              modulus.first == 0 ||
              (modulus.length - 1) * 8 + modulus.first.bitLength < 2048) {
            continue;
          }
          if (keys.containsKey(kid)) throw const FormatException();
          // Only import public RSA material; ignore embedded URLs/certificates.
          keys[kid] = JsonWebKey.fromJson({
            'kty': 'RSA',
            'kid': kid,
            'alg': 'RS256',
            'use': 'sig',
            'n': n,
            'e': requiredString(json, 'e'),
          });
        }
        return _KeySet(keys, _clock());
      })().timeout(timeout);
    } on Exception {
      throw const LtiException(
        LtiErrorCode.platformUnavailable,
        'Platform keys could not be loaded.',
      );
    }
  }
}

final class _KeySet {
  const _KeySet(this.keys, this.fetchedAt);
  final Map<String, JsonWebKey> keys;
  final DateTime fetchedAt;
}
