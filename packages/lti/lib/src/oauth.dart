import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'signing.dart';

enum LtiOAuthErrorCode {
  rejected,
  unavailable,
  invalidResponse,
  insufficientScope,
  capacity,
}

/// Safe diagnostics: never includes assertions, tokens or platform response text.
final class LtiOAuthException implements Exception {
  const LtiOAuthException(this.code, {this.statusCode});
  final LtiOAuthErrorCode code;
  final int? statusCode;
  @override
  String toString() => 'LtiOAuthException(${code.name}, status=$statusCode)';
}

final class LtiAccessToken {
  LtiAccessToken._(this.value, Set<String> scopes, this.expiresAt)
    : scopes = Set.unmodifiable(scopes);

  /// Secret bearer credential. Do not log or return to a browser.
  final String value;
  final Set<String> scopes;
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
  LtiOAuthClient({
    required this.client,
    required this.signer,
    DateTime Function()? clock,
    this.timeout = const Duration(seconds: 10),
    this.refreshLeeway = const Duration(seconds: 30),
    this.maxEntries = 100,
    this.maxResponseBytes = 65536,
  }) : _clock = clock ?? DateTime.now {
    if (timeout <= Duration.zero ||
        refreshLeeway < Duration.zero ||
        maxEntries <= 0 ||
        maxResponseBytes <= 0) {
      throw ArgumentError('Invalid OAuth client limits.');
    }
  }
  final http.Client client;
  final LtiJwtSigner signer;
  final DateTime Function() _clock;
  final Duration timeout;
  final Duration refreshLeeway;
  final int maxEntries;
  final int maxResponseBytes;
  final _cache = <_CacheKey, LtiAccessToken>{};
  final _pending = <_CacheKey, Future<LtiAccessToken>>{};

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
        if (response.statusCode != 200) {
          await response.stream.listen(null).cancel();
          throw LtiOAuthException(
            response.statusCode == 429 || response.statusCode >= 500
                ? LtiOAuthErrorCode.unavailable
                : LtiOAuthErrorCode.rejected,
            statusCode: response.statusCode,
          );
        }
        if (response.headers['content-type']
                ?.split(';')
                .first
                .trim()
                .toLowerCase() !=
            'application/json') {
          await response.stream.listen(null).cancel();
          throw const FormatException();
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw const FormatException();
          }
          bytes.addAll(chunk);
        }
        final data = jsonDecode(utf8.decode(bytes));
        if (data is! Map<String, dynamic>) throw const FormatException();
        final value = data['access_token'];
        final type = data['token_type'];
        final lifetime = data['expires_in'];
        if (value is! String ||
            !_bearer.hasMatch(value) ||
            type is! String ||
            type.toLowerCase() != 'bearer' ||
            lifetime is! int ||
            lifetime <= 0 ||
            lifetime > 2147483647) {
          throw const FormatException();
        }
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
        final expiry = started.add(Duration(seconds: lifetime));
        if (!expiry.isAfter(_clock())) throw const FormatException();
        return LtiAccessToken._(value, granted, expiry);
      })().timeout(timeout);
    } on LtiOAuthException {
      rethrow;
    } on FormatException {
      throw const LtiOAuthException(LtiOAuthErrorCode.invalidResponse);
    } on Exception {
      throw const LtiOAuthException(LtiOAuthErrorCode.unavailable);
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }
}
