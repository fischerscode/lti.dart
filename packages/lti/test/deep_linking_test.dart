import 'dart:convert';

import 'package:jose/jose.dart';
import 'package:lti/lti.dart';
import 'package:test/test.dart';

import 'support/platform.dart';

Map<String, Object?> settings() => {
  'deep_link_return_url': 'https://platform.example/return?opaque=1&second=2',
  'accept_types': ['ltiResourceLink', 'link', 'file', 'html', 'image'],
  'accept_presentation_document_targets': ['window', 'iframe', 'embed'],
};

void main() {
  late TestPlatform platform;
  late LtiTool tool;
  late LtiJwtSigner signer;
  setUp(() {
    platform = TestPlatform();
    signer = LtiJwtSigner(
      keys: MemoryLtiSigningKeyProvider(
        RsaLtiSigningKey.fromJwk(TestPlatform.otherKey.toJson()),
      ),
      clock: () => platform.now,
    );
    tool = LtiTool(
      registrations: platform.tool.registrations,
      transactions: platform.tool.transactions,
      tokenVerifier: platform.verifier,
      signer: signer,
      clock: () => platform.now,
    );
  });
  tearDown(() => platform.client.close());

  Future<LtiDeepLinkingLaunch> launch({
    Map<String, Object?>? options,
    void Function(Map<String, Object?>)? mutate,
  }) async {
    final login = await platform.begin();
    final claims = platform.claims(login)
      ..[LtiClaims.messageType] = 'LtiDeepLinkingRequest'
      ..[LtiDeepLinkingClaims.settings] = options ?? settings()
      ..remove(LtiClaims.resourceLink)
      ..remove(LtiClaims.roles)
      ..remove(LtiClaims.targetLinkUri);
    mutate?.call(claims);
    return await tool.completeLaunch(
      state: login.state,
      browserBinding: login.browserBinding,
      idToken: platform.sign(claims),
    ) as LtiDeepLinkingLaunch;
  }

  Future<Map<String, Object?>> verify(LtiDeepLinkingResponse response) async {
    final store = JsonWebKeyStore()
      ..addKey(
        JsonWebKey.fromJson(TestPlatform.publicKey(TestPlatform.otherKey)),
      );
    final payload = await JsonWebSignature.fromCompactSerialization(
      response.jwt,
    ).getPayload(store, allowedAlgorithms: ['RS256']);
    return jsonDecode(payload.stringContent) as Map<String, Object?>;
  }

  test('selection returns a verifiable LTI response and supports a subsequent launch', () async {
    final request = await launch(
      options: settings()..['data'] = 'opaque +/%<>',
    );
    expect(request.roles, isEmpty);
    expect(request.targetLinkUri, platform.registration.targetLinkUris.single);
    expect(request.settings.autoCreate, false);
    expect(request.settings.acceptLineItem, isNull);
    final response = await tool.createDeepLinkingResponse(
      launch: request,
      items: [
        LtiContentItem.ltiResourceLink(
          url: Uri.parse(request.targetLinkUri),
          title: 'Exercise',
          custom: {'exercise': '42'},
          lineItem: LtiDeepLinkingLineItem(scoreMaximum: 10),
        ),
      ],
      message: 'Selected',
    );
    final claims = await verify(response);
    expect(claims['iss'], 'client');
    expect(claims['aud'], platform.registration.issuer);
    expect(claims[LtiClaims.version], '1.3.0');
    expect(claims[LtiClaims.messageType], 'LtiDeepLinkingResponse');
    expect(claims[LtiClaims.deploymentId], 'deployment');
    expect(claims[LtiDeepLinkingClaims.data], 'opaque +/%<>');
    expect(claims[LtiDeepLinkingClaims.message], 'Selected');
    expect(response.formFields, {'JWT': response.jwt});
    expect(response.returnUrl.toString(), settings()['deep_link_return_url']);
    final selected =
        (claims[LtiDeepLinkingClaims.contentItems]! as List).single as Map;
    final login = await platform.begin();
    final resourceClaims = platform.claims(login)
      ..[LtiClaims.custom] = selected['custom'];
    final resource = await platform.complete(login, claims: resourceClaims);
    expect(resource.custom['exercise'], '42');
  });

  for (final data in [
    '',
    null,
    {
      'nested': ['opaque'],
    },
  ]) {
    test('cancellation echoes present opaque data: $data', () async {
      final request = await launch(options: settings()..['data'] = data);
      final claims = await verify(
        await tool.createDeepLinkingResponse(launch: request),
      );
      expect(claims.containsKey(LtiDeepLinkingClaims.data), true);
      expect(claims[LtiDeepLinkingClaims.data], data);
      expect(claims[LtiDeepLinkingClaims.contentItems], isEmpty);
    });
  }
  test('absent data remains absent and errors are signed', () async {
    final response = await tool.createDeepLinkingResponse(
      launch: await launch(),
      errorMessage: 'Selection unavailable',
      errorLog: 'Internal reference',
      log: 'Canceled',
    );
    final claims = await verify(response);
    expect(claims.containsKey(LtiDeepLinkingClaims.data), false);
    expect(claims[LtiDeepLinkingClaims.errorMessage], 'Selection unavailable');
    expect(claims[LtiDeepLinkingClaims.errorLog], 'Internal reference');
    expect(claims[LtiDeepLinkingClaims.log], 'Canceled');
  });
  test('claim validation rejects wrong target, nonce and role types', () async {
    for (final entry in [
      MapEntry(LtiClaims.targetLinkUri, 'https://evil.example'),
      const MapEntry('nonce', 'wrong'),
      MapEntry(LtiClaims.roles, null),
    ]) {
      await expectLater(
        launch(mutate: (claims) => claims[entry.key] = entry.value),
        throwsA(isA<LtiException>()),
      );
    }
  });
  test('invalid settings fail before exposing launch', () async {
    for (final entry in [
      const MapEntry('deep_link_return_url', 'javascript:alert(1)'),
      const MapEntry('accept_multiple', 'true'),
      const MapEntry('accept_lineitem', null),
      const MapEntry('accept_types', 'link'),
      const MapEntry('accept_presentation_document_targets', null),
    ]) {
      await expectLater(
        launch(options: settings()..[entry.key] = entry.value),
        throwsA(isA<LtiException>()),
      );
    }
    await expectLater(launch(options: {}), throwsA(isA<LtiException>()));
  });
  test(
    'selection enforces multiplicity, types, presentation and MIME',
    () async {
      final link = LtiContentItem.link(
        url: Uri.parse('https://tool.example/page'),
      );
      final request = await launch();
      await expectLater(
        tool.createDeepLinkingResponse(launch: request, items: [link, link]),
        throwsArgumentError,
      );
      final restricted = await launch(
        options: settings()..['accept_types'] = ['file'],
      );
      await expectLater(
        tool.createDeepLinkingResponse(launch: restricted, items: [link]),
        throwsArgumentError,
      );
      final target = await launch(
        options: settings()..['accept_presentation_document_targets'] = [],
      );
      await expectLater(
        tool.createDeepLinkingResponse(
          launch: target,
          items: [
            LtiContentItem.link(
              url: Uri.parse('https://tool.example'),
              properties: {'window': {}},
            ),
          ],
        ),
        throwsArgumentError,
      );
      final files = await launch(
        options: settings()
          ..['accept_media_types'] = 'image/*, application/pdf',
      );
      await expectLater(
        tool.createDeepLinkingResponse(
          launch: files,
          items: [
            LtiContentItem.file(
              url: Uri.parse('https://tool.example/file'),
              mediaType: 'text/html',
            ),
          ],
        ),
        throwsArgumentError,
      );
      await tool.createDeepLinkingResponse(
        launch: files,
        items: [
          LtiContentItem.file(
            url: Uri.parse('https://tool.example/file'),
            mediaType: 'image/png',
          ),
        ],
      );
    },
  );
  test(
    'all five types, presentation metadata and extensions serialize immutably',
    () async {
      final custom = {'exercise': '42'};
      final items = [
        LtiContentItem.ltiResourceLink(
          custom: custom,
          properties: {
            'iframe': {'width': 640, 'height': 480},
            'available': {'startDateTime': '2026-01-01T00:00:00Z'},
            'submission': {'endDateTime': '2026-12-31T23:59:59Z'},
            'https://tool.example/extension': {'enabled': true},
          },
        ),
        LtiContentItem.link(
          url: Uri.parse('https://tool.example'),
          properties: {
            'iframe': {'src': 'https://tool.example/embed'},
            'embed': {'html': '<p>Example</p>'},
            'icon': {'url': 'https://tool.example/icon', 'width': 32},
            'window': {
              'targetName': '_blank',
              'windowFeatures': 'resizable=yes',
            },
          },
        ),
        LtiContentItem.file(
          url: Uri.parse('https://tool.example/file'),
          mediaType: 'application/pdf',
          expiresAt: platform.now,
        ),
        LtiContentItem.html(html: '<strong>Content</strong>'),
        LtiContentItem.image(
          url: Uri.parse('https://tool.example/image'),
          width: 400,
          height: 200,
        ),
      ];
      custom['exercise'] = 'mutated';
      expect((items.first.toJson()['custom']! as Map)['exercise'], '42');
      expect(
        () => (items.first.toJson()['iframe']! as Map)['width'] = 1,
        throwsUnsupportedError,
      );
      final claims = await verify(
        await tool.createDeepLinkingResponse(
          launch: await launch(options: settings()..['accept_multiple'] = true),
          items: items,
        ),
      );
      expect((claims[LtiDeepLinkingClaims.contentItems]! as List).length, 5);
      expect(items[2].toJson().containsKey('mediaType'), false);
      final extension = LtiContentItem.fromJson({
        'type': 'https://tool.example/new-type',
        'value': 7,
      });
      await tool.createDeepLinkingResponse(
        launch: await launch(
          options: settings()..['accept_types'] = [extension.type],
        ),
        items: [extension],
      );
    },
  );
  test('invalid content metadata cannot be signed', () {
    for (final json in <Map<String, Object?>>[
      {'type': 'link', 'url': 'javascript:alert(1)'},
      {'type': 'image', 'url': 'https://tool.example', 'width': -1},
      {
        'type': 'ltiResourceLink',
        'custom': {'id': 1},
      },
      {
        'type': 'ltiResourceLink',
        'lineItem': {'scoreMaximum': 0},
      },
      {
        'type': 'ltiResourceLink',
        'iframe': {'src': 'https://evil.example'},
      },
      {
        'type': 'ltiResourceLink',
        'available': {
          'startDateTime': '2026-03-01T00:00:00Z',
          'endDateTime': '2026-01-01T00:00:00Z',
        },
      },
    ]) {
      expect(
        () => LtiContentItem.fromJson(json),
        throwsA(anyOf(isA<ArgumentError>(), isA<LtiException>())),
      );
    }
  });
}
