import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'oauth.dart';
import 'service_models.dart';
import 'tool.dart';

/// Stable categories for service capability, transport and response failures.
enum LtiServiceErrorCode {
  /// Transport failure, timeout, rate limiting, or a platform 5xx response.
  unavailable,

  /// The service returned a status not accepted by the requested operation.
  rejected,

  /// The response media type, JSON, fields or pagination were invalid.
  invalidResponse,

  /// An endpoint violates HTTPS or configured origin restrictions.
  untrustedDestination,

  /// The verified launch lacks the endpoint, scope or version required.
  missingCapability,

  /// Pagination exceeded the page limit or repeated a previously visited URL.
  paginationLimit,
}

/// Safe categories only; no platform values or personal data.
enum LtiServiceResponseIssue {
  /// The response does not use the expected service media type.
  contentType,

  /// The response body exceeds the configured byte limit.
  responseSize,

  /// The response cannot be decoded as UTF-8 JSON.
  json,

  /// The service payload fails its model validation.
  payload,

  /// A pagination Link header is malformed or ambiguous.
  pagination,

  /// The NRPS root object or container identifier is invalid.
  membershipContainer,

  /// The NRPS context object or its identifier is invalid.
  membershipContext,

  /// The membership context ID differs from the verified launch context.
  contextMismatch,

  /// The NRPS members field is not an array.
  members,

  /// A member entry is malformed; inspect the exception's member-field detail.
  member,

  /// A normal membership page contains a deleted entry reserved for differences.
  membershipStatus,
}

/// Redacted service failure containing fixed categories rather than response data.
final class LtiServiceException implements Exception {
  /// Creates a service failure with optional HTTP and validation metadata.
  const LtiServiceException(
    this.code, {
    this.statusCode,
    this.responseIssue,
    this.memberField,
  });

  /// Stable failure category for application error handling.
  final LtiServiceErrorCode code;

  /// HTTP status when available; null for failures without captured status.
  final int? statusCode;

  /// Fixed validation category for an invalid response, when available.
  final LtiServiceResponseIssue? responseIssue;

  /// Fixed NRPS field category when a member failed validation; otherwise null.
  final LtiMemberField? memberField;
  @override
  String toString() =>
      'LtiServiceException(${code.name}, status=$statusCode, issue=${responseIssue?.name}, memberField=${memberField?.name})';
}

/// Transport bound to one verified launch. Origin permissions must be supplied
/// by the administrator, never copied from a claim or a service response.
/// The caller owns the HTTP client. Application authorization remains required.
final class LtiServiceClient {
  /// Binds service calls to one verified [launch] and trusted [allowedOrigins].
  ///
  /// Origins must be administrator-configured HTTPS origins without paths,
  /// queries or fragments. Never build this allowlist from launch claims.
  /// Invalid configuration throws [ArgumentError] or [FormatException].
  /// [client] remains caller-owned. Requests do not follow redirects or retry.
  ///
  /// The origin policy does not pin DNS/IP addresses; production deployments
  /// should enforce network egress restrictions. Application authorization is
  /// required before accessing rosters or changing grades.
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

  /// Verified launch that supplies registration, deployment and service claims.
  final LtiLaunch launch;

  /// Reusable token client; tokens are requested with the required operation scope.
  final LtiOAuthClient oauth;

  /// Caller-owned HTTP transport used for service requests.
  final http.Client client;

  /// Immutable normalized trusted HTTPS origins for credential-bearing requests.
  final Set<String> allowedOrigins;

  /// Deadline for each service HTTP request and body read; default 10 seconds.
  /// OAuth token acquisition has its own independently configured timeout.
  final Duration timeout;

  /// Maximum bytes read from a JSON service response; defaults to one MiB.
  final int maxResponseBytes;

  /// Maximum pages fetched by each automatic pagination stream; defaults to 100.
  final int maxPages;

  /// AGS client bound to this launch; capability checks occur on operation use.
  LtiAgsClient get ags => LtiAgsClient._(this);

  /// NRPS client bound to this launch; capability checks occur on operation use.
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

/// Assignment and Grade Services operations for a verified launch.
///
/// Obtain from [LtiServiceClient.ags]. Operations require the advertised
/// endpoint and scope and can throw [LtiServiceException] or [LtiOAuthException].
/// Reads prefer the read-only line-item scope when advertised; writes are
/// never automatically retried, even after a timeout or rejected token.
final class LtiAgsClient {
  LtiAgsClient._(this._service);
  final LtiServiceClient _service;

  /// Wire media type for a single AGS gradebook column.
  static const lineItemMediaType = 'application/vnd.ims.lis.v2.lineitem+json';

  /// Wire media type for an AGS gradebook-column collection.
  static const lineItemsMediaType =
      'application/vnd.ims.lis.v2.lineitemcontainer+json';

  /// Wire media type for a collection of platform-computed results.
  static const resultsMediaType =
      'application/vnd.ims.lis.v2.resultcontainer+json';

  /// Wire media type for publishing an AGS score update.
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

  /// Reads one page of gradebook columns using an advertised line-item scope.
  ///
  /// [resourceLinkId], [resourceId] and [tag] filter the initial request.
  /// [limit] is a positive page-size hint, not a guaranteed count.
  /// When [page] is supplied, its opaque URL replaces filters and pagination
  /// parameters and must share the configured collection origin.
  /// Throws [ArgumentError] for a nonpositive limit; see [LtiAgsClient] for
  /// service errors. Follow the returned page's next link or use [allLineItems].
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

  /// Lazily streams columns across pages, applying filters to the initial URL.
  ///
  /// [limit] must be positive when supplied. Next links are followed unchanged.
  /// A page cycle or the configured page bound emits [LtiServiceException].
  /// Earlier items may already have been delivered when a later page fails.
  /// The stream performs network requests only when listened to.
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

  /// Reads one gradebook column from [lineItem] or the launch's single-item URL.
  ///
  /// Fails with [LtiServiceException] when no endpoint or suitable read scope
  /// is advertised. The URL must satisfy the service origin policy.
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

  /// Creates a gradebook column and returns the platform definition with its ID.
  ///
  /// Requires the full line-item scope. [item] must have no ID or this throws
  /// [ArgumentError]. A failed request may still have created a column on the
  /// platform; reconcile using your own resource ID/tag before retrying.
  /// See [LtiAgsClient] for service and OAuth failures.
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

  /// Replaces the full column definition at [original]'s platform ID.
  ///
  /// Requires the full line-item scope. [original] must have an ID;
  /// [replacement] may omit its ID but cannot change the ID or resource-link
  /// binding. Invalid identities throw [ArgumentError]. Preserve fields and
  /// extensions you wish to keep; this is PUT, not a partial patch.
  ///
  /// Returns the platform's resulting definition. There are no retries;
  /// [LtiServiceException] and [LtiOAuthException] report remote failures.
  ///
  /// ```dart
  /// final updated = await services.ags.updateLineItem(
  ///   existing,
  ///   LtiLineItem.fromJson({...existing.json, 'label': 'Revised title'}),
  /// );
  /// ```
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

  /// Deletes [lineItem], defaulting to the launch's single-item URL.
  ///
  /// Requires the full line-item scope. This may remove associated grades;
  /// the application must authorize the action and track item ownership.
  /// There are no automatic retries. Service failures throw [LtiServiceException]
  /// or [LtiOAuthException].
  Future<void> deleteLineItem({Uri? lineItem}) async {
    await _service._send(
      'DELETE',
      _item(lineItem),
      _scope(LtiServiceScopes.lineItem),
      statuses: {204},
      jsonResponse: false,
    );
  }

  /// Publishes [score] to [lineItem] or the launch's single-item endpoint.
  ///
  /// Requires the score scope. A null score value explicitly clears a prior
  /// score. Completion means the HTTP request was accepted, not that the
  /// gradebook has already propagated the result; use [results] to read back.
  ///
  /// Persist and order increasing timestamps per item/user in the host
  /// application. Writes are never automatically retried. A transport failure
  /// may occur after the platform applied the score. Failures are reported as
  /// [LtiServiceException] or [LtiOAuthException].
  ///
  /// ```dart
  /// await services.ags.publishScore(LtiScore(
  ///   userId: learnerSubject,
  ///   timestamp: nextPersistedUpdateTime,
  ///   activityProgress: LtiActivityProgress.completed,
  ///   gradingProgress: LtiGradingProgress.fullyGraded,
  ///   scoreGiven: 80,
  ///   scoreMaximum: 100,
  /// ), lineItem: createdItem.id);
  /// ```
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

  /// Reads one page of platform-computed results for a gradebook column.
  ///
  /// [lineItem] defaults to the launch's single-item URL. [userId] optionally
  /// filters by platform subject. [limit] must be positive when supplied.
  /// [page] is an opaque continuation URL and replaces initial query filters.
  /// Requires the result-read scope. The platform may scale or override scores;
  /// do not assume results equal the values previously submitted.
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

  /// Lazily streams results across pages for [lineItem] and optional [userId].
  ///
  /// Uses the same endpoint defaults and scope as [results]. [limit] is a
  /// positive page-size hint. Streams may emit some results before a later
  /// request fails; cycles and the configured page bound produce
  /// [LtiServiceException].
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

/// Names and Role Provisioning Services for a verified launch.
///
/// Obtain from [LtiServiceClient.nrps]. Requires advertised version `2.0`.
/// Operations can throw [LtiOAuthException] or [LtiServiceException]; the host
/// must authorize roster access and handle optional personal fields.
final class LtiNrpsClient {
  LtiNrpsClient._(this._service);
  final LtiServiceClient _service;

  /// Wire media type for an NRPS 2.0 membership container.
  static const mediaType =
      'application/vnd.ims.lti-nrps.v2.membershipcontainer+json';
  Uri get _endpoint {
    final cap = _service.launch.nrps;
    if (cap == null || !cap.versions.contains('2.0')) {
      throw const LtiServiceException(LtiServiceErrorCode.missingCapability);
    }
    return cap.memberships;
  }

  /// Reads one page of memberships, optionally filtered by role or resource.
  ///
  /// [role] is passed to the platform unchanged. [resourceLinkId] becomes the
  /// `rlid` filter. [limit] must be positive when provided. [page] supplies an
  /// opaque continuation URL, replacing these query filters.
  ///
  /// Set [differences] only when reading a changes feed; it permits deleted
  /// memberships. When a launch has a context, the response ID must match it.
  /// Service, validation and destination failures throw [LtiServiceException];
  /// token failures throw [LtiOAuthException].
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

  /// Lazily streams memberships, following same-origin continuation links.
  ///
  /// [role], [resourceLinkId] and positive [limit] apply to the initial request.
  /// Pass a previously returned [differencesUrl] to read changes including
  /// deleted members; its opaque query replaces the other filters.
  ///
  /// A page cycle or configured page limit emits [LtiServiceException].
  /// Earlier members may already have been delivered when a later page fails.
  /// Store changes-feed cursors only after successfully processing the stream.
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
