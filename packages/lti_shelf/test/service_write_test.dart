import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lti/lti.dart';
import 'package:test/test.dart';
import 'package:shelf/shelf.dart';

import '../../lti/test/support/platform.dart';
import '../example/service_write_test.dart';

void main() {
  test('write UI binds explicit actions to the instructor and its own test item', () async {
    final platform = TestPlatform();
    addTearDown(platform.client.close);
    final old = platform.registration;
    final registration = LtiRegistration(
      issuer: old.issuer,
      clientId: old.clientId,
      deploymentIds: old.deploymentIds,
      targetLinkUris: old.targetLinkUris,
      authenticationEndpoint: old.authenticationEndpoint,
      jwksUri: old.jwksUri,
      redirectUri: old.redirectUri,
      tokenEndpoint: Uri.parse('https://platform.example/token'),
    );
    final tool = LtiTool(
      registrations: MemoryLtiRegistrationStore([registration]),
      transactions: MemoryLtiTransactionStore(),
      tokenVerifier: platform.verifier,
      clock: () => platform.now,
    );
    Future<LtiResourceLaunch> launch(String role) async {
      final login = await tool.beginLogin(
        LtiLoginRequest.fromParameters(platform.loginParameters),
      );
      return await tool.completeResourceLaunch(
        state: login.state,
        browserBinding: login.browserBinding,
        idToken: platform.sign({
          ...platform.claims(login),
          LtiClaims.roles: [role],
          LtiServiceClaims.nrps: {
            'service_versions': ['2.0'],
            'context_memberships_url': 'https://platform.example/members',
          },
          LtiServiceClaims.ags: {
            'scope': [
              LtiServiceScopes.lineItem,
              LtiServiceScopes.score,
              LtiServiceScopes.resultReadonly,
            ],
            'lineitems': 'https://platform.example/items',
          },
        }),
      );
    }

    final paths = <String>[];
    Map<String, Object?>? item;
    final scores = <Map<String, dynamic>>[];
    var ambiguousCreate = false;
    final client = MockClient((r) async {
      paths.add('${r.method} ${r.url.path}');
      http.Response json(Object data, String media, [int status = 200]) =>
          http.Response(
            jsonEncode(data),
            status,
            headers: {'content-type': media},
          );
      if (r.url.path == '/token') {
        return json({
          'access_token': 'SECRET',
          'token_type': 'Bearer',
          'expires_in': 3600,
        }, 'application/json');
      }
      if (r.url.path == '/members') {
        return json({
          'id': r.url.toString(),
          'context': {'id': 'course'},
          'members': [
            {
              'user_id': 'test-learner',
              'name': '<script>name</script>',
              'roles': ['Learner'],
            },
            {
              'user_id': 'teacher',
              'roles': ['Instructor'],
            },
          ],
        }, LtiNrpsClient.mediaType);
      }
      if (r.method == 'POST' && r.url.path == '/items') {
        item = {
          ...jsonDecode(r.body) as Map<String, dynamic>,
          'id': 'https://platform.example/items/test',
        };
        if (ambiguousCreate) return http.Response('PRIVATE', 500);
        return json(item!, LtiAgsClient.lineItemMediaType, 201);
      }
      if (r.url.path == '/items/test/scores') {
        scores.add(jsonDecode(r.body) as Map<String, dynamic>);
        return http.Response('', 204);
      }
      if (r.url.path == '/items/test/results') {
        expect(r.url.queryParameters['user_id'], 'test-learner');
        return json([
          {
            'id': 'https://platform.example/result',
            'scoreOf': 'https://platform.example/items/test',
            'userId': 'test-learner',
            'resultScore': scores.last['scoreGiven'],
            'resultMaximum': 100,
          },
        ], LtiAgsClient.resultsMediaType);
      }
      expect(r.url.path, '/items/test');
      if (r.method == 'DELETE') return http.Response('', 204);
      if (r.method == 'PUT') item = jsonDecode(r.body) as Map<String, dynamic>;
      return json(item!, LtiAgsClient.lineItemMediaType);
    });
    addTearDown(client.close);
    final oauth = LtiOAuthClient(
      client: client,
      signer: LtiJwtSigner(
        keys: MemoryLtiSigningKeyProvider(
          RsaLtiSigningKey.fromJwk(TestPlatform.key.toJson()),
        ),
      ),
    );
    LtiServiceClient services(LtiResourceLaunch launch) => LtiServiceClient(
      launch: launch,
      oauth: oauth,
      client: client,
      allowedOrigins: {Uri.parse('https://platform.example')},
    );
    final teacher = await launch(LtiRoles.instructor);
    var now = DateTime.now();
    final ui = ServiceWriteTest(
      origin: Uri.parse('https://tool.example'),
      servicesFor: services,
      clock: () => now,
    );
    final request = Request(
      'POST',
      Uri.parse('https://tool.example/lti/launch'),
    );
    var response = ui.begin(request, teacher);
    expect(paths, isEmpty); // Launch alone never reads or writes services.
    final cookie = response.headers['set-cookie']!.split(';').first;
    var page = await response.readAsString();
    String field(String name) =>
        RegExp('name="$name" value="([^"<>]+)"').firstMatch(page)!.group(1)!;
    Map<String, String> form(String action) => {
      'session': field('session'),
      'csrf': field('csrf'),
      'action': action,
    };
    Future<Response> send(
      Map<String, String> fields, {
      String? binding,
      String origin = 'https://tool.example',
    }) => ui.handle(
      Request(
        'POST',
        Uri.parse('https://tool.example${ServiceWriteTest.path}'),
        headers: {
          'origin': origin,
          'cookie': binding ?? cookie,
          'content-type': 'application/x-www-form-urlencoded',
        },
        body: Uri(queryParameters: fields).query,
      ),
    );
    Future<void> act(
      String action, [
      Map<String, String> extra = const {},
    ]) async {
      response = await send({...form(action), ...extra});
      expect(response.statusCode, 200);
      page = await response.readAsString();
      expect(page, isNot(contains('SECRET')));
      expect(page, isNot(contains('PRIVATE')));
    }

    final create = form('create');
    expect((await send(create, binding: '')).statusCode, 403);
    expect(
      (await send(create, origin: 'https://evil.example')).statusCode,
      403,
    );
    expect((await send({...create, 'csrf': 'wrong'})).statusCode, 403);
    expect(paths, isEmpty);
    await act('create');
    expect(page, contains('Testspalte erstellt'));
    expect((await send(create)).statusCode, 403);
    await act('create'); // Even a fresh token cannot create twice.
    expect(paths.where((p) => p == 'POST /items'), hasLength(1));
    await act('read');
    await act('update');
    expect(item!['label'], endsWith('– geändert'));
    await act('roster');
    expect(page, contains('1 aktive Lernendenkonten'));
    expect(page, contains('&lt;script&gt;'));
    final learner = RegExp('<option value="([^"<>]+)">')
        .firstMatch(page)!
        .group(1)!;
    await act('score', {'learner': 'arbitrary-id', 'confirm': 'yes'});
    await act('score', {'learner': learner});
    expect(scores, isEmpty);
    await act('score', {'learner': learner, 'confirm': 'yes'});
    expect(scores.single['userId'], 'test-learner');
    expect(scores.single['scoreGiven'], 80);
    await act('results');
    expect(page, contains('Ergebnis: 80&#47;100'));
    await act('delete'); // Must confirm deletion while a score may exist.
    expect(paths.where((p) => p.startsWith('DELETE')), isEmpty);
    await act('clear');
    expect(scores.last['scoreGiven'], isNull);
    expect(
      DateTime.parse(scores.last['timestamp'] as String)
          .isAfter(DateTime.parse(scores.first['timestamp'] as String)),
      isTrue,
    );
    await act('results');
    expect(page, contains('Ergebnis: leer&#47;100'));
    await act('delete');
    expect(page, contains('Eigene Testspalte gelöscht'));
    await act('delete');
    expect(paths.where((p) => p == 'DELETE /items/test'), hasLength(1));
    expect(ui.begin(request, await launch(LtiRoles.learner)).statusCode, 403);
    now = now.add(const Duration(hours: 2));
    expect((await send(form('read'))).statusCode, 403);

    // An ambiguous create is not automatically repeated, even with a new form.
    response = ui.begin(request, teacher);
    final secondCookie = response.headers['set-cookie']!.split(';').first;
    page = await response.readAsString();
    ambiguousCreate = true;
    response = await send(form('create'), binding: secondCookie);
    page = await response.readAsString();
    expect(page, contains('Erstellung unklar'));
    final count = paths.length;
    response = await send(form('create'), binding: secondCookie);
    expect(paths.length, count);
  });
}
