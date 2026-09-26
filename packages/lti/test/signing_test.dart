import 'dart:async';
import 'dart:convert';

import 'package:asn1lib/asn1lib.dart';
import 'package:jose/jose.dart';
import 'package:lti/lti.dart';
import 'package:test/test.dart';

import 'support/platform.dart';

void main() {
  late RsaLtiSigningKey first;
  late RsaLtiSigningKey second;
  late MemoryLtiSigningKeyProvider keys;
  late LtiJwtSigner signer;
  late DateTime now;
  setUp(() {
    now = DateTime.utc(2026, 9, 26, 12);
    first = RsaLtiSigningKey.fromJwk(TestPlatform.key.toJson());
    second = RsaLtiSigningKey.fromJwk(TestPlatform.otherKey.toJson());
    keys = MemoryLtiSigningKeyProvider(first);
    signer = LtiJwtSigner(keys: keys, clock: () => now);
  });

  Future<Map<String, Object?>> verify(String token) async {
    final store = JsonWebKeyStore();
    for (final key in await keys.publicKeys()) {
      store.addKey(JsonWebKey.fromJson(key.toJwk()));
    }
    final payload = await JsonWebSignature.fromCompactSerialization(token)
        .getPayload(store, allowedAlgorithms: ['RS256']);
    return jsonDecode(payload.stringContent) as Map<String, Object?>;
  }

  Future<String> message({Map<String, Object?> claims = const {}}) =>
      signer.signMessage(
        registration: registration(),
        deploymentId: 'deployment',
        messageType: 'LtiDeepLinkingResponse',
        claims: claims,
      );

  test(
    'tool message has a verifiable RS256 envelope and unique nonce',
    () async {
      final token = await message(
        claims: {
          'https://example.test/content': ['resource'],
        },
      );
      final claims = await verify(token);
      expect(claims['iss'], 'client');
      expect(claims['aud'], 'https://platform.example');
      expect(claims['iat'], now.millisecondsSinceEpoch ~/ 1000);
      expect(
        claims['exp'],
        now.add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
      );
      expect(claims[LtiClaims.version], '1.3.0');
      expect(claims[LtiClaims.messageType], 'LtiDeepLinkingResponse');
      expect(claims[LtiClaims.deploymentId], 'deployment');
      expect(claims['https://example.test/content'], ['resource']);
      expect(claims['nonce'], isNot((await verify(await message()))['nonce']));
      final header = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(token.split('.').first)),
        ),
      );
      expect(header, {
        'alg': 'RS256',
        'typ': 'JWT',
        'kid': first.publicKey.keyId,
      });
    },
  );

  test(
    'OAuth assertions use client identity, configured audience and unique jti',
    () async {
      final token = await signer.createClientAssertion(
        registration: registration(),
        deploymentId: 'deployment',
      );
      final claims = await verify(token);
      expect(claims['iss'], 'client');
      expect(claims['sub'], 'client');
      expect(claims['aud'], 'https://platform.example/token');
      expect(claims[LtiClaims.deploymentId], 'deployment');
      expect(claims, isNot(contains('nonce')));
      expect(claims, isNot(contains(LtiClaims.messageType)));
      final other = await verify(
        await signer.createClientAssertion(
          registration: registration(audience: 'https://authorization.example'),
        ),
      );
      expect(other['aud'], 'https://authorization.example');
      expect(other, isNot(contains(LtiClaims.deploymentId)));
      expect(other['jti'], isNot(claims['jti']));
    },
  );

  test('requires a known assertion audience and valid lifetime', () async {
    await expectLater(
      signer.createClientAssertion(
        registration: registration(withEndpoint: false),
      ),
      throwsStateError,
    );
    for (final duration in [
      Duration.zero,
      const Duration(milliseconds: 500),
      const Duration(minutes: 6),
    ]) {
      expect(
        () => LtiJwtSigner(keys: keys, lifetime: duration),
        throwsArgumentError,
      );
    }
  });

  test(
    'prevents overrides of security claims and unknown deployments',
    () async {
      for (final name in [
        'iss',
        'aud',
        'sub',
        'iat',
        'exp',
        'nonce',
        'azp',
        'jti',
        LtiClaims.version,
        LtiClaims.deploymentId,
        LtiClaims.messageType,
      ]) {
        await expectLater(
          message(claims: {name: 'override'}),
          throwsArgumentError,
        );
      }
      await expectLater(
        signer.signMessage(
          registration: registration(),
          deploymentId: 'unknown',
          messageType: 'LtiDeepLinkingResponse',
        ),
        throwsArgumentError,
      );
      await expectLater(
        signer.createClientAssertion(
          registration: registration(),
          deploymentId: 'unknown',
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'public JWKS is constructed from a strict public-field allowlist',
    () async {
      final raw = TestPlatform.key.toJson();
      final public = LtiPublicKey.fromJwk({
        ...raw,
        'secret': 'must-not-leak',
        'jku': 'https://attacker.example',
      });
      expect(public.toJwk().keys.toSet(), {
        'kty',
        'kid',
        'alg',
        'use',
        'key_ops',
        'n',
        'e',
      });
      expect(() => public.toJwk()['d'] = raw['d'], throwsUnsupportedError);
      final encoded = jsonEncode(await signer.publicJwks());
      for (final name in ['d', 'p', 'q']) {
        expect(encoded, isNot(contains(raw[name])));
      }
      expect(encoded, isNot(contains('must-not-leak')));
    },
  );

  test(
    'rotation stages keys, switches signer and keeps old tokens verifiable',
    () async {
      final oldToken = await message();
      expect(() => keys.activate(second), throwsStateError);
      keys.publish(second.publicKey);
      expect(await keys.publicKeys(), hasLength(2));
      expect(await keys.signingKeyFor(registration()), same(first));
      keys.activate(second);
      final newToken = await message();
      await verify(oldToken);
      await verify(newToken);
      expect(() => keys.retire(second.publicKey.keyId), throwsStateError);
      keys.retire(first.publicKey.keyId);
      await verify(newToken);
      await expectLater(verify(oldToken), throwsA(isA<JoseException>()));
      final reused = LtiPublicKey.fromJwk({
        ...second.publicKey.toJwk(),
        'kid': first.publicKey.keyId,
      });
      expect(() => keys.publish(reused), throwsArgumentError);
    },
  );

  test(
    'rejects weak, public-only, mismatched and non-signing private keys',
    () {
      final weak = {
        ...TestPlatform.key.toJson(),
        'n': base64Url.encode(List<int>.filled(128, 255)),
        'kid': 'weak',
      };
      final variants = <Map<String, Object?>>[
        weak,
        first.publicKey.toJwk(),
        {
          ...TestPlatform.key.toJson(),
          'd': TestPlatform.otherKey.toJson()['d'],
        },
        {...TestPlatform.key.toJson(), 'alg': 'HS256'},
        {
          ...TestPlatform.key.toJson(),
          'key_ops': ['verify'],
        },
        {...TestPlatform.key.toJson(), 'kid': ''},
        {...TestPlatform.key.toJson(), 'e': 'AA'},
      ];
      for (final value in variants) {
        expect(() => RsaLtiSigningKey.fromJwk(value), throwsArgumentError);
      }
    },
  );

  test(
    'imports a generated private PEM and never includes invalid PEM in errors',
    () async {
      final imported = RsaLtiSigningKey.fromPem(
        privatePem(TestPlatform.key),
        keyId: 'pem-key',
      );
      final input = utf8.encode('PEM interoperability');
      expect(
        TestPlatform.key.verify(
          input,
          await imported.sign(input),
          algorithm: 'RS256',
        ),
        isTrue,
      );
      expect(imported.publicKey.keyId, 'pem-key');
      expect(
        () => RsaLtiSigningKey.fromPem('secret-value', keyId: 'bad'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'safe error',
            isNot(contains('secret-value')),
          ),
        ),
      );
    },
  );

  test(
    'external signing sees a stable payload despite concurrent caller mutation',
    () async {
      final gate = Completer<void>();
      final external = DelayedKey(first, gate.future);
      keys = MemoryLtiSigningKeyProvider(external);
      signer = LtiJwtSigner(keys: keys, clock: () => now);
      final values = ['original'];
      final pending = message(claims: {'https://example.test/items': values});
      values[0] = 'changed';
      gate.complete();
      expect((await verify(await pending))['https://example.test/items'], [
        'original',
      ]);
    },
  );

  test('does not return an expired JWT after slow external signing', () async {
    final gate = Completer<void>();
    keys = MemoryLtiSigningKeyProvider(DelayedKey(first, gate.future));
    signer = LtiJwtSigner(
      keys: keys,
      clock: () => now,
      lifetime: const Duration(seconds: 1),
    );
    final pending = message();
    now = now.add(const Duration(seconds: 1));
    gate.complete();
    await expectLater(pending, throwsStateError);
  });
}

LtiRegistration registration({String? audience, bool withEndpoint = true}) =>
    LtiRegistration(
      issuer: 'https://platform.example',
      clientId: 'client',
      authenticationEndpoint: Uri.parse('https://platform.example/authorize'),
      jwksUri: Uri.parse('https://platform.example/keys'),
      redirectUri: Uri.parse('https://tool.example/lti/launch'),
      deploymentIds: {'deployment'},
      targetLinkUris: {'https://tool.example/activity'},
      tokenEndpoint: withEndpoint
          ? Uri.parse('https://platform.example/token')
          : null,
      authorizationServerAudience: audience,
    );

final class DelayedKey implements LtiSigningKey {
  DelayedKey(this.delegate, this.ready);
  final LtiSigningKey delegate;
  final Future<void> ready;
  @override
  LtiPublicKey get publicKey => delegate.publicKey;
  @override
  Future<List<int>> sign(List<int> input) async {
    await ready;
    return delegate.sign(input);
  }
}

// Encode a fresh test key as PKCS#1 DER; no private fixture is persisted.
String privatePem(JsonWebKey key) {
  BigInt integer(String name) => base64Url
      .decode(base64Url.normalize(key.toJson()[name] as String))
      .fold(BigInt.zero, (value, byte) => (value << 8) | BigInt.from(byte));
  final p = integer('p');
  final q = integer('q');
  final d = integer('d');
  final sequence = ASN1Sequence();
  for (final number in [
    BigInt.zero,
    integer('n'),
    integer('e'),
    d,
    p,
    q,
    d % (p - BigInt.one),
    d % (q - BigInt.one),
    q.modInverse(p),
  ]) {
    sequence.add(ASN1Integer(number));
  }
  return '-----BEGIN RSA PRIVATE KEY-----\n${base64.encode(sequence.encodedBytes)}\n-----END RSA PRIVATE KEY-----';
}
