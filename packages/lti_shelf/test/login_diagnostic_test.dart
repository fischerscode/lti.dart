import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../../../tool/lti_login_diagnostic.dart';

void main() {
  late HttpServer server;
  late Uri url;
  late http.Client client;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = Uri.parse('http://127.0.0.1:${server.port}/lti/login');
    client = http.Client();
    server.listen((request) async {
      await handleLoginDiagnostic(request);
      await request.response.close();
    });
  });
  tearDown(() async {
    client.close();
    await server.close(force: true);
  });
  final values = {
    'iss': 'https://platform.example',
    'client_id': 'client',
    'lti_deployment_id': 'deployment',
    'login_hint': 'SECRET_LOGIN_HINT',
    'lti_message_hint': 'SECRET_MESSAGE_HINT',
    'id_token': 'SECRET_TOKEN',
  };
  for (final method in ['GET', 'POST']) {
    test(
      '$method shows only allowlisted metadata, never credentials',
      () async {
        final response = method == 'GET'
            ? await client.get(url.replace(queryParameters: values))
            : await client.post(url, body: values);
        expect(response.statusCode, 200);
        expect(response.headers['cache-control'], 'no-store');
        expect(response.headers['referrer-policy'], 'no-referrer');
        expect(response.body, contains('NOT an authenticated launch'));
        expect(response.body, contains('"client_id": "client"'));
        expect(response.body, contains('"iss": "https://platform.example"'));
        expect(response.body, contains('"lti_deployment_id": "deployment"'));
        expect(response.body, isNot(contains('SECRET_')));
      },
    );
  }
  test('rejects duplicate fields within and across query and body', () async {
    expect(
      (await client.get(url.replace(query: 'iss=a&iss=b'))).statusCode,
      400,
    );
    expect(
      (await client.post(
        url.replace(query: 'client_id=a'),
        body: {'client_id': 'b'},
      )).statusCode,
      400,
    );
  });
  test('rejects unsupported methods and non-form bodies', () async {
    expect((await client.put(url)).statusCode, 405);
    expect(
      (await client.post(
        url,
        headers: {'content-type': 'application/json'},
        body: '{}',
      )).statusCode,
      415,
    );
  });
  test('bounds query and request body size', () async {
    expect(
      (await client.get(url.replace(query: 'iss=${'x' * 17000}'))).statusCode,
      400,
    );
    expect(
      (await client.post(url, body: {'iss': 'x' * 17000})).statusCode,
      400,
    );
  });
  test('escapes control characters and reports missing metadata', () async {
    final response = await client.get(
      url.replace(queryParameters: {'client_id': 'a\nb'}),
    );
    expect(response.body, contains(r'a\nb'));
    expect(response.body, isNot(contains('"iss"')));
  });
}
