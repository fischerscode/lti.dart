import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';
import 'package:lti/lti.dart';

/// Runs an offline resource launch with a simulated platform and browser.
///
/// From the repository root:
/// `fvm dart run packages/lti/example/lti_example.dart`
///
/// The simulator signs a real RS256 token; the tool verifies it through its
/// configured JWKS endpoint. No network requests or HTTP server are involved.
Future<void> main() async {
  // In an application, provision these values from trusted platform settings.
  final registration = LtiRegistration(
    issuer: 'https://platform.example',
    clientId: 'example-client',
    deploymentIds: {'example-deployment'},
    authenticationEndpoint: Uri.parse('https://platform.example/authorize'),
    jwksUri: Uri.parse('https://platform.example/keys'),
    redirectUri: Uri.parse('https://tool.example/lti/launch'),
    targetLinkUris: {'https://tool.example/activity'},
  );

  // Only the simulated platform owns this key. Real tools fetch the platform's
  // public keys and never generate or receive its private signing key.
  final platformKey = JsonWebKey.fromJson({
    ...JsonWebKey.generate('RS256', keyBitLength: 2048).toJson(),
    'kid': 'example-platform-key',
  });
  final publicKey = LtiPublicKey.fromJwk(platformKey.toJson());
  final client = MockClient((request) async {
    if (request.method != 'GET' || request.url != registration.jwksUri) {
      throw StateError('Unexpected request in the offline example.');
    }
    return http.Response(
      jsonEncode({
        'keys': [publicKey.toJwk()],
      }),
      200,
      headers: {'content-type': 'application/jwk-set+json'},
    );
  });

  try {
    final tool = LtiTool(
      registrations: MemoryLtiRegistrationStore([registration]),
      transactions: MemoryLtiTransactionStore(),
      tokenVerifier: RemoteJwksVerifier(client: client),
    );

    // 1. Parse the platform's unsigned login-initiation parameters.
    final login = await tool.beginLogin(
      LtiLoginRequest.fromParameters({
        'iss': registration.issuer,
        'client_id': registration.clientId,
        'login_hint': 'example-opaque-hint',
        'target_link_uri': 'https://tool.example/activity',
      }),
    );

    // 2. An HTTP adapter stores this binding in a Secure, HttpOnly browser
    // cookie associated with login.state, then redirects to login.uri.
    // This variable stands in for that protected browser storage.
    final browserBinding = login.browserBinding;

    // 3. The simulated platform signs the launch using the redirect's nonce.
    final idToken = _platformLaunch(registration, login, platformKey);

    // 4. The adapter receives state/id_token from the platform's form POST.
    // Read browserBinding from the cookie, never from that form's parameters.
    final launch = await tool.completeResourceLaunch(
      state: login.state,
      browserBinding: browserBinding,
      idToken: idToken,
    );

    // 5. Apply application authorization before creating a session or showing
    // protected content. Identity/context can be absent in other launches.
    print('LTI resource launch verified.');
    print('User present: ${launch.user != null}');
    print('Context present: ${launch.context != null}');
    print('Learner role: ${launch.roles.contains(LtiRoles.learner)}');
  } finally {
    // The application owns the transport and closes it at shutdown.
    client.close();
  }
}

// Simulation only: a real platform creates this token outside the tool.
String _platformLaunch(
  LtiRegistration registration,
  LtiLoginRedirect login,
  JsonWebKey platformKey,
) {
  final issuedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final builder = JsonWebSignatureBuilder()
    ..jsonContent = {
      'iss': registration.issuer,
      'aud': registration.clientId,
      'iat': issuedAt,
      'exp': issuedAt + 120,
      'nonce': login.uri.queryParameters['nonce'],
      'sub': 'example-learner',
      LtiClaims.messageType: 'LtiResourceLinkRequest',
      LtiClaims.version: '1.3.0',
      LtiClaims.deploymentId: registration.deploymentIds.single,
      LtiClaims.targetLinkUri: 'https://tool.example/activity',
      LtiClaims.resourceLink: {'id': 'example-resource'},
      LtiClaims.context: {'id': 'example-course'},
      LtiClaims.roles: [LtiRoles.learner],
    }
    ..setProtectedHeader('kid', platformKey.keyId)
    ..addRecipient(platformKey, algorithm: 'RS256');
  return builder.build().toCompactSerialization();
}
