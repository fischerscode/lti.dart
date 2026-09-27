import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lti/lti.dart';
import 'package:test/test.dart';

import '../../lti/test/support/platform.dart';
import '../example/service_read_test.dart';

void main() {
  test(
    'read report requests tokens and GETs only, without exposing personal data',
    () async {
      final platform = TestPlatform();
      addTearDown(platform.client.close);
      final old = platform.registration;
      final registration = LtiRegistration(
        issuer: old.issuer,
        clientId: old.clientId,
        deploymentIds: old.deploymentIds,
        targetLinkUris: old.targetLinkUris,
        authenticationEndpoint: old.authenticationEndpoint,
        jwksUri: old.jwksUri,
        redirectUri: old.redirectUri,
        tokenEndpoint: Uri.parse('https://platform.example/token'),
      );
      final tool = LtiTool(
        registrations: MemoryLtiRegistrationStore([registration]),
        transactions: MemoryLtiTransactionStore(),
        tokenVerifier: platform.verifier,
        clock: () => platform.now,
      );
      Future<LtiResourceLaunch> launch(String role) async {
        final login = await tool.beginLogin(
          LtiLoginRequest.fromParameters(platform.loginParameters),
        );
        return await tool.completeResourceLaunch(
          state: login.state,
          browserBinding: login.browserBinding,
          idToken: platform.sign({
            ...platform.claims(login),
            LtiClaims.roles: [role],
            LtiServiceClaims.nrps: {
              'service_versions': ['2.0'],
              'context_memberships_url': 'https://platform.example/members',
            },
            LtiServiceClaims.ags: {
              'scope': [LtiServiceScopes.lineItemReadonly],
              'lineitems': 'https://platform.example/items',
            },
          }),
        );
      }

      final paths = <String>[];
      var failed = false;
      final client = MockClient((r) async {
        paths.add(r.url.path);
        if (r.url.path == '/token') {
          expect(r.method, 'POST');
          return http.Response(
            '{"access_token":"SECRET","token_type":"Bearer","expires_in":3600}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        expect(r.method, 'GET');
        expect(r.url.queryParameters['limit'], '10');
        if (failed) return http.Response('PRIVATE_ERROR', 403);
        if (r.url.path == '/members') {
          return http.Response(
            jsonEncode({
              'id': r.url.toString(),
              'context': {'id': 'course'},
              'members': [
                {
                  'user_id': 'PRIVATE_ID',
                  'name': 'PRIVATE_NAME',
                  'roles': [LtiRoles.learner],
                },
              ],
            }),
            200,
            headers: {'content-type': LtiNrpsClient.mediaType},
          );
        }
        return http.Response(
          '[]',
          200,
          headers: {'content-type': LtiAgsClient.lineItemsMediaType},
        );
      });
      addTearDown(client.close);
      final oauth = LtiOAuthClient(
        client: client,
        signer: LtiJwtSigner(
          keys: MemoryLtiSigningKeyProvider(
            RsaLtiSigningKey.fromJwk(TestPlatform.key.toJson()),
          ),
        ),
      );
      LtiServiceClient services(LtiResourceLaunch launch) => LtiServiceClient(
        launch: launch,
        oauth: oauth,
        client: client,
        allowedOrigins: {Uri.parse('https://platform.example')},
      );
      final teacher = await launch(LtiRoles.instructor);
      final report = await serviceReadReport(teacher, services);
      expect(report, contains('NRPS: OK; first page members=1'));
      expect(report, contains('AGS line items: OK; first page items=0'));
      expect(report, isNot(contains('PRIVATE')));
      expect(report, isNot(contains('SECRET')));
      expect(paths, ['/token', '/members', '/token', '/items']);
      failed = true;
      final failure = await serviceReadReport(teacher, services);
      expect(failure, contains('rejected; HTTP 403'));
      expect(failure, isNot(contains('PRIVATE')));
      final learner = await launch(LtiRoles.learner);
      final denied = await serviceReadReport(
        learner,
        (_) => throw StateError('must not construct'),
      );
      expect(denied, contains('Service reads skipped'));
    },
  );
}
