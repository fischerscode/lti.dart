import 'dart:convert';

import 'package:lti/lti.dart';
import 'package:test/test.dart';

import 'support/platform.dart';

Matcher failsWith(LtiErrorCode code) =>
    throwsA(isA<LtiException>().having((e) => e.code, 'code', code));

void main() {
  late TestPlatform platform;
  setUp(() => platform = TestPlatform());
  tearDown(() => platform.client.close());

  test('builds OIDC request and preserves opaque hints exactly', () async {
    final login = await platform.begin();
    final query = login.uri.queryParameters;
    expect(query['scope'], 'openid');
    expect(query['response_type'], 'id_token');
    expect(query['response_mode'], 'form_post');
    expect(query['prompt'], 'none');
    expect(query['login_hint'], platform.loginParameters['login_hint']);
    expect(
      query['lti_message_hint'],
      platform.loginParameters['lti_message_hint'],
    );
    expect(query['redirect_uri'], platform.registration.redirectUri.toString());
    expect({login.state, login.browserBinding, query['nonce']}.length, 3);
    expect(login.state.length, 43);
    expect((await platform.begin()).state, isNot(login.state));
  });

  test(
    'validates a real signature and exposes immutable typed launch data',
    () async {
      final login = await platform.begin();
      final claims = platform.claims(login)
        ..['https://vendor.example/extra'] = {
          'value': [1],
        };
      final launch = await platform.complete(login, claims: claims);
      expect(launch.user!.subject, 'student');
      expect(launch.user!.email, isNull);
      expect(launch.context!.id, 'course');
      expect(launch.resourceLink.id, 'resource');
      expect(launch.custom, {'exercise': '42'});
      expect(launch.deploymentId, 'deployment');
      expect(() => launch.roles.clear(), throwsUnsupportedError);
      expect(
        () =>
            (launch.claims[LtiClaims.resourceLink]!
                    as Map<String, Object?>)['id'] =
                'forged',
        throwsUnsupportedError,
      );
      expect(launch.claims['https://vendor.example/extra'], {
        'value': [1],
      });
    },
  );

  test('supports anonymous launches with an empty roles list', () async {
    final login = await platform.begin();
    final claims = platform.claims(login)
      ..remove('sub')
      ..[LtiClaims.roles] = <String>[];
    final launch = await platform.complete(login, claims: claims);
    expect(launch.user, isNull);
    expect(launch.roles, isEmpty);
  });

  test('rejects replay, including concurrent submission', () async {
    final login = await platform.begin();
    final token = platform.sign(platform.claims(login));
    final results = await Future.wait(
      List.generate(2, (_) async {
        try {
          await platform.complete(login, token: token);
          return true;
        } on LtiException catch (e) {
          expect(e.code, LtiErrorCode.invalidState);
          return false;
        }
      }),
    );
    expect(results.where((success) => success), hasLength(1));
  });

  test(
    'wrong browser cannot consume the rightful browser transaction',
    () async {
      final login = await platform.begin();
      await expectLater(
        platform.complete(login, binding: 'attacker'),
        failsWith(LtiErrorCode.invalidState),
      );
      expect(platform.requests, 0);
      await platform.complete(login);
    },
  );

  test('expired login is rejected before accessing platform keys', () async {
    final login = await platform.begin();
    platform.now = platform.now.add(const Duration(minutes: 5));
    await expectLater(
      platform.complete(login),
      failsWith(LtiErrorCode.invalidState),
    );
    expect(platform.requests, 0);
  });

  final invalidClaims = <String, Object?>{
    'iss': 'https://attacker.example',
    'aud': 'different-client',
    'nonce': 'wrong',
    'azp': 'wrong',
    'iat': 9999999999,
    'exp': 1,
    'nbf': 9999999999,
    LtiClaims.version: '1.1',
    LtiClaims.deploymentId: 'unregistered',
    LtiClaims.targetLinkUri: 'https://attacker.example',
    LtiClaims.roles: 'Learner',
    LtiClaims.resourceLink: {'id': ''},
    'sub': '',
    LtiClaims.custom: {'count': 3},
  };
  for (final entry in invalidClaims.entries) {
    test('rejects invalid ${entry.key}', () async {
      final login = await platform.begin();
      final claims = platform.claims(login)..[entry.key] = entry.value;
      await expectLater(
        platform.complete(login, claims: claims),
        failsWith(LtiErrorCode.invalidClaims),
      );
    });
  }
  for (final name in [
    'iss',
    'aud',
    'nonce',
    'iat',
    'exp',
    LtiClaims.version,
    LtiClaims.deploymentId,
    LtiClaims.targetLinkUri,
    LtiClaims.roles,
    LtiClaims.resourceLink,
  ]) {
    test('rejects missing $name', () async {
      final login = await platform.begin();
      await expectLater(
        platform.complete(login, claims: platform.claims(login)..remove(name)),
        failsWith(LtiErrorCode.invalidClaims),
      );
    });
  }

  test('multiple audiences require azp identifying this client', () async {
    var login = await platform.begin();
    await expectLater(
      platform.complete(
        login,
        claims: platform.claims(login)..['aud'] = ['client', 'another'],
      ),
      failsWith(LtiErrorCode.invalidClaims),
    );
    login = await platform.begin();
    await platform.complete(
      login,
      claims: platform.claims(login)
        ..['aud'] = ['client', 'another']
        ..['azp'] = 'client',
    );
  });

  test('does not dispatch unsupported message types', () async {
    final login = await platform.begin();
    await expectLater(
      platform.complete(
        login,
        claims: platform.claims(login)
          ..[LtiClaims.messageType] = 'LtiDeepLinkingRequest',
      ),
      failsWith(LtiErrorCode.unsupportedMessage),
    );
  });

  test('rejects old tokens even when their expiry is in the future', () async {
    final login = await platform.begin();
    final claims = platform.claims(login)
      ..['iat'] =
          platform.now
              .subtract(const Duration(hours: 1))
              .millisecondsSinceEpoch ~/
          1000;
    await expectLater(
      platform.complete(login, claims: claims),
      failsWith(LtiErrorCode.invalidClaims),
    );
  });

  test('deployment hint is bound to the signed deployment', () async {
    final login = await platform.tool.beginLogin(
      LtiLoginRequest.fromParameters(
        platform.loginParameters..['lti_deployment_id'] = 'other-deployment',
      ),
    );
    await expectLater(
      platform.complete(login),
      failsWith(LtiErrorCode.invalidClaims),
    );
  });

  test('modified payload fails signature verification', () async {
    final login = await platform.begin();
    final parts = platform.sign(platform.claims(login)).split('.');
    parts[1] = base64Url
        .encode(
          utf8.encode(jsonEncode(platform.claims(login)..['sub'] = 'attacker')),
        )
        .replaceAll('=', '');
    await expectLater(
      platform.complete(login, token: parts.join('.')),
      failsWith(LtiErrorCode.invalidToken),
    );
  });

  test('rejects unsigned tokens before fetching keys', () async {
    final login = await platform.begin();
    final header = base64Url
        .encode(utf8.encode('{"alg":"none","kid":"platform-key"}'))
        .replaceAll('=', '');
    await expectLater(
      platform.complete(login, token: '$header.e30.signature'),
      failsWith(LtiErrorCode.invalidToken),
    );
    expect(platform.requests, 0);
  });

  test(
    'rejects unregistered issuer and target without network calls',
    () async {
      for (final parameter in [
        {'iss': 'https://attacker.example'},
        {'target_link_uri': 'https://attacker.example'},
      ]) {
        await expectLater(
          platform.tool.beginLogin(
            LtiLoginRequest.fromParameters({
              ...platform.loginParameters,
              ...parameter,
            }),
          ),
          throwsA(isA<LtiException>()),
        );
      }
      expect(platform.requests, 0);
    },
  );

  test(
    'issuer is exact, and client is required when registration is ambiguous',
    () async {
      final registration = platform.registration;
      final second = LtiRegistration(
        issuer: registration.issuer,
        clientId: 'second',
        authenticationEndpoint: registration.authenticationEndpoint,
        jwksUri: registration.jwksUri,
        redirectUri: registration.redirectUri,
        deploymentIds: registration.deploymentIds,
        targetLinkUris: registration.targetLinkUris,
      );
      final store = MemoryLtiRegistrationStore([registration, second]);
      expect(await store.find(registration.issuer), isNull);
      expect(
        await store.find(registration.issuer, clientId: 'second'),
        same(second),
      );
      expect(
        await store.find('${registration.issuer}/', clientId: 'second'),
        isNull,
      );
    },
  );
}
