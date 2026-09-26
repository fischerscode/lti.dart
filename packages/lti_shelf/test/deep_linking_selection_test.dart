import 'dart:convert';

import 'package:jose/jose.dart';
import 'package:lti/lti.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../../lti/test/support/platform.dart';
import '../example/bycs_server.dart';
import '../example/deep_linking_selection.dart';

void main() {
  late TestPlatform platform;
  late LtiTool tool;
  late Handler handler;
  final origin = Uri.parse('https://tool.example');
  setUp(() {
    platform = TestPlatform();
    tool = LtiTool(
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
    handler = integrationHandler(tool: tool, origin: origin);
  });
  tearDown(() => platform.client.close());

  Future<LtiDeepLinkingLaunch> verified({
    String role = LtiRoles.instructor,
    bool supported = true,
  }) async {
    final login = await platform.begin();
    final claims = platform.claims(login)
      ..[LtiClaims.messageType] = 'LtiDeepLinkingRequest'
      ..[LtiClaims.roles] = [role]
      ..remove(LtiClaims.resourceLink)
      ..[LtiDeepLinkingClaims.settings] = {
        'deep_link_return_url': 'https://platform.example/return',
        'accept_types': [if (supported) 'ltiResourceLink'],
        'accept_presentation_document_targets': ['window'],
        'data': 'opaque-platform-value',
      };
    return await tool.completeLaunch(
      state: login.state,
      browserBinding: login.browserBinding,
      idToken: platform.sign(claims),
    ) as LtiDeepLinkingLaunch;
  }

  Future<({String cookie, Map<String, String> fields})> form(
    Response response,
  ) async {
    expect(response.statusCode, 200);
    final html = await response.readAsString();
    String field(String name) =>
        RegExp('name="$name" value="([^"]+)"').firstMatch(html)!.group(1)!;
    return (
      cookie: response.headersAll['set-cookie']!
          .firstWhere((s) => s.startsWith('__Host-lti-selection-'))
          .split(';')
          .first,
      fields: {
        'session': field('session'),
        'csrf': field('csrf'),
        'choice': 'select',
      },
    );
  }

  Request submit(
    ({String cookie, Map<String, String> fields}) data, {
    String? cookie,
    String? requestOrigin,
    Map<String, String>? fields,
  }) => Request(
    'POST',
    origin.resolve(DeepLinkingSelection.path),
    headers: {
      'origin': requestOrigin ?? origin.origin,
      'content-type': 'application/x-www-form-urlencoded',
      'cookie': cookie ?? data.cookie,
    },
    body: Uri(queryParameters: fields ?? data.fields).query,
  );
  Future<Map<String, dynamic>> verify(Response response) async {
    expect(response.statusCode, 200);
    expect(response.headers['content-security-policy'], contains('nonce-'));
    final html = await response.readAsString();
    final jwt = RegExp('name="JWT" value="([^"]+)"')
        .firstMatch(html)!
        .group(1)!;
    final store = JsonWebKeyStore()
      ..addKey(
        JsonWebKey.fromJson(TestPlatform.publicKey(TestPlatform.otherKey)),
      );
    final payload = await JsonWebSignature.fromCompactSerialization(jwt)
        .getPayload(store, allowedAlgorithms: ['RS256']);
    return jsonDecode(payload.stringContent) as Map<String, dynamic>;
  }

  test('selection signs a resource link and its subsequent launch carries the marker', () async {
    final selection = DeepLinkingSelection(tool: tool, origin: origin);
    final data = await form(
      selection.begin(
        Request('POST', origin.resolve('/lti/launch')),
        await verified(),
      ),
    );
    final response = await selection.complete(submit(data));
    expect(response.headers['set-cookie'], contains('Max-Age=0'));
    final claims = await verify(response);
    expect(claims[LtiClaims.messageType], 'LtiDeepLinkingResponse');
    expect(claims[LtiDeepLinkingClaims.data], 'opaque-platform-value');
    final item =
        (claims[LtiDeepLinkingClaims.contentItems] as List).single as Map;
    expect(item['url'], origin.resolve('/activity').toString());
    expect(item.containsKey('lineItem'), false);
    final login = await platform.begin();
    final launchClaims = platform.claims(login)
      ..[LtiClaims.custom] = item['custom'];
    final resource = await handler(
      Request(
        'POST',
        origin.resolve('/lti/launch'),
        headers: {
          'content-type': 'application/x-www-form-urlencoded',
          'cookie': '__Host-lti-${login.state}=${login.browserBinding}',
        },
        body: Uri(
          queryParameters: {
            'state': login.state,
            'id_token': platform.sign(launchClaims),
          },
        ).query,
      ),
    );
    expect(
      await resource.readAsString(),
      contains('Deep Linking test marker present: true'),
    );
    expect((await selection.complete(submit(data))).statusCode, 403);
  });
  test(
    'cancel signs an empty response even when resource links are unsupported',
    () async {
      final selection = DeepLinkingSelection(tool: tool, origin: origin);
      final data = await form(
        selection.begin(
          Request('POST', origin.resolve('/lti/launch')),
          await verified(supported: false),
        ),
      );
      expect((await selection.complete(submit(data))).statusCode, 400);
      final claims = await verify(
        await selection.complete(
          submit(data, fields: {...data.fields, 'choice': 'cancel'}),
        ),
      );
      expect(claims[LtiDeepLinkingClaims.contentItems], isEmpty);
      expect(claims[LtiDeepLinkingClaims.data], 'opaque-platform-value');
    },
  );
  test('requires browser cookie, CSRF token and matching origin', () async {
    final selection = DeepLinkingSelection(tool: tool, origin: origin);
    final data = await form(
      selection.begin(
        Request('POST', origin.resolve('/lti/launch')),
        await verified(),
      ),
    );
    expect(
      (await selection.complete(submit(data, cookie: ''))).statusCode,
      403,
    );
    expect(
      (await selection.complete(
        submit(data, cookie: '${data.cookie}; ${data.cookie}'),
      )).statusCode,
      403,
    );
    expect(
      (await selection.complete(
        submit(data, requestOrigin: 'https://evil.example'),
      )).statusCode,
      403,
    );
    expect(
      (await selection.complete(
        submit(data, fields: {...data.fields, 'csrf': 'wrong'}),
      )).statusCode,
      403,
    );
    expect((await selection.complete(submit(data))).statusCode, 200);
  });
  test(
    'expires sessions and rejects learners under the example policy',
    () async {
      var now = platform.now;
      final selection = DeepLinkingSelection(
        tool: tool,
        origin: origin,
        clock: () => now,
      );
      expect(
        selection
            .begin(
              Request('POST', origin.resolve('/lti/launch')),
              await verified(role: LtiRoles.learner),
            )
            .statusCode,
        403,
      );
      final data = await form(
        selection.begin(
          Request('POST', origin.resolve('/lti/launch')),
          await verified(),
        ),
      );
      now = now.add(const Duration(minutes: 11));
      expect((await selection.complete(submit(data))).statusCode, 403);
    },
  );
  test(
    'bounds pending sessions and consumes before concurrent signing',
    () async {
      final selection = DeepLinkingSelection(
        tool: tool,
        origin: origin,
        maxSessions: 1,
      );
      final launch = await verified();
      final data = await form(
        selection.begin(Request('POST', origin.resolve('/lti/launch')), launch),
      );
      expect(
        selection
            .begin(Request('POST', origin.resolve('/lti/launch')), launch)
            .statusCode,
        503,
      );
      final results = await Future.wait([
        selection.complete(submit(data)),
        selection.complete(submit(data)),
      ]);
      expect(results.map((r) => r.statusCode).toList()..sort(), [200, 403]);
    },
  );
  test('parallel selections keep separate browser bindings', () async {
    final selection = DeepLinkingSelection(tool: tool, origin: origin);
    final first = await form(
      selection.begin(
        Request('POST', origin.resolve('/lti/launch')),
        await verified(),
      ),
    );
    final second = await form(
      selection.begin(
        Request('POST', origin.resolve('/lti/launch')),
        await verified(),
      ),
    );
    expect(
      (await selection.complete(submit(first, cookie: second.cookie)))
          .statusCode,
      403,
    );
    expect((await selection.complete(submit(first))).statusCode, 200);
    expect((await selection.complete(submit(second))).statusCode, 200);
  });
  test('integration runner dispatches a signed deep linking callback to selection UI', () async {
    final login = await platform.begin();
    final launch = await verified();
    final claims = Map<String, Object?>.from(launch.claims)
      ..['nonce'] = login.uri.queryParameters['nonce'];
    final response = await handler(
      Request(
        'POST',
        origin.resolve('/lti/launch'),
        headers: {
          'content-type': 'application/x-www-form-urlencoded',
          'cookie': '__Host-lti-${login.state}=${login.browserBinding}',
        },
        body: Uri(
          queryParameters: {
            'state': login.state,
            'id_token': platform.sign(claims),
          },
        ).query,
      ),
    );
    final data = await form(response);
    final result = await verify(await handler(submit(data)));
    expect(result[LtiClaims.messageType], 'LtiDeepLinkingResponse');
  });
}
