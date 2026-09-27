import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'oauth.dart';
import 'service_models.dart';
import 'tool.dart';

enum LtiServiceErrorCode {
  unavailable,
  rejected,
  invalidResponse,
  untrustedDestination,
  missingCapability,
  paginationLimit,
}

/// Safe categories only; no platform values or personal data.
enum LtiServiceResponseIssue {
  contentType,
  responseSize,
  json,
  payload,
  pagination,
  membershipContainer,
  membershipContext,
  contextMismatch,
  members,
  member,
  membershipStatus,
}

final class LtiServiceException implements Exception {
  const LtiServiceException(
    this.code, {
    this.statusCode,
    this.responseIssue,
    this.memberField,
  });
  final LtiServiceErrorCode code;
  final int? statusCode;
  final LtiServiceResponseIssue? responseIssue;
  final LtiMemberField? memberField;
  @override
  String toString() =>
      'LtiServiceException(${code.name}, status=$statusCode, issue=${responseIssue?.name}, memberField=${memberField?.name})';
}

/// Transport bound to one verified launch. Origin permissions must be supplied
/// by the administrator, never copied from a claim or a service response.
/// The caller owns the HTTP client. Application authorization remains required.
final class LtiServiceClient {
  LtiServiceClient({
    required this.launch,
    required this.oauth,
    required this.client,
    required Set<Uri> allowedOrigins,
    this.timeout = const Duration(seconds: 10),
    this.maxResponseBytes = 1048576,
    this.maxPages = 100,
  }) : allowedOrigins = Set.unmodifiable(
         allowedOrigins.map((u) {
           serviceUri(u.toString());
           if (u.hasQuery || (u.path.isNotEmpty && u.path != '/')) {
             throw ArgumentError('Service permissions must be HTTPS origins.');
           }
           return u.origin;
         }),
       ) {
    if (this.allowedOrigins.isEmpty ||
        timeout <= Duration.zero ||
        maxResponseBytes <= 0 ||
        maxPages <= 0) {
      throw ArgumentError('Invalid service client limits.');
    }
  }
  final LtiLaunch launch;
  final LtiOAuthClient oauth;
  final http.Client client;
  final Set<String> allowedOrigins;
  final Duration timeout;
  final int maxResponseBytes;
  final int maxPages;
  LtiAgsClient get ags => LtiAgsClient._(this);
  LtiNrpsClient get nrps => LtiNrpsClient._(this);

  void _check(Uri uri, {Uri? pageOrigin}) {
    try {
      serviceUri(uri.toString());
    } on FormatException {
      throw const LtiServiceException(LtiServiceErrorCode.untrustedDestination);
    }
    if (!allowedOrigins.contains(uri.origin) ||
        (pageOrigin != null && pageOrigin.origin != uri.origin)) {
      throw const LtiServiceException(LtiServiceErrorCode.untrustedDestination);
    }
  }

  Future<_Reply> _send(
    String method,
    Uri uri,
    String scope, {
    required Set<int> statuses,
    String? mediaType,
    Map<String, Object?>? body,
    bool jsonResponse = true,
  }) async {
    // Check BEFORE obtaining or forwarding any credentials.
    _check(uri);
    final token = await oauth.accessToken(
      registration: launch.registration,
      scopes: {scope},
      deploymentId: launch.deploymentId,
    );
    final abort = Completer<void>();
    int? statusCode;
    LtiServiceResponseIssue? issue;
    try {
      return await (() async {
        final request = http.AbortableRequest(
          method,
          uri,
          abortTrigger: abort.future,
        )..followRedirects = false;
        request.headers['authorization'] = 'Bearer ${token.value}';
        if (mediaType != null) request.headers['accept'] = mediaType;
        if (body != null) {
          request.bodyBytes = utf8.encode(jsonEncode(body));
          request.headers['content-type'] = mediaType!;
        }
        final response = await client.send(request);
        statusCode = response.statusCode;
        if (!statuses.contains(response.statusCode)) {
          await response.stream.listen(null).cancel();
          if (response.statusCode == 401) oauth.invalidate(token);
          throw LtiServiceException(
            response.statusCode == 429 || response.statusCode >= 500
                ? LtiServiceErrorCode.unavailable
                : LtiServiceErrorCode.rejected,
            statusCode: response.statusCode,
          );
        }
        if (!jsonResponse) {
          await response.stream.listen(null).cancel();
          return _Reply(null, response.headers, response.statusCode);
        }
        issue = LtiServiceResponseIssue.contentType;
        if (response.headers['content-type']
                ?.split(';')
                .first
                .trim()
                .toLowerCase() !=
            mediaType) {
          await response.stream.listen(null).cancel();
          throw const FormatException();
        }
        issue = LtiServiceResponseIssue.responseSize;
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw const FormatException();
          }
          bytes.addAll(chunk);
        }
        issue = LtiServiceResponseIssue.json;
        return _Reply(
          jsonDecode(utf8.decode(bytes)),
          response.headers,
          response.statusCode,
        );
      })().timeout(timeout);
    } on LtiServiceException {
      rethrow;
    } on FormatException {
      throw LtiServiceException(
        LtiServiceErrorCode.invalidResponse,
        statusCode: statusCode,
        responseIssue: issue,
      );
    } on Exception {
      throw const LtiServiceException(LtiServiceErrorCode.unavailable);
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Map<String, Uri> _links(_Reply reply, Uri current) => _parse(
    () {
      final header = reply.headers['link'];
      if (header == null) return <String, Uri>{};
      final links = <String, Uri>{};
      for (final entry in _splitLinks(header)) {
        final match = RegExp(r'^\s*<([^>]*)>(.*)$').firstMatch(entry);
        if (match == null) throw const FormatException();
        final params = match.group(2)!;
        // Anchored links have a different context; do not follow them.
        if (RegExp(r';\s*anchor\s*=', caseSensitive: false).hasMatch(params)) {
          continue;
        }
        final rel = RegExp(
          r';\s*rel\s*=\s*(?:"([^"]*)"|([^;\s]+))',
          caseSensitive: false,
        ).allMatches(params).toList();
        if (rel.length > 1) throw const FormatException();
        if (rel.isEmpty) continue;
        for (final relation
            in (rel.single.group(1) ?? rel.single.group(2)!).split(' ')) {
          if (relation != 'next' && relation != 'differences') continue;
          final uri = current.resolve(match.group(1)!);
          _check(uri, pageOrigin: current);
          if (links.containsKey(relation)) throw const FormatException();
          links[relation] = uri;
        }
      }
      return links;
    },
    statusCode: reply.statusCode,
    issue: LtiServiceResponseIssue.pagination,
  );

  Stream<T> _all<T>(
    Uri start,
    Future<LtiServicePage<T>> Function(Uri) fetch,
  ) async* {
    Uri? next = start;
    final visited = <Uri>{};
    while (next != null) {
      _check(next, pageOrigin: start);
      if (visited.length >= maxPages || !visited.add(next)) {
        throw const LtiServiceException(LtiServiceErrorCode.paginationLimit);
      }
      final page = await fetch(next);
      for (final item in page.items) {
        yield item;
      }
      next = page.next;
    }
  }
}

final class _Reply {
  const _Reply(this.data, this.headers, this.statusCode);
  final int statusCode;
  final Object? data;
  final Map<String, String> headers;
}

T _parse<T>(
  T Function() parse, {
  int? statusCode,
  LtiServiceResponseIssue issue = LtiServiceResponseIssue.payload,
}) {
  try {
    return parse();
  } on MemberFormatException catch (error) {
    throw LtiServiceException(
      LtiServiceErrorCode.invalidResponse,
      statusCode: statusCode,
      responseIssue: issue,
      memberField: error.field,
    );
  } on LtiException {
    throw LtiServiceException(
      LtiServiceErrorCode.invalidResponse,
      statusCode: statusCode,
      responseIssue: issue,
    );
  } on FormatException {
    throw LtiServiceException(
      LtiServiceErrorCode.invalidResponse,
      statusCode: statusCode,
      responseIssue: issue,
    );
  }
}

/// Split Link field values without splitting commas in URI references/quotes.
List<String> _splitLinks(String header) {
  final result = <String>[];
  var start = 0;
  var angle = false;
  var quote = false;
  var escape = false;
  for (var i = 0; i < header.length; i++) {
    final char = header[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (quote && char == r'\') {
      escape = true;
      continue;
    }
    if (!angle && char == '"') {
      quote = !quote;
      continue;
    }
    if (!quote) {
      if (char == '<') angle = true;
      if (char == '>') angle = false;
      if (char == ',' && !angle) {
        result.add(header.substring(start, i));
        start = i + 1;
      }
    }
  }
  if (quote || angle || escape) throw const FormatException();
  result.add(header.substring(start));
  return result;
}

Uri _query(Uri uri, Map<String, String?> values) {
  final present = Map<String, String>.fromEntries(
    values.entries
        .where((e) => e.value != null)
        .map((e) => MapEntry(e.key, e.value!)),
  );
  return present.isEmpty
      ? uri
      : uri.replace(queryParameters: {...uri.queryParametersAll, ...present});
}

void _limit(int? limit) {
  if (limit != null && limit <= 0) {
    throw ArgumentError('Limit must be positive.');
  }
}

Uri _append(Uri uri, String suffix) => uri.replace(
  path:
      '${uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path}/$suffix',
);

final class LtiAgsClient {
  LtiAgsClient._(this._service);
  final LtiServiceClient _service;
  static const lineItemMediaType = 'application/vnd.ims.lis.v2.lineitem+json';
  static const lineItemsMediaType =
      'application/vnd.ims.lis.v2.lineitemcontainer+json';
  static const resultsMediaType =
      'application/vnd.ims.lis.v2.resultcontainer+json';
  static const scoreMediaType = 'application/vnd.ims.lis.v1.score+json';
  LtiAgsEndpoints get _cap =>
      _service.launch.ags ??
      (throw const LtiServiceException(LtiServiceErrorCode.missingCapability));
  String _scope(String scope) {
    if (!_cap.scopes.contains(scope)) {
      throw const LtiServiceException(LtiServiceErrorCode.missingCapability);
    }
    return scope;
  }

  String get _readScope => _scope(
    _cap.scopes.contains(LtiServiceScopes.lineItemReadonly)
        ? LtiServiceScopes.lineItemReadonly
        : LtiServiceScopes.lineItem,
  );
  Uri get _container =>
      _cap.lineItems ??
      (throw const LtiServiceException(LtiServiceErrorCode.missingCapability));
  Uri _item(Uri? item) =>
      item ??
      _cap.lineItem ??
      (throw const LtiServiceException(LtiServiceErrorCode.missingCapability));

  Future<LtiServicePage<LtiLineItem>> lineItems({
    String? resourceLinkId,
    String? resourceId,
    String? tag,
    int? limit,
    Uri? page,
  }) {
    _limit(limit);
    final uri =
        page ??
        _query(_container, {
          'resource_link_id': resourceLinkId,
          'resource_id': resourceId,
          'tag': tag,
          'limit': limit?.toString(),
        });
    _service._check(uri, pageOrigin: _container);
    return _lineItems(uri);
  }

  Future<LtiServicePage<LtiLineItem>> _lineItems(Uri uri) async {
    final reply = await _service._send(
      'GET',
      uri,
      _readScope,
      statuses: {200},
      mediaType: lineItemsMediaType,
    );
    return _parse(() {
      if (reply.data is! List) throw const FormatException();
      final items = (reply.data! as List).map((d) => _lineItem(d)).toList();
      return LtiServicePage(
        items: items,
        next: _service._links(reply, uri)['next'],
      );
    });
  }

  Stream<LtiLineItem> allLineItems({
    String? resourceLinkId,
    String? resourceId,
    String? tag,
    int? limit,
  }) {
    _limit(limit);
    return _service._all(
      _query(_container, {
        'resource_link_id': resourceLinkId,
        'resource_id': resourceId,
        'tag': tag,
        'limit': limit?.toString(),
      }),
      _lineItems,
    );
  }

  LtiLineItem _lineItem(Object? data) {
    final item = LtiLineItem.fromJson(serviceObject(data));
    if (item.id == null) throw const FormatException();
    _service._check(item.id!);
    return item;
  }

  Future<LtiLineItem> getLineItem({Uri? lineItem}) async {
    final reply = await _service._send(
      'GET',
      _item(lineItem),
      _readScope,
      statuses: {200},
      mediaType: lineItemMediaType,
    );
    return _parse(() => _lineItem(reply.data));
  }

  Future<LtiLineItem> createLineItem(LtiLineItem item) async {
    if (item.id != null) {
      throw ArgumentError('New line items cannot specify an ID.');
    }
    final reply = await _service._send(
      'POST',
      _container,
      _scope(LtiServiceScopes.lineItem),
      statuses: {201},
      mediaType: lineItemMediaType,
      body: item.toJson(),
    );
    return _parse(() => _lineItem(reply.data));
  }

  /// PUT replaces the entire definition. Preserve the current id/resource link.
  Future<LtiLineItem> updateLineItem(
    LtiLineItem original,
    LtiLineItem replacement,
  ) async {
    if (original.id == null ||
        (replacement.id != null && replacement.id != original.id) ||
        original.resourceLinkId != replacement.resourceLinkId) {
      throw ArgumentError(
        'Line item identity and resource binding cannot change.',
      );
    }
    final reply = await _service._send(
      'PUT',
      original.id!,
      _scope(LtiServiceScopes.lineItem),
      statuses: {200, 201},
      mediaType: lineItemMediaType,
      body: replacement.toJson(),
    );
    return _parse(() => _lineItem(reply.data));
  }

  Future<void> deleteLineItem({Uri? lineItem}) async {
    await _service._send(
      'DELETE',
      _item(lineItem),
      _scope(LtiServiceScopes.lineItem),
      statuses: {204},
      jsonResponse: false,
    );
  }

  /// Persist and order monotonically increasing timestamps per line item/user
  /// in the host application. Writes are never automatically retried.
  Future<void> publishScore(LtiScore score, {Uri? lineItem}) async {
    await _service._send(
      'POST',
      _append(_item(lineItem), 'scores'),
      _scope(LtiServiceScopes.score),
      statuses: {200, 204},
      mediaType: scoreMediaType,
      body: score.toJson(),
      jsonResponse: false,
    );
  }

  Future<LtiServicePage<LtiResult>> results({
    Uri? lineItem,
    String? userId,
    int? limit,
    Uri? page,
  }) {
    _limit(limit);
    final base = _append(_item(lineItem), 'results');
    final uri =
        page ?? _query(base, {'user_id': userId, 'limit': limit?.toString()});
    _service._check(uri, pageOrigin: base);
    return _results(uri);
  }

  Future<LtiServicePage<LtiResult>> _results(Uri uri) async {
    final reply = await _service._send(
      'GET',
      uri,
      _scope(LtiServiceScopes.resultReadonly),
      statuses: {200},
      mediaType: resultsMediaType,
    );
    return _parse(() {
      if (reply.data is! List) throw const FormatException();
      return LtiServicePage(
        items: (reply.data! as List).map(
          (d) => LtiResult.fromJson(serviceObject(d)),
        ),
        next: _service._links(reply, uri)['next'],
      );
    });
  }

  Stream<LtiResult> allResults({Uri? lineItem, String? userId, int? limit}) {
    _limit(limit);
    return _service._all(
      _query(_append(_item(lineItem), 'results'), {
        'user_id': userId,
        'limit': limit?.toString(),
      }),
      _results,
    );
  }
}

final class LtiNrpsClient {
  LtiNrpsClient._(this._service);
  final LtiServiceClient _service;
  static const mediaType =
      'application/vnd.ims.lti-nrps.v2.membershipcontainer+json';
  Uri get _endpoint {
    final cap = _service.launch.nrps;
    if (cap == null || !cap.versions.contains('2.0')) {
      throw const LtiServiceException(LtiServiceErrorCode.missingCapability);
    }
    return cap.memberships;
  }

  Future<LtiServicePage<LtiMember>> memberships({
    String? role,
    String? resourceLinkId,
    int? limit,
    Uri? page,
    bool differences = false,
  }) {
    _limit(limit);
    final uri =
        page ??
        _query(_endpoint, {
          'role': role,
          'rlid': resourceLinkId,
          'limit': limit?.toString(),
        });
    _service._check(uri, pageOrigin: _endpoint);
    return _memberships(uri, differences);
  }

  Future<LtiServicePage<LtiMember>> _memberships(
    Uri uri,
    bool differences,
  ) async {
    final reply = await _service._send(
      'GET',
      uri,
      LtiServiceScopes.membershipReadonly,
      statuses: {200},
      mediaType: mediaType,
    );
    T parse<T>(LtiServiceResponseIssue issue, T Function() read) =>
        _parse(read, statusCode: reply.statusCode, issue: issue);
    final data = parse(LtiServiceResponseIssue.membershipContainer, () {
      final data = serviceObject(reply.data);
      serviceUri(data['id']);
      return data;
    });
    final context = parse(LtiServiceResponseIssue.membershipContext, () {
      final context = serviceObject(data['context']);
      serviceString(context, 'id');
      return context;
    });
    if (_service.launch.context != null &&
        _service.launch.context!.id != context['id']) {
      throw LtiServiceException(
        LtiServiceErrorCode.invalidResponse,
        statusCode: reply.statusCode,
        responseIssue: LtiServiceResponseIssue.contextMismatch,
      );
    }
    final rawMembers = parse(LtiServiceResponseIssue.members, () {
      if (data['members'] is! List) throw const FormatException();
      return data['members']! as List;
    });
    final members = parse(
      LtiServiceResponseIssue.member,
      () =>
          rawMembers.map((m) => LtiMember.fromJson(serviceObject(m))).toList(),
    );
    if (!differences &&
        members.any((m) => m.status == LtiMembershipStatus.deleted)) {
      throw LtiServiceException(
        LtiServiceErrorCode.invalidResponse,
        statusCode: reply.statusCode,
        responseIssue: LtiServiceResponseIssue.membershipStatus,
      );
    }
    final links = _service._links(reply, uri);
    return LtiServicePage(
      items: members,
      context: context,
      next: links['next'],
      differences: links['differences'],
    );
  }

  Stream<LtiMember> allMemberships({
    String? role,
    String? resourceLinkId,
    int? limit,
    Uri? differencesUrl,
  }) {
    _limit(limit);
    final uri =
        differencesUrl ??
        _query(_endpoint, {
          'role': role,
          'rlid': resourceLinkId,
          'limit': limit?.toString(),
        });
    _service._check(uri, pageOrigin: _endpoint);
    return _service._all(uri, (u) => _memberships(u, differencesUrl != null));
  }
}
