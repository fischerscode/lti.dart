import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:lti/lti.dart';
import 'package:lti_shelf/lti_shelf.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Integration skeleton, not a learning application. Place behind HTTPS.
Future<void> main() async {
  String env(String name) =>
      Platform.environment[name] ??
      (throw StateError('Set $name before starting the example.'));

  final origin = Uri.parse(env('TOOL_ORIGIN'));
  final client = http.Client();
  final privateKeyPath = Platform.environment['LTI_PRIVATE_KEY_FILE'];
  final signer = privateKeyPath == null
      ? null
      : LtiJwtSigner(
          keys: MemoryLtiSigningKeyProvider(
            RsaLtiSigningKey.fromPem(
              await File(privateKeyPath).readAsString(),
              keyId: env('LTI_KEY_ID'),
            ),
          ),
        );
  final registration = LtiRegistration(
    issuer: env('LTI_ISSUER'),
    clientId: env('LTI_CLIENT_ID'),
    deploymentIds: {env('LTI_DEPLOYMENT_ID')},
    authenticationEndpoint: Uri.parse(env('LTI_AUTH_ENDPOINT')),
    jwksUri: Uri.parse(env('LTI_JWKS_URI')),
    redirectUri: origin.resolve('/lti/launch'),
    targetLinkUris: {origin.resolve('/activity').toString()},
  );
  final adapter = LtiShelf(
    tool: LtiTool(
      registrations: MemoryLtiRegistrationStore([registration]),
      transactions: MemoryLtiTransactionStore(),
      tokenVerifier: RemoteJwksVerifier(client: client),
      signer: signer,
    ),
    publicOrigin: origin,
    onResourceLaunch: (request, launch) {
      // Replace with application authorization, session creation and a redirect.
      // Do not send the id_token or all launch claims to the browser.
      return Response.ok('LTI resource launch verified.');
    },
  );
  final server = await shelf_io.serve(
    adapter.handler,
    InternetAddress.loopbackIPv4,
    8080,
  );
  stdout.writeln(
    'LTI adapter listening on localhost:${server.port} behind $origin',
  );
  await ProcessSignal.sigint.watch().first;
  await server.close(force: true);
  client.close();
}
