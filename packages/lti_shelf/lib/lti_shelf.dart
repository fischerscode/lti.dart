/// Shelf routes for LTI login, resource launches, Deep Linking and tool JWKS.
///
/// Construct [LtiShelf] with a configured [LtiTool], an external HTTPS origin
/// and application launch callbacks. Mount [LtiShelf.handler] at the server
/// root and compose other routes in the host application. Protocol verification
/// does not replace application authorization or durable user sessions.
///
/// ```dart
/// final adapter = LtiShelf(
///   tool: configuredTool,
///   publicOrigin: Uri.parse('https://tool.example'),
///   onResourceLaunch: (request, launch) async {
///     // Apply the application's authorization policy before showing content.
///     return Response.ok('Launch verified; authorization still required.');
///   },
/// );
/// final handler = adapter.handler;
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:lti/lti.dart';
import 'package:shelf/shelf.dart';

/// Handles a verified resource launch and returns the application response.
///
/// The callback receives the original Shelf request, whose form body has
/// already been consumed. Apply application authorization and create your own
/// session; successful protocol validation alone does not grant tool access.
/// Callback failures propagate to the host error-handling middleware.
typedef LtiResourceLaunchHandler = FutureOr<Response> Function(
  Request request,
  LtiResourceLaunch launch,
);

/// Handles a verified Deep Linking request by presenting a selection UI.
///
/// Retain the launch in a protected server session, authorize the user and
/// protect selection actions against CSRF. The request body is already read.
/// Return a signed selection with [deepLinkingFormResponse] after selection.
typedef LtiDeepLinkingLaunchHandler = FutureOr<Response> Function(
  Request request,
  LtiDeepLinkingLaunch launch,
);

/// Mount [handler] at the server root. Paths are relative to [publicOrigin].
/// HTTPS must terminate at the server or a trusted reverse proxy.
///
/// This adapter requires a browser cookie to bind the OIDC response. Browsers
/// can use opt-in partitioned cookies for embedded launches where supported.
/// Missing cookies fail closed; the adapter never falls back to state alone.
final class LtiShelf {
  /// Creates root-mounted login, callback and optional public JWKS routes.
  ///
  /// [publicOrigin] must be the externally visible HTTPS origin, including any
  /// nonstandard port. Routes must be distinct absolute plain paths; the
  /// registered callback must equal the origin plus [launchPath]. Invalid
  /// configuration throws [ArgumentError]. [onResourceLaunch] must authorize
  /// the verified user before returning protected content.
  ///
  /// The host configures TLS, request deadlines and platform-specific iframe
  /// CSP. [partitionedCookies] can support embedded launches in compatible
  /// browsers; missing binding cookies are always rejected.
  LtiShelf({
    required this.tool,
    required this.publicOrigin,
    required this.onResourceLaunch,
    this.onDeepLinkingLaunch,
    this.onProtocolError,
    this.loginPath = '/lti/login',
    this.launchPath = '/lti/launch',
    this.jwksPath = '/lti/jwks',
    this.jwksCacheLifetime = const Duration(minutes: 5),
    this.maxRequestBytes = 131072,
    this.partitionedCookies = false,
  }) {
    if (publicOrigin.scheme != 'https' ||
        publicOrigin.host.isEmpty ||
        publicOrigin.userInfo.isNotEmpty ||
        publicOrigin.hasQuery ||
        publicOrigin.hasFragment ||
        (publicOrigin.path.isNotEmpty && publicOrigin.path != '/') ||
        {loginPath, launchPath, jwksPath}.length != 3 ||
        jwksCacheLifetime < Duration.zero ||
        maxRequestBytes <= 0) {
      throw ArgumentError(
        'An HTTPS origin, distinct paths and positive body limit are required.',
      );
    }
    for (final path in [loginPath, launchPath, jwksPath]) {
      if (!RegExp(r'^/[a-zA-Z0-9/_-]+$').hasMatch(path)) {
        throw ArgumentError('Route paths must be absolute, plain URL paths.');
      }
    }
  }

  /// Configured protocol verifier, registration store and optional signer.
  final LtiTool tool;

  /// Externally visible HTTPS origin used for callbacks and route validation.
  final Uri publicOrigin;

  /// Application callback invoked only after resource launch validation.
  final LtiResourceLaunchHandler onResourceLaunch;

  /// Optional selection callback; absent handlers reject Deep Linking requests.
  final LtiDeepLinkingLaunchHandler? onDeepLinkingLaunch;

  /// Optional server-side diagnostic observer. The HTTP response stays generic.
  /// Do not throw from this callback. Custom verifiers/stores must also ensure
  /// their exception messages contain no tokens or personal data.
  final void Function(LtiException error)? onProtocolError;

  /// Login-initiation path accepting GET or form POST; default `/lti/login`.
  final String loginPath;

  /// OIDC callback path accepting form POST; default `/lti/launch`.
  final String launchPath;

  /// Public tool JWKS path for GET/HEAD; active only when a signer is configured.
  final String jwksPath;

  /// Public JWKS cache lifetime; defaults to five minutes and may be zero.
  final Duration jwksCacheLifetime;

  /// Maximum POST body bytes or GET encoded-query length; default 131072.
  final int maxRequestBytes;

  /// Opt into CHIPS for browser binding within a platform iframe.
  /// Requires browser support; missing cookies still fail closed.
  final bool partitionedCookies;

  static const _headers = {
    'cache-control': 'no-store',
    'pragma': 'no-cache',
    'referrer-policy': 'no-referrer',
  };

  /// Root-mounted Shelf handler for the configured protocol routes.
  ///
  /// Unknown paths return 404; compose with your application's router.
  /// Protocol failures produce redacted HTTP responses. Application callback
  /// exceptions propagate. Successful launch responses are marked no-store;
  /// application cookies are preserved and the one-use binding cookie expires.
  Handler get handler => _handle;

  Future<Response> _handle(Request request) async {
    final path = '/${request.url.path}';
    if (path == jwksPath && tool.signer != null) {
      if (request.method != 'GET' && request.method != 'HEAD') {
        return Response(405, headers: {..._headers, 'allow': 'GET, HEAD'});
      }
      final body = jsonEncode(await tool.signer!.publicJwks());
      return Response.ok(
        request.method == 'HEAD' ? null : body,
        headers: {
          'content-type': 'application/jwk-set+json',
          'cache-control': 'public, max-age=${jwksCacheLifetime.inSeconds}',
          'content-length': utf8.encode(body).length.toString(),
          'x-content-type-options': 'nosniff',
        },
      );
    }
    if (path != loginPath && path != launchPath) {
      return Response.notFound('Not found');
    }
    final allowed = path == loginPath ? ['GET', 'POST'] : ['POST'];
    if (!allowed.contains(request.method)) {
      return Response(405, headers: {..._headers, 'allow': allowed.join(', ')});
    }
    String? state;
    LtiLaunch launch;
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
      launch = await tool.completeLaunch(
        state: state,
        browserBinding: binding,
        idToken: token!,
      );
      if (launch is LtiDeepLinkingLaunch && onDeepLinkingLaunch == null) {
        throw const LtiException(
          LtiErrorCode.unsupportedMessage,
          'No selection handler configured.',
        );
      }
    } on LtiException catch (error) {
      onProtocolError?.call(error);
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
    final response = await switch (launch) {
      LtiResourceLaunch() => onResourceLaunch(request, launch),
      LtiDeepLinkingLaunch() => onDeepLinkingLaunch!(request, launch),
    };
    final headers = Map<String, Object>.from(response.headersAll);
    headers.addAll(_headers);
    // Application forms may need a policy that preserves their POST Origin.
    // Keep no-referrer as the default and always enforce no-store.
    final referrerPolicy = response.headers['referrer-policy'];
    if (referrerPolicy != null) {
      headers['referrer-policy'] = referrerPolicy;
    }
    headers['set-cookie'] = [
      ...?response.headersAll['set-cookie'],
      _cookie(state, '', 0),
    ];
    return response.change(headers: headers);
  }

  String _cookie(String state, String value, int maxAge) =>
      '__Host-lti-$state=$value; Path=/; Secure; HttpOnly; SameSite=None; Max-Age=$maxAge'
      '${partitionedCookies ? '; Partitioned' : ''}';

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

/// Auto-post a signed selection to the platform; includes a manual-submit fallback.
/// Content-item HTML is carried inside the JWT and is never rendered here.
///
/// [message] must be produced from an authorized, verified selection request.
/// The returned no-store HTML response escapes form values, uses a nonce-based
/// script policy and posts an uppercase `JWT` field. It does not establish an
/// application session, authenticate the browser, or send the POST itself.
Response deepLinkingFormResponse(LtiDeepLinkingResponse message) {
  final random = Random.secure();
  final nonce = base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
  const escape = HtmlEscape();
  final action = escape.convert(message.returnUrl.toString());
  final jwt = escape.convert(message.jwt);
  return Response.ok(
    '''<!doctype html><html lang="en"><meta charset="utf-8">
<title>Return to learning platform</title><body>
<form id="lti-return" method="post" action="$action">
<input type="hidden" name="JWT" value="$jwt">
<button type="submit">Return to learning platform</button></form>
<script nonce="$nonce">document.getElementById('lti-return').submit();</script>
</body></html>''',
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'pragma': 'no-cache',
      'referrer-policy': 'no-referrer',
      'x-content-type-options': 'nosniff',
      'content-security-policy':
          "default-src 'none'; script-src 'nonce-$nonce'; base-uri 'none'; form-action https:",
    },
  );
}
