import 'package:lti/lti.dart';
import 'package:lti_shelf/lti_shelf.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

// Shared simulator is test-only; neither published package imports test code.
import '../../lti/test/support/platform.dart';

void main() {
  late TestPlatform platform;
  late LtiShelf adapter;
  var launches = 0;
  setUp(() {
    platform = TestPlatform();
    launches = 0;
    adapter = LtiShelf(
      tool: platform.tool,
      publicOrigin: Uri.parse('https://tool.example'),
      onResourceLaunch: (request, launch) {
        launches++;
        expect(launch.user!.subject, 'student');
        return Response(
          303,
          headers: {
            'location': '/application',
            'set-cookie': [
              'app-session=example; Secure; HttpOnly',
              'preference=value; Secure',
            ],
          },
        );
      },
    );
  });
  tearDown(() => platform.client.close());

  Future<Response> login({String method = 'GET'}) async => adapter.handler(
    Request(
      method,
      Uri.parse('https://tool.example/lti/login').replace(
        queryParameters: method == 'GET' ? platform.loginParameters : null,
      ),
      headers: method == 'POST'
          ? {'content-type': 'application/x-www-form-urlencoded'}
          : null,
      body: method == 'POST'
          ? Uri(queryParameters: platform.loginParameters).query
          : null,
    ),
  );

  Future<Request> callback(
    Response response, {
    bool includeCookie = true,
    bool invalidAudience = false,
  }) async {
    final redirect = Uri.parse(response.headers['location']!);
    final query = redirect.queryParameters;
    final login = LtiLoginRedirect(
      uri: redirect,
      state: query['state']!,
      browserBinding: '',
      expiresAt: platform.now,
    );
    final claims = platform.claims(login);
    if (invalidAudience) claims['aud'] = 'wrong-client';
    final token = platform.sign(claims);
    return Request(
      'POST',
      Uri.parse('https://tool.example/lti/launch'),
      headers: {
        'content-type': 'application/x-www-form-urlencoded; charset=utf-8',
        if (includeCookie)
          'cookie': response.headers['set-cookie']!.split(';').first,
      },
      body: Uri(queryParameters: {'state': login.state, 'id_token': token})
          .query,
    );
  }

  for (final partitioned in [false, true]) {
    test('cookie partitioning $partitioned applies to set and clear', () async {
      adapter = LtiShelf(
        tool: platform.tool,
        publicOrigin: Uri.parse('https://tool.example'),
        partitionedCookies: partitioned,
        onResourceLaunch: (_, _) => Response.ok('verified'),
      );
      final start = await login();
      expect(
        start.headers['set-cookie']!.contains('; Partitioned'),
        partitioned,
      );
      final response = await adapter.handler(await callback(start));
      expect(response.statusCode, 200);
      expect(response.headers['set-cookie'], contains('Max-Age=0'));
      expect(
        response.headers['set-cookie']!.contains('; Partitioned'),
        partitioned,
      );
      final missing = await adapter.handler(
        await callback(await login(), includeCookie: false),
      );
      expect(missing.statusCode, 400);
    });
  }

  test('invalid audience returns 401 without dispatching a launch', () async {
    final result = await adapter.handler(
      await callback(await login(), invalidAudience: true),
    );
    expect(result.statusCode, 401);
    expect(launches, 0);
  });

  test(
    'OIDC error consumes a bound transaction without reflecting descriptions',
    () async {
      final start = await login();
      final state = Uri.parse(start.headers['location']!)
          .queryParameters['state']!;
      final request = Request(
        'POST',
        Uri.parse('https://tool.example/lti/launch'),
        headers: {
          'content-type': 'application/x-www-form-urlencoded',
          'cookie': start.headers['set-cookie']!.split(';').first,
        },
        body: Uri(
          queryParameters: {
            'state': state,
            'error': 'login_required',
            'error_description': 'private platform diagnostic',
          },
        ).query,
      );
      final result = await adapter.handler(request);
      expect(result.statusCode, 401);
      expect(
        await result.readAsString(),
        'LTI request rejected: authenticationFailed',
      );
      expect(platform.requests, 0);
      expect((await adapter.handler(await callback(start))).statusCode, 400);
      expect(launches, 0);
    },
  );

  test('OIDC error without browser binding cannot consume a login', () async {
    final start = await login();
    final state = Uri.parse(start.headers['location']!)
        .queryParameters['state']!;
    final result = await adapter.handler(
      Request(
        'POST',
        Uri.parse('https://tool.example/lti/launch'),
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: Uri(queryParameters: {'state': state, 'error': 'login_required'})
            .query,
      ),
    );
    expect(result.statusCode, 400);
    expect((await adapter.handler(await callback(start))).statusCode, 303);
  });

  for (final method in ['GET', 'POST']) {
    test(
      '$method login through signed callback preserves application cookies',
      () async {
        final response = await login(method: method);
        expect(response.statusCode, 303);
        expect(
          response.headers['set-cookie'],
          contains('Secure; HttpOnly; SameSite=None'),
        );
        expect(response.headers['set-cookie'], startsWith('__Host-lti-'));
        expect(response.headers['cache-control'], 'no-store');
        final result = await adapter.handler(await callback(response));
        expect(result.statusCode, 303);
        expect(result.headers['location'], '/application');
        expect(result.headersAll['set-cookie'], hasLength(3));
        expect(result.headersAll['set-cookie']!.last, contains('Max-Age=0'));
        expect(result.headers['cache-control'], 'no-store');
        expect(launches, 1);
      },
    );
  }

  test(
    'missing browser cookie fails closed without calling application',
    () async {
      final response = await adapter.handler(
        await callback(await login(), includeCookie: false),
      );
      expect(response.statusCode, 400);
      expect(await response.readAsString(), contains('invalidState'));
      expect(launches, 0);
      expect(platform.requests, 0);
    },
  );

  test('replayed form cannot create a second application session', () async {
    final start = await login();
    expect((await adapter.handler(await callback(start))).statusCode, 303);
    expect((await adapter.handler(await callback(start))).statusCode, 400);
    expect(launches, 1);
  });

  test('parallel browser tabs have independent binding cookies', () async {
    final a = await login();
    final b = await login();
    expect(
      a.headers['set-cookie']!.split('=').first,
      isNot(b.headers['set-cookie']!.split('=').first),
    );
    expect((await adapter.handler(await callback(a))).statusCode, 303);
    expect((await adapter.handler(await callback(b))).statusCode, 303);
    expect(launches, 2);
  });

  test(
    'rejects duplicate form parameters and inappropriate content types',
    () async {
      for (final body in [
        'state=a&state=b&id_token=x',
        'state=a&id_token=x&id_token=y',
      ]) {
        final response = await adapter.handler(
          Request(
            'POST',
            Uri.parse('https://tool.example/lti/launch'),
            headers: {'content-type': 'application/x-www-form-urlencoded'},
            body: body,
          ),
        );
        expect(response.statusCode, 400);
      }
      final response = await adapter.handler(
        Request(
          'POST',
          Uri.parse('https://tool.example/lti/launch'),
          headers: {'content-type': 'application/json'},
          body: '{}',
        ),
      );
      expect(response.statusCode, 400);
      expect(launches, 0);
    },
  );

  test('limits streamed request bodies', () async {
    final response = await adapter.handler(
      Request(
        'POST',
        Uri.parse('https://tool.example/lti/login'),
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: 'a' * 131073,
      ),
    );
    expect(response.statusCode, 400);
  });

  test('wrong methods are rejected and unknown routes return 404', () async {
    final response = await adapter.handler(
      Request('GET', Uri.parse('https://tool.example/lti/launch')),
    );
    expect(response.statusCode, 405);
    expect(response.headers['allow'], 'POST');
    expect(
      (await adapter.handler(
        Request('GET', Uri.parse('https://tool.example/other')),
      )).statusCode,
      404,
    );
  });

  test(
    'refuses callback configuration that differs from the registration',
    () async {
      adapter = LtiShelf(
        tool: platform.tool,
        publicOrigin: Uri.parse('https://wrong.example'),
        onResourceLaunch: (_, _) => Response.ok('never'),
      );
      expect((await login()).statusCode, 400);
    },
  );
}
