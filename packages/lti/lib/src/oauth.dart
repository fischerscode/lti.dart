import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'signing.dart';

/// Stable failure categories for obtaining platform service access tokens.
enum LtiOAuthErrorCode {
  /// The token endpoint returned a non-success status other than 429 or 5xx.
  rejected,

  /// Transport, timeout, signing or platform availability failure.
  unavailable,

  /// A successful HTTP response failed token-response validation.
  invalidResponse,

  /// The granted token scopes do not include every requested scope.
  insufficientScope,

  /// Too many distinct token requests are already pending in this client.
  capacity,
}

/// Fixed validation categories; never contains platform response values.
enum LtiOAuthResponseIssue {
  /// The token response has an unsupported or missing Content-Type.
  contentType,

  /// The response exceeds the configured maximum byte count.
  responseSize,

  /// The response is not valid UTF-8 JSON containing an object.
  json,

  /// The access token is absent or is not a valid bearer credential string.
  accessToken,

  /// The token type is absent or is not Bearer (case-insensitive).
  tokenType,

  /// The expiry lifetime is not a positive bounded integer number of seconds.
  expiresIn,

  /// The explicit scope value is not a valid space-separated scope set.
  scope,

  /// The token has already expired by the time the response is processed.
  expired,
}

/// Safe diagnostics: never includes assertions, tokens or platform response text.
final class LtiOAuthException implements Exception {
  /// Creates a redacted OAuth failure with optional HTTP and validation metadata.
  const LtiOAuthException(this.code, {this.statusCode, this.responseIssue});

  /// Stable failure category for application error handling.
  final LtiOAuthErrorCode code;

  /// HTTP status when available; null for failures without captured status.
  final int? statusCode;

  /// Fixed validation category for an invalid response, when available.
  final LtiOAuthResponseIssue? responseIssue;
  @override
  String toString() =>
      'LtiOAuthException(${code.name}, status=$statusCode, issue=${responseIssue?.name})';
}

/// A validated bearer token and its immutable granted scopes.
///
/// Obtained through [LtiOAuthClient.accessToken]. Treat [value] as a credential;
/// only transmit it to explicitly trusted service destinations.
final class LtiAccessToken {
  LtiAccessToken._(this.value, Set<String> scopes, this.expiresAt)
    : scopes = Set.unmodifiable(scopes);

  /// Secret bearer credential. Do not log or return to a browser.
  final String value;

  /// Immutable granted scopes; may include additional platform-granted scopes.
  final Set<String> scopes;

  /// Conservative expiry computed from request start plus the granted lifetime.
  final DateTime expiresAt;
  @override
  String toString() => 'LtiAccessToken([redacted])';
}

typedef _CacheKey = (LtiRegistration, String?, String);

/// Client-credentials tokens from an administrator-provisioned token endpoint.
/// The caller owns [client]. Never construct registrations from launch URLs.
/// Cache keys use registration identity, optional deployment and exact scope set.
/// This client does not send bearer credentials to service URLs.
final class LtiOAuthClient {
  /// Creates a reusable OAuth client with bounded process-local caching.
  ///
  /// The caller owns [client]. [clock] defaults to the current time. Invalid
  /// limits throw [ArgumentError]. [allowMoodleTokenContentType] is an explicit
  /// compatibility option; enable it only for trusted affected platforms.
  LtiOAuthClient({
    required this.client,
    required this.signer,
    DateTime Function()? clock,
    this.timeout = const Duration(seconds: 10),
    this.refreshLeeway = const Duration(seconds: 30),
    this.maxEntries = 100,
    this.maxResponseBytes = 65536,
    this.allowMoodleTokenContentType = false,
  }) : _clock = clock ?? DateTime.now {
    if (timeout <= Duration.zero ||
        refreshLeeway < Duration.zero ||
        maxEntries <= 0 ||
        maxResponseBytes <= 0) {
      throw ArgumentError('Invalid OAuth client limits.');
    }
  }

  /// Caller-owned HTTP transport; close it when the host application stops.
  final http.Client client;

  /// Tool signer used to create a fresh assertion for each token request.
  final LtiJwtSigner signer;
  final DateTime Function() _clock;

  /// Deadline for assertion creation and the token request; default 10 seconds.
  final Duration timeout;

  /// Tokens this close to expiry are not reused; defaults to 30 seconds.
  final Duration refreshLeeway;

  /// Maximum cached tokens and maximum concurrent distinct token requests.
  final int maxEntries;

  /// Maximum token-response bytes accepted; defaults to 65536.
  final int maxResponseBytes;

  /// Compatibility for Moodle token endpoints that omit a JSON content type.
  /// Allows missing, text/html or text/plain headers, but still requires a
  /// fully valid JSON token response. Enable only for a trusted registration.
  final bool allowMoodleTokenContentType;
  final _cache = <_CacheKey, LtiAccessToken>{};
  final _pending = <_CacheKey, Future<LtiAccessToken>>{};

  /// Returns a cached or newly requested client-credentials token.
  ///
  /// [registration] must come from trusted configuration. [scopes] must be a
  /// nonempty set of OAuth scope tokens; [deploymentId], when supplied, must
  /// belong to the registration. Invalid arguments throw [ArgumentError].
  ///
  /// Cache keys use registration object identity, deployment and the exact
  /// requested scope set. Concurrent matching requests share one fetch.
  /// Throws [LtiOAuthException] for request or response failures. No redirects
  /// are followed; never log the returned token value.
  Future<LtiAccessToken> accessToken({
    required LtiRegistration registration,
    required Set<String> scopes,
    String? deploymentId,
  }) async {
    if (registration.tokenEndpoint == null ||
        scopes.isEmpty ||
        scopes.any((s) => !_scope.hasMatch(s)) ||
        (deploymentId != null &&
            !registration.deploymentIds.contains(deploymentId))) {
      throw ArgumentError(
        'Expected a token endpoint, valid scopes and deployment.',
      );
    }
    final sorted = scopes.toList()..sort();
    final key = (registration, deploymentId, sorted.join(' '));
    final now = _clock();
    _cache.removeWhere(
      (_, token) => !token.expiresAt.isAfter(now.add(refreshLeeway)),
    );
    final cached = _cache[key];
    if (cached != null) return cached;
    final pending = _pending[key];
    if (pending != null) return pending;
    if (_pending.length >= maxEntries) {
      throw const LtiOAuthException(LtiOAuthErrorCode.capacity);
    }
    final future = _fetch(registration, deploymentId, sorted);
    _pending[key] = future;
    try {
      final token = await future;
      if (token.expiresAt.isAfter(_clock().add(refreshLeeway))) {
        if (_cache.length >= maxEntries) _cache.remove(_cache.keys.first);
        _cache[key] = token;
      }
      return token;
    } finally {
      _pending.remove(key);
    }
  }

  /// Evict the exact rejected token, without discarding a newer replacement.
  /// Call after a service rejects it; retry policy belongs to the application.
  void invalidate(LtiAccessToken token) =>
      _cache.removeWhere((_, entry) => identical(entry, token));

  static final _scope = RegExp(r'^[\x21\x23-\x5B\x5D-\x7E]+$');
  static final _bearer = RegExp(r'^[A-Za-z0-9._~+/-]+=*$');

  Future<LtiAccessToken> _fetch(
    LtiRegistration registration,
    String? deploymentId,
    List<String> scopes,
  ) async {
    final abort = Completer<void>();
    final started = _clock();
    int? statusCode;
    LtiOAuthResponseIssue? issue;
    try {
      return await (() async {
        final assertion = await signer.createClientAssertion(
          registration: registration,
          deploymentId: deploymentId,
        );
        if (abort.isCompleted) throw TimeoutException('Token request expired.');
        final request = http.AbortableRequest(
          'POST',
          registration.tokenEndpoint!,
          abortTrigger: abort.future,
        )..followRedirects = false;
        request.headers['accept'] = 'application/json';
        request.bodyFields = {
          'grant_type': 'client_credentials',
          'client_assertion_type':
              'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
          'client_assertion': assertion,
          'scope': scopes.join(' '),
        };
        final response = await client.send(request);
        statusCode = response.statusCode;
        if (response.statusCode != 200) {
          await response.stream.listen(null).cancel();
          throw LtiOAuthException(
            response.statusCode == 429 || response.statusCode >= 500
                ? LtiOAuthErrorCode.unavailable
                : LtiOAuthErrorCode.rejected,
            statusCode: response.statusCode,
          );
        }
        issue = LtiOAuthResponseIssue.contentType;
        final mediaType = response.headers['content-type']
            ?.split(';')
            .first
            .trim()
            .toLowerCase();
        final moodleContentType =
            allowMoodleTokenContentType &&
            (mediaType == null ||
                mediaType == '' ||
                mediaType == 'text/html' ||
                mediaType == 'text/plain');
        if (mediaType != 'application/json' && !moodleContentType) {
          await response.stream.listen(null).cancel();
          throw const FormatException();
        }
        issue = LtiOAuthResponseIssue.responseSize;
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw const FormatException();
          }
          bytes.addAll(chunk);
        }
        issue = LtiOAuthResponseIssue.json;
        final data = jsonDecode(utf8.decode(bytes));
        if (data is! Map<String, dynamic>) throw const FormatException();
        final value = data['access_token'];
        final type = data['token_type'];
        final lifetime = data['expires_in'];
        issue = LtiOAuthResponseIssue.accessToken;
        if (value is! String || !_bearer.hasMatch(value)) {
          throw const FormatException();
        }
        issue = LtiOAuthResponseIssue.tokenType;
        if (type is! String || type.toLowerCase() != 'bearer') {
          throw const FormatException();
        }
        issue = LtiOAuthResponseIssue.expiresIn;
        if (lifetime is! int || lifetime <= 0 || lifetime > 2147483647) {
          throw const FormatException();
        }
        issue = LtiOAuthResponseIssue.scope;
        final scopeValue = data['scope'];
        final granted = data.containsKey('scope')
            ? (scopeValue is String
                  ? scopeValue.split(' ').toSet()
                  : <String>{})
            : scopes.toSet();
        if (granted.isEmpty || granted.any((s) => !_scope.hasMatch(s))) {
          throw const FormatException();
        }
        if (!granted.containsAll(scopes)) {
          throw const LtiOAuthException(LtiOAuthErrorCode.insufficientScope);
        }
        issue = LtiOAuthResponseIssue.expired;
        final expiry = started.add(Duration(seconds: lifetime));
        if (!expiry.isAfter(_clock())) throw const FormatException();
        return LtiAccessToken._(value, granted, expiry);
      })().timeout(timeout);
    } on LtiOAuthException {
      rethrow;
    } on FormatException {
      throw LtiOAuthException(
        LtiOAuthErrorCode.invalidResponse,
        statusCode: statusCode,
        responseIssue: issue,
      );
    } on Exception {
      throw const LtiOAuthException(LtiOAuthErrorCode.unavailable);
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }
}
