import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';
import 'package:lti/lti.dart';

/// In-process platform simulator: signs real RSA tokens and serves public JWKS.
final class TestPlatform {
  TestPlatform() {
    client = MockClient((request) async {
      requests++;
      requestedUris.add(request.url);
      if (request.followRedirects) {
        throw StateError('Redirects must be disabled');
      }
      return http.Response(jsonEncode({'keys': publicKeys}), statusCode);
    });
    verifier = RemoteJwksVerifier(client: client, clock: () => now);
    tool = LtiTool(
      registrations: MemoryLtiRegistrationStore([registration]),
      transactions: MemoryLtiTransactionStore(),
      tokenVerifier: verifier,
      clock: () => now,
    );
  }
  static final key = _key('platform-key');
  static final otherKey = _key('rotated-key');
  static JsonWebKey _key(String id) => JsonWebKey.fromJson({
    ...JsonWebKey.generate('RS256', keyBitLength: 2048).toJson(),
    'kid': id,
  });
  static Map<String, Object?> publicKey(JsonWebKey key) => {
    'kty': 'RSA',
    'kid': key.keyId,
    'use': 'sig',
    'alg': 'RS256',
    'n': key.toJson()['n'],
    'e': key.toJson()['e'],
  };

  DateTime now = DateTime.utc(2026, 9, 26, 12);
  int requests = 0;
  int statusCode = 200;
  final requestedUris = <Uri>[];
  List<Map<String, Object?>> publicKeys = [publicKey(key)];
  late final http.Client client;
  late final RemoteJwksVerifier verifier;
  late final LtiTool tool;
  final registration = LtiRegistration(
    issuer: 'https://platform.example',
    clientId: 'client',
    authenticationEndpoint: Uri.parse('https://platform.example/authorize'),
    jwksUri: Uri.parse('https://platform.example/keys'),
    redirectUri: Uri.parse('https://tool.example/lti/launch'),
    deploymentIds: {'deployment', 'other-deployment'},
    targetLinkUris: {'https://tool.example/activity'},
    additionalTrustedAudiences: {'another'},
  );
  Map<String, String> get loginParameters => {
    'iss': registration.issuer,
    'client_id': registration.clientId,
    'login_hint': 'opaque login hint +/%',
    'lti_message_hint': 'opaque message hint +/%',
    'target_link_uri': registration.targetLinkUris.single,
  };
  Future<LtiLoginRedirect> begin() =>
      tool.beginLogin(LtiLoginRequest.fromParameters(loginParameters));

  Map<String, Object?> claims(LtiLoginRedirect login) => {
    'iss': registration.issuer,
    'aud': registration.clientId,
    'sub': 'student',
    'iat': now.millisecondsSinceEpoch ~/ 1000,
    'exp': now.add(const Duration(minutes: 2)).millisecondsSinceEpoch ~/ 1000,
    'nonce': login.uri.queryParameters['nonce'],
    LtiClaims.messageType: 'LtiResourceLinkRequest',
    LtiClaims.version: '1.3.0',
    LtiClaims.deploymentId: 'deployment',
    LtiClaims.targetLinkUri: registration.targetLinkUris.single,
    LtiClaims.roles: [
      'http://purl.imsglobal.org/vocab/lis/v2/membership#Learner',
    ],
    LtiClaims.resourceLink: {'id': 'resource', 'title': 'Exercise'},
    LtiClaims.context: {'id': 'course', 'title': 'Class'},
    LtiClaims.custom: {'exercise': '42'},
  };
  String sign(
    Map<String, Object?> claims, {
    JsonWebKey? signingKey,
    Map<String, Object?> headers = const {},
  }) {
    final selected = signingKey ?? key;
    final builder = JsonWebSignatureBuilder()..jsonContent = claims;
    builder.setProtectedHeader('kid', selected.keyId);
    headers.forEach(builder.setProtectedHeader);
    builder.addRecipient(selected, algorithm: 'RS256');
    return builder.build().toCompactSerialization();
  }

  Future<LtiResourceLaunch> complete(
    LtiLoginRedirect login, {
    Map<String, Object?>? claims,
    String? token,
    String? binding,
  }) => tool.completeResourceLaunch(
    state: login.state,
    browserBinding: binding ?? login.browserBinding,
    idToken: token ?? sign(claims ?? this.claims(login)),
  );
}
