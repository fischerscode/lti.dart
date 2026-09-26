import 'package:lti/lti.dart';
import 'package:test/test.dart';

import 'support/platform.dart';

void main() {
  late TestPlatform platform;
  setUp(() => platform = TestPlatform());
  tearDown(() => platform.client.close());

  test('caches keys across launches', () async {
    await platform.complete(await platform.begin());
    await platform.complete(await platform.begin());
    expect(platform.requests, 1);
  });

  test('refreshes an expired key cache', () async {
    await platform.complete(await platform.begin());
    platform.now = platform.now.add(const Duration(minutes: 16));
    await platform.complete(await platform.begin());
    expect(platform.requests, 2);
  });

  test('coalesces concurrent JWKS requests', () async {
    final a = await platform.begin();
    final b = await platform.begin();
    await Future.wait([platform.complete(a), platform.complete(b)]);
    expect(platform.requests, 1);
  });

  test(
    'refreshes unknown kid after cooldown and accepts rotated key',
    () async {
      await platform.complete(await platform.begin());
      platform.publicKeys = [TestPlatform.publicKey(TestPlatform.otherKey)];
      platform.now = platform.now.add(const Duration(seconds: 31));
      final login = await platform.begin();
      await platform.complete(
        login,
        token: platform.sign(
          platform.claims(login),
          signingKey: TestPlatform.otherKey,
        ),
      );
      expect(platform.requests, 2);
    },
  );

  test('unknown kid flood does not continually refresh keys', () async {
    await platform.complete(await platform.begin());
    for (var i = 0; i < 3; i++) {
      final login = await platform.begin();
      await expectLater(
        platform.complete(
          login,
          token: platform.sign(
            platform.claims(login),
            signingKey: TestPlatform.otherKey,
          ),
        ),
        throwsA(isA<LtiException>()),
      );
    }
    expect(platform.requests, 1);
  });

  test('never trusts token-provided key URLs or inline keys', () async {
    final login = await platform.begin();
    final token = platform.sign(
      platform.claims(login),
      signingKey: TestPlatform.otherKey,
      headers: {
        'jku': 'https://attacker.example/keys',
        'jwk': TestPlatform.publicKey(TestPlatform.otherKey),
      },
    );
    await expectLater(
      platform.complete(login, token: token),
      throwsA(isA<LtiException>()),
    );
    expect(platform.requestedUris, [platform.registration.jwksUri]);
  });

  test(
    'platform failure is distinguishable and does not expose token',
    () async {
      platform.statusCode = 500;
      final login = await platform.begin();
      await expectLater(
        platform.complete(login),
        throwsA(
          isA<LtiException>().having(
            (e) => e.code,
            'code',
            LtiErrorCode.platformUnavailable,
          ),
        ),
      );
    },
  );
}
