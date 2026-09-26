import 'dart:convert';

import 'package:jose/jose.dart';
import 'package:lti/lti.dart';
import 'package:lti_shelf/lti_shelf.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../../lti/test/support/platform.dart';

void main() {
  late TestPlatform platform;
  late MemoryLtiSigningKeyProvider keys;
  late LtiJwtSigner signer;
  late LtiShelf adapter;
  setUp(() {
    platform = TestPlatform();
    keys = MemoryLtiSigningKeyProvider(
      RsaLtiSigningKey.fromJwk(TestPlatform.key.toJson()),
    );
    signer = LtiJwtSigner(keys: keys, clock: () => platform.now);
    adapter = LtiShelf(
      tool: LtiTool(
        registrations: MemoryLtiRegistrationStore([platform.registration]),
        transactions: MemoryLtiTransactionStore(),
        tokenVerifier: platform.verifier,
        signer: signer,
        clock: () => platform.now,
      ),
      publicOrigin: Uri.parse('https://tool.example'),
      onResourceLaunch: (_, _) => Response.ok('verified'),
    );
  });
  tearDown(() => platform.client.close());

  Future<Response> request([String method = 'GET']) async => adapter.handler(
    Request(method, Uri.parse('https://tool.example/lti/jwks')),
  );

  Future<JsonWebKeyStore> publishedKeys() async {
    final response = await request();
    final json =
        jsonDecode(await response.readAsString()) as Map<String, Object?>;
    return JsonWebKeyStore()..addKeySet(JsonWebKeySet.fromJson(json));
  }

  Future<String> sign() => signer.signMessage(
    registration: platform.registration,
    deploymentId: 'deployment',
    messageType: 'LtiDeepLinkingResponse',
  );

  test('unauthenticated JWKS endpoint contains only public material', () async {
    final response = await request();
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], 'application/jwk-set+json');
    expect(response.headers['cache-control'], 'public, max-age=300');
    expect(response.headers, isNot(contains('set-cookie')));
    final body = await response.readAsString();
    final json = jsonDecode(body) as Map<String, Object?>;
    final key = (json['keys']! as List).single as Map<String, Object?>;
    expect(key.keys.toSet(), {'kty', 'kid', 'alg', 'use', 'key_ops', 'n', 'e'});
    expect(body, isNot(contains(TestPlatform.key.toJson()['d'])));
    final token = await sign();
    expect(
      await JsonWebSignature.fromCompactSerialization(token)
          .verify(await publishedKeys()),
      isTrue,
    );
    expect(platform.requests, 0);
  });

  test('HEAD has GET metadata with no body; POST returns 405', () async {
    final get = await request();
    final head = await request('HEAD');
    expect(head.statusCode, 200);
    expect(head.headers['content-length'], get.headers['content-length']);
    expect(await head.readAsString(), isEmpty);
    final post = await request('POST');
    expect(post.statusCode, 405);
    expect(post.headers['allow'], 'GET, HEAD');
  });

  test('rotation exposes both public keys until explicit retirement', () async {
    final oldToken = await sign();
    final next = RsaLtiSigningKey.fromJwk(TestPlatform.otherKey.toJson());
    keys.publish(next.publicKey);
    keys.activate(next);
    final newToken = await sign();
    final overlapping = await publishedKeys();
    expect(
      await JsonWebSignature.fromCompactSerialization(oldToken)
          .verify(overlapping),
      isTrue,
    );
    expect(
      await JsonWebSignature.fromCompactSerialization(newToken)
          .verify(overlapping),
      isTrue,
    );
    keys.retire(TestPlatform.key.keyId!);
    final retired = await publishedKeys();
    expect(
      await JsonWebSignature.fromCompactSerialization(oldToken).verify(retired),
      isFalse,
    );
    expect(
      await JsonWebSignature.fromCompactSerialization(newToken).verify(retired),
      isTrue,
    );
  });

  test('JWKS route is absent when signing is not configured', () async {
    final unsigned = LtiShelf(
      tool: platform.tool,
      publicOrigin: Uri.parse('https://tool.example'),
      onResourceLaunch: (_, _) => Response.ok('verified'),
    );
    expect(
      (await unsigned.handler(
        Request('GET', Uri.parse('https://tool.example/lti/jwks')),
      )).statusCode,
      404,
    );
  });

  test('rejects conflicting routes and negative cache lifetime', () {
    expect(
      () => LtiShelf(
        tool: platform.tool,
        publicOrigin: Uri.parse('https://tool.example'),
        jwksPath: '/lti/login',
        onResourceLaunch: (_, _) => Response.ok('never'),
      ),
      throwsArgumentError,
    );
    expect(
      () => LtiShelf(
        tool: platform.tool,
        publicOrigin: Uri.parse('https://tool.example'),
        jwksCacheLifetime: const Duration(seconds: -1),
        onResourceLaunch: (_, _) => Response.ok('never'),
      ),
      throwsArgumentError,
    );
  });
}
