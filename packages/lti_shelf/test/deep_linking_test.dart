import 'dart:convert';

import 'package:jose/jose.dart';
import 'package:lti/lti.dart';
import 'package:lti_shelf/lti_shelf.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../../lti/test/support/platform.dart';

void main() {
  test(
    'browser login dispatches selection and posts a signed response',
    () async {
      final platform = TestPlatform();
      addTearDown(platform.client.close);
      final tool = LtiTool(
        registrations: platform.tool.registrations,
        transactions: platform.tool.transactions,
        tokenVerifier: platform.verifier,
        clock: () => platform.now,
        signer: LtiJwtSigner(
          keys: MemoryLtiSigningKeyProvider(
            RsaLtiSigningKey.fromJwk(TestPlatform.otherKey.toJson()),
          ),
          clock: () => platform.now,
        ),
      );
      var selections = 0;
      final adapter = LtiShelf(
        tool: tool,
        publicOrigin: Uri.parse('https://tool.example'),
        onResourceLaunch: (_, _) => throw StateError('Wrong dispatcher'),
        onDeepLinkingLaunch: (request, launch) async {
          selections++;
          return deepLinkingFormResponse(
            await tool.createDeepLinkingResponse(
              launch: launch,
              items: [
                LtiContentItem.html(html: '<script>untrusted()</script>'),
              ],
            ),
          );
        },
      );
      final login = await adapter.handler(
        Request(
          'GET',
          Uri.parse('https://tool.example/lti/login')
              .replace(queryParameters: platform.loginParameters),
        ),
      );
      final redirect = Uri.parse(login.headers['location']!);
      final state = redirect.queryParameters['state']!;
      final claims =
          platform.claims(
              LtiLoginRedirect(
                uri: redirect,
                state: state,
                browserBinding: '',
                expiresAt: platform.now,
              ),
            )
            ..[LtiClaims.messageType] = 'LtiDeepLinkingRequest'
            ..remove(LtiClaims.resourceLink)
            ..[LtiDeepLinkingClaims.settings] = {
              'deep_link_return_url': 'https://platform.example/return?a=1&b=2',
              'accept_types': ['html'],
              'accept_presentation_document_targets': <String>[],
            };
      Request callback() => Request(
        'POST',
        Uri.parse('https://tool.example/lti/launch'),
        headers: {
          'content-type': 'application/x-www-form-urlencoded',
          'cookie': login.headers['set-cookie']!.split(';').first,
        },
        body: Uri(
          queryParameters: {'state': state, 'id_token': platform.sign(claims)},
        ).query,
      );
      final response = await adapter.handler(callback());
      expect(response.statusCode, 200);
      expect(selections, 1);
      expect(response.headers['set-cookie'], contains('Max-Age=0'));
      expect(response.headers['cache-control'], 'no-store');
      final html = await response.readAsString();
      expect(html, contains('method="post"'));
      expect(html, contains('return?a=1&amp;b=2'));
      expect(html, isNot(contains('<script>untrusted()')));
      final nonce = RegExp('script nonce="([^"]+)"')
          .firstMatch(html)!
          .group(1)!;
      expect(
        response.headers['content-security-policy'],
        contains("'nonce-$nonce'"),
      );
      final jwt = RegExp('name="JWT" value="([^"]+)"')
          .firstMatch(html)!
          .group(1)!;
      final store = JsonWebKeyStore()
        ..addKey(
          JsonWebKey.fromJson(TestPlatform.publicKey(TestPlatform.otherKey)),
        );
      final payload = await JsonWebSignature.fromCompactSerialization(jwt)
          .getPayload(store, allowedAlgorithms: ['RS256']);
      final result = jsonDecode(payload.stringContent) as Map;
      expect(result[LtiClaims.messageType], 'LtiDeepLinkingResponse');
      expect((await adapter.handler(callback())).statusCode, 400);
      expect(selections, 1);
    },
  );

  test(
    'form helper escapes attribute values and rejects unsafe actions',
    () async {
      final response = deepLinkingFormResponse(
        LtiDeepLinkingResponse(
          returnUrl: Uri.parse('https://platform.example/return'),
          jwt: '"><script>alert(1)</script>',
        ),
      );
      final html = await response.readAsString();
      expect(html, isNot(contains('<script>alert(1)</script>')));
      expect(html, contains('&quot;&gt;&lt;script&gt;'));
      expect(
        () => LtiDeepLinkingResponse(
          returnUrl: Uri.parse('javascript:alert(1)'),
          jwt: 'token',
        ),
        throwsArgumentError,
      );
    },
  );
}
