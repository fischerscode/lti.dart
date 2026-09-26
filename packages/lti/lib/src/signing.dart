import 'dart:convert';
import 'dart:math';

import 'package:jose/jose.dart';

import 'models.dart';

/// Public RSA verification material. Private/unknown JWK fields are never stored
/// or returned. This final type is the boundary used by the public JWKS route.
final class LtiPublicKey {
  LtiPublicKey._(this.keyId, this._modulus, this._exponent);

  factory LtiPublicKey.fromJwk(Map<String, Object?> jwk) {
    try {
      if (jwk['kty'] != 'RSA' ||
          (jwk['alg'] != null && jwk['alg'] != 'RS256') ||
          (jwk['use'] != null && jwk['use'] != 'sig')) {
        throw const FormatException();
      }
      final kid = requiredString(jwk, 'kid');
      final n = _integer(requiredString(jwk, 'n'));
      final e = _integer(requiredString(jwk, 'e'));
      if (n.bitLength < 2048 ||
          n.isEven ||
          e < BigInt.from(3) ||
          e.isEven ||
          e >= n) {
        throw const FormatException();
      }
      return LtiPublicKey._(
        kid,
        _canonical(requiredString(jwk, 'n')),
        _canonical(requiredString(jwk, 'e')),
      );
    } catch (_) {
      throw ArgumentError(
        'Expected an RS256 public key with kid and at least 2048 RSA bits.',
      );
    }
  }

  final String keyId;
  final String _modulus;
  final String _exponent;

  Map<String, Object?> toJwk() => Map.unmodifiable({
    'kty': 'RSA',
    'kid': keyId,
    'alg': 'RS256',
    'use': 'sig',
    'key_ops': ['verify'],
    'n': _modulus,
    'e': _exponent,
  });

  bool _sameMaterial(LtiPublicKey other) =>
      _modulus == other._modulus && _exponent == other._exponent;

  static String _canonical(String encoded) => base64Url
      .encode(base64Url.decode(base64Url.normalize(encoded)))
      .replaceAll('=', '');

  static BigInt _integer(String encoded) {
    final bytes = base64Url.decode(base64Url.normalize(encoded));
    if (bytes.isEmpty || bytes.first == 0) throw const FormatException();
    return bytes.fold(
      BigInt.zero,
      (value, byte) => (value << 8) | BigInt.from(byte),
    );
  }
}

/// Trusted signing integration for local keys, HSMs or external signing services.
/// [sign] must produce RSASSA-PKCS1-v1_5 with SHA-256 (RS256), not RSA-PSS.
abstract interface class LtiSigningKey {
  LtiPublicKey get publicKey;
  Future<List<int>> sign(List<int> signingInput);
}

/// Local private-key implementation backed by JOSE. Does not generate keys or
/// persist them. Load stable private material from your application's secret store.
final class RsaLtiSigningKey implements LtiSigningKey {
  RsaLtiSigningKey._(this._key, this.publicKey);

  factory RsaLtiSigningKey.fromJwk(Map<String, Object?> jwk) {
    try {
      final public = LtiPublicKey.fromJwk(jwk);
      requiredString(jwk, 'd');
      if (jwk.containsKey('key_ops') &&
          !stringList(jwk['key_ops']).contains('sign')) {
        throw const FormatException();
      }
      // Import only relevant RSA fields, with no external certificate/URL data.
      final key = JsonWebKey.fromJson({
        'kty': 'RSA',
        'kid': public.keyId,
        'alg': 'RS256',
        'use': 'sig',
        for (final name in ['n', 'e', 'd', 'p', 'q', 'dp', 'dq', 'qi'])
          if (jwk.containsKey(name)) name: requiredString(jwk, name),
      });
      final probe = utf8.encode('LTI RSA key consistency check');
      if (!JsonWebKey.fromJson(public.toJwk()).verify(
        probe,
        key.sign(probe, algorithm: 'RS256'),
        algorithm: 'RS256',
      )) {
        throw const FormatException();
      }
      return RsaLtiSigningKey._(key, public);
    } catch (_) {
      // Configuration errors must not include any part of the private key.
      throw ArgumentError('Invalid RS256 private signing key.');
    }
  }

  factory RsaLtiSigningKey.fromPem(String pem, {required String keyId}) {
    try {
      return RsaLtiSigningKey.fromJwk(
        JsonWebKey.fromPem(pem, keyId: keyId).toJson(),
      );
    } catch (_) {
      throw ArgumentError('Invalid RSA private PEM signing key.');
    }
  }

  final JsonWebKey _key;
  @override
  final LtiPublicKey publicKey;

  @override
  Future<List<int>> sign(List<int> signingInput) async =>
      _key.sign(signingInput, algorithm: 'RS256');
}

/// A provider must publish the public key before signing with it and retain
/// retired verification keys for the required token lifetime/cache overlap.
/// Implementations may choose a signing key separately for each registration.
abstract interface class LtiSigningKeyProvider {
  Future<LtiSigningKey> signingKeyFor(LtiRegistration registration);
  Future<List<LtiPublicKey>> publicKeys();
}

/// One active tool-wide key and an explicitly managed set of public keys.
/// For multiple server instances, coordinate/persist the same key lifecycle
/// externally. This implementation retains kid history only for its lifetime.
final class MemoryLtiSigningKeyProvider implements LtiSigningKeyProvider {
  MemoryLtiSigningKeyProvider(LtiSigningKey activeKey) : _active = activeKey {
    publish(activeKey.publicKey);
  }

  LtiSigningKey _active;
  final _published = <String, LtiPublicKey>{};
  final _history = <String, LtiPublicKey>{};

  /// Stage the new public key before activation so platforms can refresh caches.
  void publish(LtiPublicKey key) {
    final previous = _history[key.keyId];
    if (previous != null && !previous._sameMaterial(key)) {
      throw ArgumentError(
        'A key ID must never identify different RSA material.',
      );
    }
    _history[key.keyId] = key;
    _published[key.keyId] = key;
  }

  /// Switch signing only after the public key has been published and propagated.
  /// The old public key remains available; the provider drops its private key.
  void activate(LtiSigningKey key) {
    final published = _published[key.publicKey.keyId];
    if (published == null || !published._sameMaterial(key.publicKey)) {
      throw StateError('Publish this public key before activating it.');
    }
    _active = key;
  }

  /// Remove an old public key after all tokens, in-flight signing operations and
  /// platform caches no longer need it. Cannot remove the active signing key.
  void retire(String keyId) {
    if (keyId == _active.publicKey.keyId) {
      throw StateError('Cannot retire the active signing key.');
    }
    if (_published.remove(keyId) == null) {
      throw ArgumentError('Unknown public key ID.');
    }
  }

  @override
  Future<LtiSigningKey> signingKeyFor(LtiRegistration registration) async =>
      _active;

  @override
  Future<List<LtiPublicKey>> publicKeys() async =>
      List.unmodifiable(_published.values);
}

/// Creates bounded-lifetime tool JWT envelopes and OAuth client assertions.
/// Message-specific payload rules (e.g. Deep Linking) are the caller's job until
/// the corresponding typed message builder is implemented.
final class LtiJwtSigner {
  LtiJwtSigner({
    required this.keys,
    DateTime Function()? clock,
    this.lifetime = const Duration(minutes: 5),
  }) : _clock = clock ?? DateTime.now {
    if (lifetime.inSeconds < 1 || lifetime > const Duration(minutes: 5)) {
      throw ArgumentError(
        'JWT lifetime must be between one second and five minutes.',
      );
    }
  }
  final LtiSigningKeyProvider keys;
  final DateTime Function() _clock;
  final Duration lifetime;
  final _random = Random.secure();

  String _identifier() => base64Url
      .encode(List.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  /// Signs the security envelope; this does not validate a message-specific schema.
  Future<String> signMessage({
    required LtiRegistration registration,
    required String deploymentId,
    required String messageType,
    Map<String, Object?> claims = const {},
  }) async {
    _checkDeployment(registration, deploymentId);
    if (messageType.isEmpty || claims.keys.any(_reserved.contains)) {
      throw ArgumentError(
        'Message type is required and reserved claims cannot be overridden.',
      );
    }
    final issued = _clock().millisecondsSinceEpoch ~/ 1000;
    return _sign(registration, {
      ...claims,
      'iss': registration.clientId,
      'aud': registration.issuer,
      'iat': issued,
      'exp': issued + lifetime.inSeconds,
      'nonce': _identifier(),
      LtiClaims.version: '1.3.0',
      LtiClaims.messageType: messageType,
      LtiClaims.deploymentId: deploymentId,
    });
  }

  /// Prepares authentication for a token request; does not request an access token.
  Future<String> createClientAssertion({
    required LtiRegistration registration,
    String? deploymentId,
  }) async {
    if (deploymentId != null) _checkDeployment(registration, deploymentId);
    final audience =
        registration.authorizationServerAudience ??
        registration.tokenEndpoint?.toString();
    if (audience == null) {
      throw StateError(
        'Configure the token endpoint or authorization server audience.',
      );
    }
    final issued = _clock().millisecondsSinceEpoch ~/ 1000;
    return _sign(registration, {
      'iss': registration.clientId,
      'sub': registration.clientId,
      'aud': audience,
      'iat': issued,
      'exp': issued + lifetime.inSeconds,
      'jti': _identifier(),
      LtiClaims.deploymentId: ?deploymentId,
    });
  }

  Future<Map<String, Object?>> publicJwks() async {
    final published = await keys.publicKeys();
    if (published.map((key) => key.keyId).toSet().length != published.length) {
      throw StateError('The signing provider published duplicate key IDs.');
    }
    return {
      'keys': published.map((key) => key.toJwk()).toList(growable: false),
    };
  }

  Future<String> _sign(
    LtiRegistration registration,
    Map<String, Object?> claims,
  ) async {
    // Snapshot before any asynchronous provider call; callers cannot mutate a
    // nested payload while key selection/signing is in progress.
    final payload = _encode(jsonEncode(claims));
    final key = await keys.signingKeyFor(registration);
    final public = key.publicKey;
    final header = _encode(
      jsonEncode({'alg': 'RS256', 'typ': 'JWT', 'kid': public.keyId}),
    );
    final input = utf8.encode('$header.$payload');
    final signature = await key.sign(List.unmodifiable(input));
    if (!JsonWebKey.fromJson(public.toJwk())
        .verify(input, signature, algorithm: 'RS256')) {
      throw StateError('Signing provider returned an invalid RS256 signature.');
    }
    if (_clock().millisecondsSinceEpoch / 1000 >= (claims['exp']! as int)) {
      throw StateError(
        'JWT expired while the signing provider was processing it.',
      );
    }
    return '$header.$payload.${base64Url.encode(signature).replaceAll('=', '')}';
  }

  static String _encode(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  static void _checkDeployment(
    LtiRegistration registration,
    String deploymentId,
  ) {
    if (!registration.deploymentIds.contains(deploymentId)) {
      throw ArgumentError('Unregistered deployment.');
    }
  }

  static const _reserved = {
    'iss',
    'aud',
    'sub',
    'iat',
    'exp',
    'nbf',
    'nonce',
    'azp',
    'jti',
    LtiClaims.version,
    LtiClaims.messageType,
    LtiClaims.deploymentId,
  };
}
