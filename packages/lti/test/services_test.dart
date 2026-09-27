import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lti/lti.dart';
import 'package:test/test.dart';

import 'support/platform.dart';

void main() {
  late TestPlatform platform;
  late LtiTool tool;
  late LtiRegistration registration;
  late LtiOAuthClient oauth;
  late http.Client httpClient;
  late Future<http.Response> Function(http.Request) respond;
  final requests = <http.Request>[];
  final itemUri = Uri.parse('https://platform.example/items/1?course=42');
  Map<String, Object?> item() => {
    'id': itemUri.toString(),
    'label': 'Test',
    'scoreMaximum': 10,
    'resourceLinkId': 'resource',
    'https://tool.example/extension': {'keep': true},
  };
  http.Response json(
    Object data,
    String media, {
    int status = 200,
    String? link,
  }) => http.Response(
    jsonEncode(data),
    status,
    headers: {'content-type': media, 'link': ?link},
  );
  Map<String, Object?> capabilities({Set<String>? scopes}) => {
    LtiServiceClaims.ags: {
      'lineitems': 'https://platform.example/items?course=42',
      'lineitem': itemUri.toString(),
      'scope':
          (scopes ??
                  {
                    LtiServiceScopes.lineItem,
                    LtiServiceScopes.lineItemReadonly,
                    LtiServiceScopes.score,
                    LtiServiceScopes.resultReadonly,
                  })
              .toList(),
    },
    LtiServiceClaims.nrps: {
      'context_memberships_url': 'https://platform.example/members?course=42',
      'service_versions': ['2.0'],
    },
  };
  setUp(() {
    platform = TestPlatform();
    requests.clear();
    final old = platform.registration;
    registration = LtiRegistration(
      issuer: old.issuer,
      clientId: old.clientId,
      authenticationEndpoint: old.authenticationEndpoint,
      jwksUri: old.jwksUri,
      redirectUri: old.redirectUri,
      deploymentIds: old.deploymentIds,
      targetLinkUris: old.targetLinkUris,
      tokenEndpoint: Uri.parse('https://platform.example/token'),
    );
    tool = LtiTool(
      registrations: MemoryLtiRegistrationStore([registration]),
      transactions: MemoryLtiTransactionStore(),
      tokenVerifier: platform.verifier,
      clock: () => platform.now,
    );
    respond = (_) async => json(item(), LtiAgsClient.lineItemMediaType);
    httpClient = MockClient((request) async {
      requests.add(request);
      expect(request.followRedirects, isFalse);
      if (request.url.path == '/token') {
        expect(request.headers.containsKey('authorization'), isFalse);
        return json({
          'access_token': 'SECRET',
          'token_type': 'Bearer',
          'expires_in': 3600,
          'scope': request.bodyFields['scope'],
        }, 'application/json');
      }
      expect(request.headers['authorization'], 'Bearer SECRET');
      return respond(request);
    });
    oauth = LtiOAuthClient(
      client: httpClient,
      signer: LtiJwtSigner(
        keys: MemoryLtiSigningKeyProvider(
          RsaLtiSigningKey.fromJwk(TestPlatform.key.toJson()),
        ),
        clock: () => platform.now,
      ),
      clock: () => platform.now,
    );
  });
  tearDown(() {
    platform.client.close();
    httpClient.close();
  });

  Future<LtiLaunch> launch([Map<String, Object?>? additions]) async {
    final login = await tool.beginLogin(
      LtiLoginRequest.fromParameters(platform.loginParameters),
    );
    return tool.completeLaunch(
      state: login.state,
      browserBinding: login.browserBinding,
      idToken: platform.sign({...platform.claims(login), ...?additions}),
    );
  }

  Future<LtiServiceClient> services({
    Map<String, Object?>? claims,
    int maxPages = 100,
    int maxResponseBytes = 1048576,
    Duration timeout = const Duration(seconds: 10),
  }) async => LtiServiceClient(
    launch: await launch(claims ?? capabilities()),
    oauth: oauth,
    client: httpClient,
    allowedOrigins: {Uri.parse('https://platform.example')},
    maxPages: maxPages,
    maxResponseBytes: maxResponseBytes,
    timeout: timeout,
  );
  Iterable<http.Request> getCalls() =>
      requests.where((r) => r.url.path != '/token');
  Matcher failure(LtiServiceErrorCode code) =>
      throwsA(isA<LtiServiceException>().having((e) => e.code, 'code', code));

  test('parses immutable capabilities only after verified launch', () async {
    final verified = await launch(capabilities());
    expect(verified.ags!.lineItem, itemUri);
    expect(verified.nrps!.versions, ['2.0']);
    expect(() => verified.ags!.scopes.add('extra'), throwsUnsupportedError);
    for (final invalid in [
      {LtiServiceClaims.ags: null},
      {
        LtiServiceClaims.ags: {'scope': 'wrong'},
      },
      {
        LtiServiceClaims.nrps: {
          'context_memberships_url': 'http://evil',
          'service_versions': ['2.0'],
        },
      },
    ]) {
      await expectLater(launch(invalid), throwsA(isA<LtiException>()));
    }
  });

  test(
    'line item CRUD uses correct methods, media and least available scope',
    () async {
      final api = (await services()).ags;
      final current = await api.getLineItem();
      expect(
        requests.first.bodyFields['scope'],
        LtiServiceScopes.lineItemReadonly,
      );
      expect(current.json['https://tool.example/extension'], {'keep': true});
      respond = (r) async {
        expect(r.headers['accept'], LtiAgsClient.lineItemMediaType);
        expect(r.headers['content-type'], LtiAgsClient.lineItemMediaType);
        expect(jsonDecode(r.body)['label'], 'New');
        return json(
          {...item(), 'label': 'New'},
          LtiAgsClient.lineItemMediaType,
          status: r.method == 'POST' ? 201 : 200,
        );
      };
      await api.createLineItem(LtiLineItem(label: 'New', scoreMaximum: 20));
      final replacement = LtiLineItem.fromJson({
        ...current.json,
        'label': 'New',
      });
      await api.updateLineItem(current, replacement);
      final before = requests.length;
      await expectLater(
        api.updateLineItem(
          current,
          LtiLineItem(label: 'New', scoreMaximum: 10),
        ),
        throwsArgumentError,
      );
      expect(requests, hasLength(before));
      respond = (_) async => http.Response('', 204);
      await api.deleteLineItem();
      expect(getCalls().map((r) => r.method), ['GET', 'POST', 'PUT', 'DELETE']);
      expect(
        requests.where((r) => r.url.path == '/token').last.bodyFields['scope'],
        LtiServiceScopes.lineItem,
      );
    },
  );

  test('score and results append paths and retain endpoint query', () async {
    final api = (await services()).ags;
    respond = (r) async {
      expect(r.url.path, '/items/1/scores');
      expect(r.url.queryParameters, {'course': '42'});
      expect(r.headers['content-type'], LtiAgsClient.scoreMediaType);
      final score = jsonDecode(r.body) as Map;
      expect(score['scoreGiven'], 11); // Extra credit is permitted.
      expect(score['scoreMaximum'], 10);
      expect(score['activityProgress'], 'Completed');
      expect(score['timestamp'], '2026-09-26T12:00:00.000Z');
      return http.Response('', 204);
    };
    await api.publishScore(
      LtiScore(
        userId: 'student',
        timestamp: platform.now,
        activityProgress: LtiActivityProgress.completed,
        gradingProgress: LtiGradingProgress.fullyGraded,
        scoreGiven: 11,
        scoreMaximum: 10,
      ),
    );
    respond = (r) async {
      expect(r.url.path, '/items/1/results');
      expect(r.url.queryParameters, {
        'course': '42',
        'user_id': 'student',
        'limit': '2',
      });
      return json([
        {
          'id': 'https://platform.example/results/1',
          'scoreOf': itemUri.toString(),
          'userId': 'student',
          'resultScore': 11,
          'resultMaximum': 10,
        },
      ], LtiAgsClient.resultsMediaType);
    };
    final results = await api.results(userId: 'student', limit: 2);
    expect(results.items.single.resultScore, 11);
    expect(results.items.single.scoreOf, itemUri);
  });

  test('pagination keeps next URL intact including commas and ignores unrelated relations', () async {
    final api = (await services()).ags;
    var page = 0;
    respond = (r) async {
      if (page++ == 0) {
        expect(r.url.queryParameters['resource_link_id'], 'resource');
        return json(
          [item()],
          LtiAgsClient.lineItemsMediaType,
          link: '</items?cursor=a,b>; title="page, two"; rel="next", <https://elsewhere.example/>; rel="help"',
        );
      }
      expect(r.url.toString(), 'https://platform.example/items?cursor=a,b');
      return json([item()], LtiAgsClient.lineItemsMediaType);
    };
    expect(
      await api.allLineItems(resourceLinkId: 'resource').toList(),
      hasLength(2),
    );
  });

  test('blocks endpoint and pagination credential exfiltration', () async {
    final bad = capabilities();
    (bad[LtiServiceClaims.ags] as Map)['lineitems'] =
        'https://evil.example/items';
    final api = (await services(claims: bad)).ags;
    await expectLater(
      () => api.lineItems(),
      failure(LtiServiceErrorCode.untrustedDestination),
    );
    expect(requests, isEmpty);
    final good = (await services()).ags;
    respond = (_) async => json(
      [],
      LtiAgsClient.lineItemsMediaType,
      link: '<https://evil.example/page>; rel="next"',
    );
    await expectLater(
      good.allLineItems().toList(),
      failure(LtiServiceErrorCode.untrustedDestination),
    );
    expect(getCalls(), hasLength(1));
  });

  test(
    'bounds page count and rejects loops and ambiguous next links',
    () async {
      final api = (await services(maxPages: 1)).ags;
      respond = (_) async => json(
        [],
        LtiAgsClient.lineItemsMediaType,
        link: '</items?page=2>; rel=next',
      );
      await expectLater(
        api.allLineItems().toList(),
        failure(LtiServiceErrorCode.paginationLimit),
      );
      final other = (await services()).ags;
      respond = (r) async => json(
        [],
        LtiAgsClient.lineItemsMediaType,
        link: '<${r.url}>; rel=next',
      );
      await expectLater(
        other.allLineItems().toList(),
        failure(LtiServiceErrorCode.paginationLimit),
      );
      respond = (_) async => json(
        [],
        LtiAgsClient.lineItemsMediaType,
        link: '</one>; rel=next, </two>; rel=next',
      );
      await expectLater(
        other.lineItems(),
        failure(LtiServiceErrorCode.invalidResponse),
      );
    },
  );

  test('missing or insufficient capabilities cause no HTTP requests', () async {
    final api = (await services(claims: {}));
    await expectLater(
      () => api.ags.getLineItem(),
      failure(LtiServiceErrorCode.missingCapability),
    );
    expect(
      () => api.nrps.memberships(),
      failure(LtiServiceErrorCode.missingCapability),
    );
    final readOnly = (await services(
      claims: capabilities(scopes: {LtiServiceScopes.lineItemReadonly}),
    )).ags;
    await expectLater(
      readOnly.createLineItem(LtiLineItem(label: 'New', scoreMaximum: 10)),
      failure(LtiServiceErrorCode.missingCapability),
    );
    expect(requests, isEmpty);
  });

  test('401 invalidates token without replaying a write; later call obtains a new token', () async {
    final api = (await services()).ags;
    respond = (_) async => http.Response('SECRET', 401);
    await expectLater(
      api.deleteLineItem(),
      failure(LtiServiceErrorCode.rejected),
    );
    expect(getCalls(), hasLength(1));
    respond = (_) async => http.Response('', 204);
    await api.deleteLineItem();
    expect(requests.where((r) => r.url.path == '/token'), hasLength(2));
  });

  for (final status in [302, 403, 404, 429, 500]) {
    test(
      'sanitizes service status $status without redirects or retries',
      () async {
        final api = (await services()).ags;
        respond = (_) async => http.Response(
          'PRIVATE',
          status,
          headers: {'location': 'https://evil.example/'},
        );
        await expectLater(
          api.getLineItem(),
          throwsA(
            isA<LtiServiceException>()
                .having((e) => e.statusCode, 'status', status)
                .having(
                  (e) => e.toString(),
                  'safe',
                  isNot(contains('PRIVATE')),
                ),
          ),
        );
        expect(getCalls(), hasLength(1));
      },
    );
  }

  test('NRPS defaults status, tolerates missing PII, preserves member messages and differences', () async {
    final api = (await services()).nrps;
    respond = (r) async {
      expect(r.url.queryParameters, {
        'course': '42',
        'role': 'Learner',
        'rlid': 'resource',
        'limit': '10',
      });
      return json(
        {
          'id': r.url.toString(),
          'context': {'id': 'course'},
          'members': [
            {
              'user_id': 'student',
              'roles': [LtiRoles.learner],
              'message': [
                {
                  LtiClaims.messageType: 'LtiResourceLinkRequest',
                  LtiClaims.custom: {'x': 'y'},
                },
              ],
            },
            {'user_id': 'inactive', 'roles': <String>[], 'status': 'Inactive'},
          ],
        },
        LtiNrpsClient.mediaType,
        link: '</members?since=1>; rel="differences"',
      );
    };
    final page = await api.memberships(
      role: 'Learner',
      resourceLinkId: 'resource',
      limit: 10,
    );
    expect(page.items.first.status, LtiMembershipStatus.active);
    expect(page.items.first.name, isNull);
    expect(page.items.first.messages.single[LtiClaims.custom], {'x': 'y'});
    expect(page.items.last.status, LtiMembershipStatus.inactive);
    expect(
      requests.first.bodyFields['scope'],
      LtiServiceScopes.membershipReadonly,
    );
    respond = (r) async => json({
      'id': r.url.toString(),
      'context': {'id': 'course'},
      'members': [
        {'user_id': 'student', 'roles': <String>[], 'status': 'Deleted'},
      ],
    }, LtiNrpsClient.mediaType);
    expect(
      (await api.allMemberships(differencesUrl: page.differences).toList())
          .single
          .status,
      LtiMembershipStatus.deleted,
    );
    await expectLater(
      api.memberships(),
      failure(LtiServiceErrorCode.invalidResponse),
    );
  });

  test('NRPS rejects context mismatch and malformed members', () async {
    final api = (await services()).nrps;
    for (final document in [
      {
        'id': 'https://platform.example/members',
        'context': {'id': 'other'},
        'members': <Object?>[],
      },
      {
        'id': 'https://platform.example/members',
        'context': {'id': 'course'},
        'members': [
          {'roles': <String>[]},
        ],
      },
    ]) {
      respond = (_) async => json(document, LtiNrpsClient.mediaType);
      await expectLater(
        api.memberships(),
        failure(LtiServiceErrorCode.invalidResponse),
      );
    }
  });

  test('results and membership streams traverse all pages without reapplying filters', () async {
    final service = await services();
    var page = 0;
    respond = (r) async {
      final first = page++ == 0;
      expect(r.url.queryParameters.containsKey('user_id'), first);
      return json(
        [
          {
            'id': 'https://platform.example/results/$page',
            'scoreOf': itemUri.toString(),
            'userId': 'student',
            'resultScore': null,
            'resultMaximum': 10,
            'comment': null,
          },
        ],
        LtiAgsClient.resultsMediaType,
        link: first ? '</items/1/results?cursor=opaque>; rel=next' : null,
      );
    };
    expect(
      await service.ags.allResults(userId: 'student').toList(),
      hasLength(2),
    );
    page = 0;
    respond = (r) async {
      final first = page++ == 0;
      expect(r.url.queryParameters.containsKey('role'), first);
      return json(
        {
          'id': r.url.toString(),
          'context': {'id': 'course'},
          'members': [
            {
              'user_id': 'student-$page',
              'roles': [LtiRoles.learner],
            },
          ],
        },
        LtiNrpsClient.mediaType,
        link: first ? '</members?cursor=opaque>; rel="next"' : null,
      );
    };
    expect(
      await service.nrps.allMemberships(role: LtiRoles.learner).toList(),
      hasLength(2),
    );
  });

  test('lineitem write scope also permits reads and unsupported NRPS versions fail locally', () async {
    final caps = capabilities(scopes: {LtiServiceScopes.lineItem});
    caps[LtiServiceClaims.nrps] = {
      'context_memberships_url': 'https://platform.example/members',
      'service_versions': ['future'],
    };
    final service = await services(claims: caps);
    await service.ags.getLineItem();
    expect(requests.first.bodyFields['scope'], LtiServiceScopes.lineItem);
    expect(
      () => service.nrps.memberships(),
      failure(LtiServiceErrorCode.missingCapability),
    );
    expect(getCalls(), hasLength(1));
  });

  test('streaming body limit cancels consumption and timeout triggers transport abort', () async {
    final verified = await launch(capabilities());
    var cancelled = false;
    final source = StreamController<List<int>>();
    source.onCancel = () {
      cancelled = true;
    };
    source.add(utf8.encode('0123456789'));
    final transport = _StreamClient(
      (_) => http.StreamedResponse(
        source.stream,
        200,
        headers: {'content-type': LtiAgsClient.lineItemMediaType},
      ),
    );
    var service = LtiServiceClient(
      launch: verified,
      oauth: oauth,
      client: transport,
      allowedOrigins: {Uri.parse('https://platform.example')},
      maxResponseBytes: 4,
    );
    await expectLater(
      service.ags.getLineItem(),
      failure(LtiServiceErrorCode.invalidResponse),
    );
    expect(cancelled, isTrue);
    await source.close();

    final aborted = Completer<void>();
    final hanging = StreamController<List<int>>();
    final stalled = _StreamClient((r) {
      (r as http.AbortableRequest).abortTrigger!.then((_) {
        aborted.complete();
        hanging.close();
      });
      return http.StreamedResponse(
        hanging.stream,
        200,
        headers: {'content-type': LtiAgsClient.lineItemMediaType},
      );
    });
    service = LtiServiceClient(
      launch: verified,
      oauth: oauth,
      client: stalled,
      allowedOrigins: {Uri.parse('https://platform.example')},
      timeout: const Duration(milliseconds: 100),
    );
    await expectLater(
      service.ags.getLineItem(),
      failure(LtiServiceErrorCode.unavailable),
    );
    await aborted.future.timeout(const Duration(seconds: 2));
    transport.close();
    stalled.close();
  });

  test('response size, media type and time are bounded', () async {
    final small = (await services(maxResponseBytes: 4)).ags;
    await expectLater(
      small.getLineItem(),
      failure(LtiServiceErrorCode.invalidResponse),
    );
    final api = (await services(timeout: const Duration(milliseconds: 100)))
        .ags;
    respond = (_) async => http.Response('PRIVATE', 200);
    await expectLater(
      api.getLineItem(),
      failure(LtiServiceErrorCode.invalidResponse),
    );
    final stalled = Completer<http.Response>();
    respond = (_) => stalled.future;
    await expectLater(
      api.getLineItem(),
      failure(LtiServiceErrorCode.unavailable),
    );
    stalled.complete(json(item(), LtiAgsClient.lineItemMediaType));
  });

  test('results default maximum to one and preserve finite platform score overrides', () {
    final result = LtiResult.fromJson({
      'id': 'https://platform.example/results/1',
      'scoreOf': itemUri.toString(),
      'userId': 'student',
      'resultScore': -1,
    });
    expect(result.resultMaximum, 1);
    expect(result.resultScore, -1);
  });

  test('model validation supports clear scores, extra credit and nullable platform metadata', () {
    final score = LtiScore(
      userId: 'student',
      timestamp: platform.now,
      activityProgress: LtiActivityProgress.started,
      gradingProgress: LtiGradingProgress.notReady,
    );
    expect(score.toJson()['scoreGiven'], isNull);
    expect(
      () => LtiScore(
        userId: 'student',
        timestamp: platform.now,
        activityProgress: LtiActivityProgress.completed,
        gradingProgress: LtiGradingProgress.fullyGraded,
        scoreGiven: 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => LtiLineItem(label: 'Test', scoreMaximum: double.nan),
      throwsFormatException,
    );
    final nullable = LtiLineItem.fromJson({
      ...item(),
      'startDateTime': '',
      'tag': null,
    });
    expect(nullable.startDateTime, isNull);
    expect(nullable.tag, isNull);
    expect(
      () => (nullable.json['https://tool.example/extension'] as Map)['keep'] =
          false,
      throwsUnsupportedError,
    );
  });
}

final class _StreamClient extends http.BaseClient {
  _StreamClient(this.respond);
  final http.StreamedResponse Function(http.BaseRequest) respond;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      respond(request);
}
