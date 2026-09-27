import 'dart:convert';
import 'dart:io';

import 'package:lti/lti.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../../lti/test/support/platform.dart';
import '../example/bycs_server.dart';

void main() {
  late TestPlatform platform;
  late Handler handler;
  setUp(() {
    platform = TestPlatform();
    handler = integrationHandler(
      tool: platform.tool,
      platformOrigin: Uri.parse('https://platform.example'),
      origin: Uri.parse('https://tool.example'),
    );
  });
  tearDown(() => platform.client.close());

  test(
    'wire response allows only trusted framing without Dart SAMEORIGIN',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.close(force: true);
      });
      serveIntegration(server, handler);
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/health'),
      );
      final response = await request.close();
      expect(response.headers.value('x-frame-options'), isNull);
      expect(
        response.headers.value('content-security-policy'),
        "frame-ancestors 'self' https://platform.example",
      );
      await response.drain<void>();
    },
  );

  test(
    'JWKS diagnostics preserve publication and redact request data',
    () async {
      final messages = <String>[];
      final signingTool = LtiTool(
        registrations: platform.tool.registrations,
        transactions: platform.tool.transactions,
        tokenVerifier: platform.verifier,
        signer: LtiJwtSigner(
          keys: MemoryLtiSigningKeyProvider(
            RsaLtiSigningKey.fromJwk(TestPlatform.key.toJson()),
          ),
        ),
      );
      final diagnosticHandler = integrationHandler(
        tool: signingTool,
        origin: Uri.parse('https://tool.example'),
        platformOrigin: Uri.parse('https://platform.example'),
        onJwksRequest: messages.add,
      );
      for (final probe in ['bycs', 'local', 'PRIVATE_QUERY']) {
        final response = await diagnosticHandler(
          Request(
            'GET',
            Uri.parse(
              'https://tool.example/lti/jwks?probe=$probe&secret=PRIVATE_TOKEN',
            ),
            headers: {
              'cookie': 'PRIVATE_COOKIE',
              'user-agent': 'PRIVATE_AGENT',
            },
          ),
        );
        expect(response.statusCode, 200);
        final keys =
            (jsonDecode(await response.readAsString()) as Map)['keys'] as List;
        expect(keys, hasLength(1));
        expect((keys.single as Map).containsKey('d'), isFalse);
        expect(response.headers['cache-control'], 'public, max-age=300');
      }
      expect(messages, hasLength(3));
      expect(messages[0], contains('method=GET probe=bycs status=200'));
      expect(messages[1], contains('method=GET probe=local status=200'));
      expect(messages[2], contains('method=GET probe=other status=200'));
      expect(messages.join(), isNot(contains('PRIVATE')));
      await diagnosticHandler(
        Request('GET', Uri.parse('https://tool.example/health')),
      );
      expect(messages, hasLength(3));
      final rejected = await diagnosticHandler(
        Request(
          'POST',
          Uri.parse('https://tool.example/lti/jwks?probe=bycs&probe=PRIVATE'),
          body: 'PRIVATE_BODY',
        ),
      );
      expect(rejected.statusCode, 405);
      expect(messages.last, contains('method=OTHER probe=other status=405'));
      expect(messages.join(), isNot(contains('PRIVATE')));
      final head = await diagnosticHandler(
        Request('HEAD', Uri.parse('https://tool.example/lti/jwks')),
      );
      expect(await head.readAsString(), isEmpty);
      expect(messages.last, contains('method=HEAD probe=none status=200'));
      final brokenObserver = integrationHandler(
        tool: signingTool,
        origin: Uri.parse('https://tool.example'),
        platformOrigin: Uri.parse('https://platform.example'),
        onJwksRequest: (_) => throw StateError('observer failed'),
      );
      expect(
        (await brokenObserver(
          Request('GET', Uri.parse('https://tool.example/lti/jwks')),
        )).statusCode,
        200,
      );
    },
  );

  test('health and direct activity never claim a verified launch', () async {
    for (final path in ['/health', '/activity']) {
      final response = await handler(
        Request('GET', Uri.parse('https://tool.example$path')),
      );
      expect(response.statusCode, 200);
      expect(response.headers['cache-control'], 'no-store');
      expect(
        await response.readAsString(),
        isNot(contains('resource launch verified.')),
      );
    }
    expect(
      (await handler(
        Request('POST', Uri.parse('https://tool.example/activity')),
      )).statusCode,
      405,
    );
  });

  test(
    'only a validated callback shows success without personal data',
    () async {
      final login = await platform.begin();
      final claims = platform.claims(login)
        ..['name'] = 'PRIVATE_NAME'
        ..['email'] = 'PRIVATE_EMAIL';
      Request callback() => Request(
        'POST',
        Uri.parse('https://tool.example/lti/launch'),
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
      );
      final response = await handler(callback());
      final body = await response.readAsString();
      expect(response.statusCode, 200);
      expect(body, contains('LTI 1.3 resource launch verified.'));
      expect(body, isNot(contains('PRIVATE_')));
      expect(body, isNot(contains('student')));
      expect((await handler(callback())).statusCode, 400);
    },
  );

  test('foreign issuer cannot begin a login', () async {
    final response = await handler(
      Request(
        'GET',
        Uri.parse('https://tool.example/lti/login').replace(
          queryParameters: {
            ...platform.loginParameters,
            'iss': 'https://foreign.example',
          },
        ),
      ),
    );
    expect(response.statusCode, 400);
    expect(response.headers.containsKey('location'), false);
  });
}
