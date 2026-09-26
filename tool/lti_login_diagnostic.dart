import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Display selected, UNVERIFIED login metadata without storing any request data.
/// This development handler never follows issuer URLs or starts authentication.
Future<void> handleLoginDiagnostic(HttpRequest request) async {
  final response = request.response;
  response.headers
    ..contentType = ContentType.text
    ..set(HttpHeaders.cacheControlHeader, 'no-store')
    ..set('referrer-policy', 'no-referrer')
    ..set('x-content-type-options', 'nosniff');
  if (request.method != 'GET' && request.method != 'POST') {
    response
      ..statusCode = HttpStatus.methodNotAllowed
      ..headers.set(HttpHeaders.allowHeader, 'GET, POST');
    return;
  }
  const limit = 16384;
  try {
    if (request.uri.query.length > limit) throw const FormatException();
    final parameters = <String, String>{};
    void addParameters(String encoded) {
      final parsed = Uri(query: encoded).queryParametersAll;
      for (final entry in parsed.entries) {
        if (entry.value.length != 1 || parameters.containsKey(entry.key)) {
          throw const FormatException();
        }
        parameters[entry.key] = entry.value.single;
      }
    }

    addParameters(request.uri.query);
    if (request.method == 'POST') {
      if (request.headers.contentType?.mimeType !=
          'application/x-www-form-urlencoded') {
        response.statusCode = HttpStatus.unsupportedMediaType;
        response.write('Expected a form POST.');
        return;
      }
      final bytes = <int>[];
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      final stream = StreamIterator<List<int>>(request);
      try {
        while (await stream.moveNext().timeout(
          deadline.difference(DateTime.now()),
        )) {
          bytes.addAll(stream.current);
          if (bytes.length > limit) throw const FormatException();
        }
      } finally {
        await stream.cancel();
      }
      addParameters(utf8.decode(bytes));
    }
    // Never display login_hint, lti_message_hint, tokens, cookies or all parameters.
    final metadata = <String, String>{
      for (final key in ['iss', 'client_id', 'lti_deployment_id'])
        if (parameters.containsKey(key)) key: parameters[key]!,
    };
    response.write(
      'LTI login diagnosis — NOT an authenticated launch.\n'
      'These values are unverified and are not automatically trusted or saved.\n\n'
      '${const JsonEncoder.withIndent('  ').convert(metadata)}\n\n'
      'Copy this result to the development chat. Missing fields require further investigation.\n',
    );
  } on FormatException {
    response.statusCode = HttpStatus.badRequest;
    response.write('Invalid or oversized login parameters.');
  } on TimeoutException {
    response.statusCode = HttpStatus.requestTimeout;
    response.write('Login request timed out.');
  } on HttpException {
    response.statusCode = HttpStatus.badRequest;
    response.write('Incomplete login request.');
  }
}
