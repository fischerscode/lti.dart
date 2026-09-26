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
      origin: Uri.parse('https://tool.example'),
    );
  });
  tearDown(() => platform.client.close());

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
