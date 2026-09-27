import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';
import 'package:lti/lti.dart';
import 'package:test/test.dart';

import 'support/platform.dart';

void main() {
  late TestPlatform platform;
  late LtiJwtSigner signer;
  late DateTime now;
  var calls = 0;
  late Future<http.Response> Function(http.Request) respond;
  late LtiOAuthClient oauth;
  late http.Client transport;
  late LtiRegistration registration;
  setUp(() {
    platform = TestPlatform();
    now = platform.now;
    calls = 0;
    registration = LtiRegistration(
      issuer: 'https://platform.example',
      clientId: 'client',
      deploymentIds: {'deployment', 'other'},
      authenticationEndpoint: Uri.parse('https://platform.example/auth'),
      jwksUri: Uri.parse('https://platform.example/keys'),
      redirectUri: Uri.parse('https://tool.example/launch'),
      targetLinkUris: {'https://tool.example/activity'},
      tokenEndpoint: Uri.parse('https://platform.example/token'),
      authorizationServerAudience: 'https://platform.example/audience',
    );
    signer = LtiJwtSigner(
      keys: MemoryLtiSigningKeyProvider(
        RsaLtiSigningKey.fromJwk(TestPlatform.key.toJson()),
      ),
      clock: () => now,
    );
    respond = (_) async => http.Response(
      jsonEncode({
        'access_token': 'SECRET',
        'token_type': 'Bearer',
        'expires_in': 60,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
    transport = MockClient((r) {
      calls++;
      return respond(r);
    });
    oauth = LtiOAuthClient(client: transport, signer: signer, clock: () => now);
  });
  tearDown(() {
    transport.close();
    platform.client.close();
  });

  Future<LtiAccessToken> get({
    Set<String> scopes = const {'read', 'write'},
    String? deployment,
  }) => oauth.accessToken(
    registration: registration,
    scopes: scopes,
    deploymentId: deployment,
  );

  test(
    'posts a verifiable assertion and canonical scopes to the trusted endpoint',
    () async {
      respond = (r) async {
        expect(r.method, 'POST');
        expect(r.url, registration.tokenEndpoint);
        expect(r.followRedirects, isFalse);
        expect(
          r.headers['content-type'],
          contains('application/x-www-form-urlencoded'),
        );
        final fields = r.bodyFields;
        expect(fields['grant_type'], 'client_credentials');
        expect(fields['scope'], 'read write');
        expect(
          fields['client_assertion_type'],
          'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
        );
        final keys = JsonWebKeyStore()
          ..addKey(
            JsonWebKey.fromJson(TestPlatform.publicKey(TestPlatform.key)),
          );
        final payload = await JsonWebSignature.fromCompactSerialization(
          fields['client_assertion']!,
        ).getPayload(keys, allowedAlgorithms: ['RS256']);
        final claims = jsonDecode(payload.stringContent) as Map;
        expect(claims['iss'], 'client');
        expect(claims['sub'], 'client');
        expect(claims['aud'], registration.authorizationServerAudience);
        expect(claims[LtiClaims.deploymentId], 'deployment');
        expect(claims['jti'], isNotEmpty);
        return http.Response(
          '{"access_token":"SECRET","token_type":"bearer","expires_in":60}',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      };
      final token = await get(deployment: 'deployment');
      expect(token.scopes, {'read', 'write'});
      expect(token.expiresAt, now.add(const Duration(seconds: 60)));
      expect(token.toString(), isNot(contains('SECRET')));
      expect(() => token.scopes.add('extra'), throwsUnsupportedError);
    },
  );

  test('coalesces identical scopes and separates scopes, registrations and deployments', () async {
    final values = await Future.wait([
      get(),
      get(scopes: {'write', 'read'}),
    ]);
    expect(calls, 1);
    expect(identical(values[0], values[1]), isTrue);
    await get(scopes: {'read'});
    await get(deployment: 'deployment');
    await get(deployment: 'other');
    final otherRegistration = LtiRegistration(
      issuer: registration.issuer,
      clientId: 'different',
      deploymentIds: {'deployment'},
      targetLinkUris: registration.targetLinkUris,
      authenticationEndpoint: registration.authenticationEndpoint,
      jwksUri: registration.jwksUri,
      redirectUri: registration.redirectUri,
      tokenEndpoint: registration.tokenEndpoint,
    );
    await oauth.accessToken(
      registration: otherRegistration,
      scopes: {'read', 'write'},
    );
    expect(calls, 5);
  });

  test('refreshes early with fresh assertions; stale invalidation keeps replacement', () async {
    final assertions = <String>[];
    final original = respond;
    respond = (r) {
      assertions.add(r.bodyFields['client_assertion']!);
      return original(r);
    };
    final first = await get();
    now = now.add(const Duration(seconds: 30));
    final second = await get();
    expect(calls, 2);
    expect(assertions.toSet(), hasLength(2));
    oauth.invalidate(first);
    expect(await get(), same(second));
    oauth.invalidate(second);
    await get();
    expect(calls, 3);
  });

  for (final entry in {
    302: LtiOAuthErrorCode.rejected,
    400: LtiOAuthErrorCode.rejected,
    401: LtiOAuthErrorCode.rejected,
    429: LtiOAuthErrorCode.unavailable,
    503: LtiOAuthErrorCode.unavailable,
  }.entries) {
    test(
      'handles HTTP ${entry.key} without leaking or caching the response',
      () async {
        respond = (_) async => http.Response(
          'SECRET error',
          entry.key,
          headers: {'location': 'https://evil.example'},
        );
        for (var i = 0; i < 2; i++) {
          await expectLater(
            get(),
            throwsA(
              isA<LtiOAuthException>()
                  .having((e) => e.code, 'code', entry.value)
                  .having(
                    (e) => e.toString(),
                    'safe',
                    isNot(contains('SECRET')),
                  ),
            ),
          );
        }
        expect(calls, 2);
      },
    );
  }

  for (final override in <Map<String, Object?>>[
    {'access_token': 'bad\r\ntoken'},
    {'token_type': 'MAC'},
    {'expires_in': 0},
    {'expires_in': '60'},
    {'scope': null},
    {'scope': 'read  write'},
  ]) {
    test('rejects malformed token response $override', () async {
      respond = (_) async => http.Response(
        jsonEncode({
          'access_token': 'SECRET',
          'token_type': 'Bearer',
          'expires_in': 60,
          ...override,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
      await expectLater(
        get(),
        throwsA(
          isA<LtiOAuthException>().having(
            (e) => e.code,
            'code',
            LtiOAuthErrorCode.invalidResponse,
          ),
        ),
      );
    });
  }

  test(
    'rejects insufficient grants and accepts explicit grants covering request',
    () async {
      respond = (_) async => http.Response(
        '{"access_token":"SECRET","token_type":"Bearer","expires_in":60,"scope":"read"}',
        200,
        headers: {'content-type': 'application/json'},
      );
      await expectLater(
        get(),
        throwsA(
          isA<LtiOAuthException>().having(
            (e) => e.code,
            'code',
            LtiOAuthErrorCode.insufficientScope,
          ),
        ),
      );
      expect((await get(scopes: {'read'})).scopes, {'read'});
    },
  );

  test('bounds cache and concurrent fetches', () async {
    oauth = LtiOAuthClient(
      client: transport,
      signer: signer,
      maxEntries: 1,
      clock: () => now,
    );
    final gate = Completer<http.Response>();
    respond = (_) => gate.future;
    final pending = get();
    await expectLater(
      get(scopes: {'another'}),
      throwsA(
        isA<LtiOAuthException>().having(
          (e) => e.code,
          'code',
          LtiOAuthErrorCode.capacity,
        ),
      ),
    );
    gate.complete(
      http.Response(
        '{"access_token":"SECRET","token_type":"Bearer","expires_in":60}',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    await pending;
    await get(scopes: {'another'});
    await get();
    expect(calls, 3);
  });

  test('rejects empty or invalid scopes before sending', () async {
    await expectLater(get(scopes: {}), throwsArgumentError);
    await expectLater(get(scopes: {'read write'}), throwsArgumentError);
    await expectLater(get(deployment: 'foreign'), throwsArgumentError);
    expect(calls, 0);
  });

  test(
    'does not reuse short-lived tokens and rejects transit-expired tokens',
    () async {
      respond = (_) async => http.Response(
        '{"access_token":"SHORT","token_type":"Bearer","expires_in":10}',
        200,
        headers: {'content-type': 'application/json'},
      );
      await get();
      await get();
      expect(calls, 2);
      respond = (_) async {
        now = now.add(const Duration(seconds: 11));
        return http.Response(
          '{"access_token":"EXPIRED","token_type":"Bearer","expires_in":10}',
          200,
          headers: {'content-type': 'application/json'},
        );
      };
      await expectLater(
        get(),
        throwsA(
          isA<LtiOAuthException>().having(
            (e) => e.code,
            'code',
            LtiOAuthErrorCode.invalidResponse,
          ),
        ),
      );
    },
  );

  test('rejects non-JSON responses and sanitizes transport failures', () async {
    respond = (_) async => http.Response('SECRET HTML', 200);
    await expectLater(
      get(),
      throwsA(
        isA<LtiOAuthException>().having(
          (e) => e.code,
          'code',
          LtiOAuthErrorCode.invalidResponse,
        ),
      ),
    );
    respond = (_) async => throw http.ClientException('PRIVATE assertion');
    await expectLater(
      get(),
      throwsA(
        isA<LtiOAuthException>()
            .having((e) => e.code, 'code', LtiOAuthErrorCode.unavailable)
            .having((e) => e.toString(), 'safe', isNot(contains('PRIVATE'))),
      ),
    );
  });

  test('limits response size', () async {
    oauth = LtiOAuthClient(
      client: transport,
      signer: signer,
      maxResponseBytes: 8,
    );
    await expectLater(
      get(),
      throwsA(
        isA<LtiOAuthException>().having(
          (e) => e.code,
          'code',
          LtiOAuthErrorCode.invalidResponse,
        ),
      ),
    );
  });

  test('times out without caching a late response', () async {
    oauth = LtiOAuthClient(
      client: transport,
      signer: signer,
      timeout: const Duration(milliseconds: 50),
      clock: () => now,
    );
    final gate = Completer<http.Response>();
    respond = (_) => gate.future;
    await expectLater(
      get(),
      throwsA(
        isA<LtiOAuthException>().having(
          (e) => e.code,
          'code',
          LtiOAuthErrorCode.unavailable,
        ),
      ),
    );
    gate.complete(
      http.Response(
        '{"access_token":"SECRET","token_type":"Bearer","expires_in":60}',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    await get();
    expect(calls, 2);
  });
}
