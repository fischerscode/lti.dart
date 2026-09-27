import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:lti/lti.dart';
import 'package:lti_shelf/lti_shelf.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'deep_linking_selection.dart';
import 'service_read_test.dart';

/// Local HTTPS integration runner, not a production application.
/// Run from the repository root; installation-specific data stays in .local/.
Future<void> main() async {
  final configPath =
      Platform.environment['LTI_CONFIG_FILE'] ??
      '.local/bycs/registration.json';
  final config =
      jsonDecode(await File(configPath).readAsString()) as Map<String, dynamic>;
  String value(String name) {
    final result = config[name];
    if (result is! String || result.isEmpty) {
      throw StateError('Missing configuration field: $name');
    }
    return result;
  }

  final origin = Uri.parse(value('tool_origin'));
  final registration = LtiRegistration(
    issuer: value('issuer'),
    clientId: value('client_id'),
    deploymentIds: {value('deployment_id')},
    authenticationEndpoint: Uri.parse(value('authentication_endpoint')),
    jwksUri: Uri.parse(value('jwks_uri')),
    tokenEndpoint: Uri.parse(value('token_endpoint')),
    redirectUri: origin.resolve('/lti/launch'),
    targetLinkUris: {origin.resolve('/activity').toString()},
  );
  final key = RsaLtiSigningKey.fromPem(
    await File(value('signing_key_file')).readAsString(),
    keyId: value('signing_key_id'),
  );
  final tls = SecurityContext()
    ..useCertificateChain(value('tls_certificate_file'))
    ..usePrivateKey(value('tls_private_key_file'));
  final client = http.Client();
  final tool = LtiTool(
    registrations: MemoryLtiRegistrationStore([registration]),
    transactions: MemoryLtiTransactionStore(),
    tokenVerifier: RemoteJwksVerifier(client: client),
    signer: LtiJwtSigner(keys: MemoryLtiSigningKeyProvider(key)),
  );
  final oauth = LtiOAuthClient(client: client, signer: tool.signer!);
  final serviceReads = Platform.environment['BYCS_SERVICE_READ_TESTS'] == '1';
  final port = int.parse(Platform.environment['PORT'] ?? '8443');
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    port,
    tls,
  );
  serveIntegration(
    server,
    integrationHandler(
      tool: tool,
      origin: origin,
      platformOrigin: Uri.parse(registration.issuer),
      servicesFor: serviceReads
          ? (launch) => LtiServiceClient(
              launch: launch,
              oauth: oauth,
              client: client,
              allowedOrigins: {
                Uri.parse(registration.issuer)
                    .replace(path: '', query: null, fragment: null),
              },
            )
          : null,
      onAccessRequest: Platform.environment['BYCS_ACCESS_LOG'] == '1'
          ? (message) => stdout.writeln(message)
          : null,
      onJwksRequest: Platform.environment['BYCS_JWKS_DIAGNOSTICS'] == '1'
          ? (message) => stdout.writeln(message)
          : null,
    ),
  );
  server.idleTimeout = const Duration(seconds: 15);
  stdout.writeln(
    'LTI HTTPS integration server on WSL 127.0.0.1:${server.port}',
  );
  stdout.writeln('Public origin: $origin');
  stdout.writeln(
    'Resource launches and Deep Linking selection enabled. '
    'Service read tests: ${serviceReads ? 'enabled for instructors' : 'disabled'}.',
  );
  if (Platform.environment['BYCS_JWKS_DIAGNOSTICS'] == '1') {
    stdout.writeln(
      'JWKS diagnostics enabled: fixed route, method, probe label and response status only.',
    );
  }
  if (Platform.environment['BYCS_ACCESS_LOG'] == '1') {
    stdout.writeln(
      'HTTP access log enabled: arrival and response for every HTTP request; no query values, headers or bodies.',
    );
  }
  final stopped = Completer<void>();
  void stop(ProcessSignal _) {
    if (!stopped.isCompleted) stopped.complete();
  }

  final interrupt = ProcessSignal.sigint.watch().listen(stop);
  final terminate = ProcessSignal.sigterm.watch().listen(stop);
  await stopped.future;
  await server.close(force: true);
  client.close();
  await interrupt.cancel();
  await terminate.cancel();
}

/// Serves the integration handler without Dart's conflicting framing default.
void serveIntegration(HttpServer server, Handler handler) {
  // Dart's default SAMEORIGIN header prevents embedding in the platform.
  // The integration handler supplies a restrictive frame-ancestors policy.
  server.defaultResponseHeaders.removeAll('x-frame-options');
  shelf_io.serveRequests(server, handler);
}

/// Shows protocol success without exposing users, course IDs or raw JWTs.
Handler integrationHandler({
  required LtiTool tool,
  required Uri origin,
  required Uri platformOrigin,
  void Function(String message)? onJwksRequest,
  void Function(String message)? onAccessRequest,
  LtiServiceClient Function(LtiResourceLaunch)? servicesFor,
}) {
  if (platformOrigin.scheme != 'https' || platformOrigin.host.isEmpty) {
    throw ArgumentError('An HTTPS platform origin is required.');
  }
  final ancestors = "frame-ancestors 'self' ${platformOrigin.origin}";
  const headers = {
    'content-type': 'text/plain; charset=utf-8',
    'cache-control': 'no-store',
    'referrer-policy': 'no-referrer',
    'x-content-type-options': 'nosniff',
  };
  final selection = DeepLinkingSelection(
    tool: tool,
    origin: origin,
    partitionedCookies: true,
  );
  final adapter = LtiShelf(
    tool: tool,
    publicOrigin: origin,
    partitionedCookies: true,
    onProtocolError: (error) =>
        stderr.writeln('LTI ${error.code.name}: ${error.message}'),
    onDeepLinkingLaunch: selection.begin,
    onResourceLaunch: (request, launch) async => Response.ok(
      'LTI 1.3 resource launch verified.\n'
      'Signature, issuer, audience, deployment, state and nonce validated.\n'
      'User present: ${launch.user != null}\n'
      'Context present: ${launch.context != null}\n'
      'Role count: ${launch.roles.length}\n'
      'Deep Linking test marker present: ${launch.custom['lti_dart_test'] == 'deep-linking-v1'}\n'
      'This is a protocol test, not application authorization.\n'
      '${servicesFor == null ? '' : '\n${await serviceReadReport(launch, servicesFor)}\n'}',
      headers: headers,
    ),
  );
  Future<Response> handle(Request request) async {
    final path = request.url.path;
    if (path.isEmpty || path == 'health' || path == 'activity') {
      if (request.method != 'GET' && request.method != 'HEAD') {
        return Response(405, headers: {...headers, 'allow': 'GET, HEAD'});
      }
      final text = path == 'activity'
          ? 'Open this activity from your ByCS course. A direct URL is not an authenticated launch.\n'
          : 'HTTPS ready. LTI resource launch verification configured.\n';
      return Response.ok(
        request.method == 'HEAD' ? null : text,
        headers: headers,
      );
    }
    try {
      if ('/$path' == DeepLinkingSelection.path) {
        return await selection.complete(request);
      }
      return await adapter.handler(request);
    } catch (_) {
      // Do not include exception details, request URLs, hints or JWTs in logs.
      stderr.writeln('LTI integration request failed with an internal error.');
      return Response.internalServerError(
        body: 'Internal integration error.',
        headers: headers,
      );
    }
  }

  return withAccessDiagnostics((request) async {
    final response = await handle(request);
    if (request.url.path == 'lti/jwks' && onJwksRequest != null) {
      // The label helps correlate a deliberate test, but does not identify its
      // sender. Never log raw queries, request headers, addresses or bodies.
      final labels = request.url.queryParametersAll['probe'];
      final label = switch (labels) {
        null => 'none',
        ['bycs'] => 'bycs',
        ['local'] => 'local',
        _ => 'other',
      };
      final method = switch (request.method) {
        'GET' => 'GET',
        'HEAD' => 'HEAD',
        _ => 'OTHER',
      };
      try {
        onJwksRequest(
          'JWKS ${DateTime.now().toUtc().toIso8601String()} '
          'method=$method probe=$label status=${response.statusCode}',
        );
      } catch (_) {
        // Diagnostic observers must not break key publication.
      }
    }
    final csp = response.headers['content-security-policy'];
    return response.change(
      headers: {
        'content-security-policy': csp == null ? ancestors : '$csp; $ancestors',
      },
    );
  }, onAccessRequest);
}

/// Logs arrival before dispatch, even if the handler stalls or throws.
/// Request IDs correlate events within this process, not users or sessions.
Handler withAccessDiagnostics(
  Handler handler,
  void Function(String message)? observer,
) {
  if (observer == null) return handler;
  var sequence = 0;
  void emit(Map<String, Object> event) {
    try {
      observer(
        'HTTP ${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), ...event})}',
      );
    } catch (_) {
      // Observability must not affect request handling.
    }
  }

  String bounded(String value, int limit) =>
      value.length <= limit ? value : '${value.substring(0, limit)}…';
  return (request) async {
    final id = ++sequence;
    final timer = Stopwatch()..start();
    emit({
      'event': 'received',
      'id': id,
      'method': bounded(request.method, 32),
      'path': bounded(request.requestedUri.path, 1024),
    });
    try {
      final response = await handler(request);
      emit({
        'event': 'response',
        'id': id,
        'status': response.statusCode,
        'elapsed_ms': timer.elapsedMilliseconds,
      });
      return response;
    } catch (_) {
      emit({
        'event': 'failed',
        'id': id,
        'elapsed_ms': timer.elapsedMilliseconds,
      });
      rethrow;
    } finally {
      timer.stop();
    }
  };
}
