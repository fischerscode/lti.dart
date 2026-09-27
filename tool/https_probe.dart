import 'dart:io';

import 'lti_login_diagnostic.dart';

/// HTTPS probe and unverified LTI login metadata diagnostic for development.
/// Run from WSL after copying the certificate into .local/bycs/tls.
Future<void> main() async {
  final certificate =
      Platform.environment['TLS_CERT_FILE'] ?? '.local/bycs/tls/fullchain.pem';
  final privateKey =
      Platform.environment['TLS_KEY_FILE'] ?? '.local/bycs/tls/privkey.pem';
  final port = int.parse(Platform.environment['PORT'] ?? '8443');
  if (!File(certificate).existsSync() || !File(privateKey).existsSync()) {
    stderr.writeln(
      'TLS files are missing or inaccessible. See docs/bycs-testing.md.',
    );
    exitCode = 1;
    return;
  }
  final context = SecurityContext()
    ..useCertificateChain(certificate)
    ..usePrivateKey(privateKey);
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    port,
    context,
  );
  server.idleTimeout = const Duration(seconds: 15);
  stdout.writeln('HTTPS probe listening on WSL 127.0.0.1:${server.port}.');
  stdout.writeln('Public URL: https://ltitest.schulzeug.eu/health');
  stdout.writeln(
    'Login diagnosis: /lti/login. Launch verification is not active.',
  );
  final interrupt = ProcessSignal.sigint.watch().listen((_) {
    server.close(force: true);
  });
  final terminate = ProcessSignal.sigterm.watch().listen((_) {
    server.close(force: true);
  });
  try {
    await for (final request in server) {
      request.response.headers
        ..contentType = ContentType.text
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('x-content-type-options', 'nosniff');
      if (request.uri.path == '/lti/login') {
        await handleLoginDiagnostic(request);
      } else if (request.method != 'GET' && request.method != 'HEAD') {
        request.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      } else if (request.uri.path == '/' || request.uri.path == '/health') {
        if (request.method == 'GET') {
          request.response.write(
            'HTTPS tunnel ready. LTI integration not configured yet.\n',
          );
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    }
  } finally {
    await interrupt.cancel();
    await terminate.cancel();
  }
}
