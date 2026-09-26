/// Shelf integration for LTI resource launches.
library;

import 'dart:async';
import 'dart:convert';

import 'package:lti/lti.dart';
import 'package:shelf/shelf.dart';

typedef LtiResourceLaunchHandler = FutureOr<Response> Function(
  Request request,
  LtiResourceLaunch launch,
);

/// Mount [handler] at the server root. Paths are relative to [publicOrigin].
/// HTTPS must terminate at the server or a trusted reverse proxy.
///
/// This adapter requires a browser cookie to bind the OIDC response. Browsers
/// blocking third-party cookies must launch in a top-level window for now.
/// Missing cookies fail closed; the adapter never falls back to state alone.
final class LtiShelf {
  LtiShelf({
    required this.tool,
    required this.publicOrigin,
    required this.onResourceLaunch,
    this.loginPath = '/lti/login',
    this.launchPath = '/lti/launch',
    this.maxRequestBytes = 131072,
  }) {
    if (publicOrigin.scheme != 'https' ||
        publicOrigin.host.isEmpty ||
        publicOrigin.userInfo.isNotEmpty ||
        publicOrigin.hasQuery ||
        publicOrigin.hasFragment ||
        (publicOrigin.path.isNotEmpty && publicOrigin.path != '/') ||
        loginPath == launchPath ||
        maxRequestBytes <= 0) {
      throw ArgumentError(
        'An HTTPS origin, distinct paths and positive body limit are required.',
      );
    }
    for (final path in [loginPath, launchPath]) {
      if (!RegExp(r'^/[a-zA-Z0-9/_-]+$').hasMatch(path)) {
        throw ArgumentError('Route paths must be absolute, plain URL paths.');
      }
    }
  }
  final LtiTool tool;
  final Uri publicOrigin;
  final LtiResourceLaunchHandler onResourceLaunch;
  final String loginPath;
  final String launchPath;
  final int maxRequestBytes;

  static const _headers = {
    'cache-control': 'no-store',
    'pragma': 'no-cache',
    'referrer-policy': 'no-referrer',
  };

  Handler get handler => _handle;

  Future<Response> _handle(Request request) async {
    final path = '/${request.url.path}';
    if (path != loginPath && path != launchPath) {
      return Response.notFound('Not found');
    }
    final allowed = path == loginPath ? ['GET', 'POST'] : ['POST'];
    if (!allowed.contains(request.method)) {
      return Response(405, headers: {..._headers, 'allow': allowed.join(', ')});
    }
    String? state;
    LtiResourceLaunch launch;
    try {
      final parameters = await _parameters(request);
      if (path == loginPath) {
        final redirect = await tool.beginLogin(
          LtiLoginRequest.fromParameters(parameters),
        );
        if (redirect.uri.queryParameters['redirect_uri'] !=
            publicOrigin.resolve(launchPath).toString()) {
          throw const LtiException(
            LtiErrorCode.invalidRequest,
            'Registration callback does not match this adapter.',
          );
        }
        return Response(
          303,
          headers: {
            ..._headers,
            'location': redirect.uri.toString(),
            'set-cookie': _cookie(
              redirect.state,
              redirect.browserBinding,
              tool.loginLifetime.inSeconds,
            ),
          },
        );
      }
      state = parameters['state'];
      final token = parameters['id_token'];
      final authenticationError = parameters['error'];
      if (state == null ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(state) ||
          (token == null &&
              (authenticationError == null || authenticationError.isEmpty)) ||
          (token != null && authenticationError != null)) {
        throw const LtiException(
          LtiErrorCode.invalidRequest,
          'Expected state and id_token.',
        );
      }
      final binding = _browserBinding(request, state);
      if (authenticationError != null) {
        await tool.completeLoginError(state: state, browserBinding: binding);
      }
      launch = await tool.completeResourceLaunch(
        state: state,
        browserBinding: binding,
        idToken: token!,
      );
    } on LtiException catch (error) {
      return Response(
        switch (error.code) {
          LtiErrorCode.platformUnavailable => 502,
          LtiErrorCode.invalidToken ||
          LtiErrorCode.invalidClaims ||
          LtiErrorCode.authenticationFailed ||
          LtiErrorCode.unknownRegistration when path == launchPath => 401,
          _ => 400,
        },
        body: 'LTI request rejected: ${error.code.name}',
        headers: {
          ..._headers,
          'content-type': 'text/plain; charset=utf-8',
          if (state != null && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(state))
            'set-cookie': _cookie(state, '', 0),
        },
      );
    } on FormatException {
      return Response(
        400,
        body: 'Invalid LTI request encoding.',
        headers: _headers,
      );
    }
    // Application failures belong to the host's error handling middleware.
    final response = await onResourceLaunch(request, launch);
    final headers = Map<String, Object>.from(response.headersAll);
    headers.addAll(_headers);
    headers['set-cookie'] = [
      ...?response.headersAll['set-cookie'],
      _cookie(state, '', 0),
    ];
    return response.change(headers: headers);
  }

  String _cookie(String state, String value, int maxAge) =>
      '__Host-lti-$state=$value; Path=/; Secure; HttpOnly; SameSite=None; Max-Age=$maxAge';

  String _browserBinding(Request request, String state) {
    final name = '__Host-lti-$state';
    final matches = (request.headers['cookie'] ?? '')
        .split(';')
        .map((part) => part.trim())
        .where((part) => part.startsWith('$name='))
        .toList();
    if (matches.length != 1) {
      throw const LtiException(
        LtiErrorCode.invalidState,
        'Browser binding missing or ambiguous.',
      );
    }
    return matches.single.substring(name.length + 1);
  }

  Future<Map<String, String>> _parameters(Request request) async {
    String encoded;
    if (request.method == 'GET') {
      encoded = request.url.query;
      if (encoded.length > maxRequestBytes) {
        throw const LtiException(
          LtiErrorCode.invalidRequest,
          'Request too large.',
        );
      }
    } else {
      if (request.headers['content-type']
              ?.split(';')
              .first
              .trim()
              .toLowerCase() !=
          'application/x-www-form-urlencoded') {
        throw const LtiException(
          LtiErrorCode.invalidRequest,
          'Expected a form POST.',
        );
      }
      final bytes = <int>[];
      await for (final chunk in request.read()) {
        bytes.addAll(chunk);
        if (bytes.length > maxRequestBytes) {
          throw const LtiException(
            LtiErrorCode.invalidRequest,
            'Request too large.',
          );
        }
      }
      encoded = utf8.decode(bytes);
    }
    final all = Uri(query: encoded).queryParametersAll;
    if (all.values.any((values) => values.length != 1)) {
      throw const LtiException(
        LtiErrorCode.invalidRequest,
        'Duplicate parameters.',
      );
    }
    return all.map((key, values) => MapEntry(key, values.single));
  }
}
