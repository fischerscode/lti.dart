import 'dart:convert';

import 'models.dart';
import 'vocabularies.dart';
import 'errors.dart';

/// OAuth scope URIs used by AGS and NRPS services.
abstract final class LtiServiceScopes {
  /// Read, create, update and delete AGS gradebook columns.
  static const lineItem =
      'https://purl.imsglobal.org/spec/lti-ags/scope/lineitem';

  /// Read AGS gradebook columns without modifying them.
  static const lineItemReadonly =
      'https://purl.imsglobal.org/spec/lti-ags/scope/lineitem.readonly';

  /// Publish scores to an AGS line item's score endpoint.
  static const score = 'https://purl.imsglobal.org/spec/lti-ags/scope/score';

  /// Read platform-computed AGS results.
  static const resultReadonly =
      'https://purl.imsglobal.org/spec/lti-ags/scope/result.readonly';

  /// Read context membership and roles through NRPS.
  static const membershipReadonly =
      'https://purl.imsglobal.org/spec/lti-nrps/scope/contextmembership.readonly';
}

/// Launch claim names advertising LTI Advantage service capabilities.
abstract final class LtiServiceClaims {
  /// AGS endpoint and scope claim name.
  static const ags = 'https://purl.imsglobal.org/spec/lti-ags/claim/endpoint';

  /// NRPS endpoint and supported-version claim name.
  static const nrps =
      'https://purl.imsglobal.org/spec/lti-nrps/claim/namesroleservice';
}

/// Parses an HTTPS URL without credentials/fragments, or throws [FormatException].
Uri serviceUri(Object? value) {
  if (value is! String) {
    throw const FormatException('Expected HTTPS service URL.');
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException('Expected HTTPS service URL.');
  }
  return uri;
}

/// AGS capabilities advertised by the platform in a verified launch.
///
/// Capabilities alone do not authorize network destinations or user actions.
final class LtiAgsEndpoints {
  /// Parses AGS endpoints and scope strings.
  ///
  /// Missing, null or empty endpoint values become null. Other endpoints must
  /// be HTTPS without credentials or fragments. Invalid URLs throw
  /// [FormatException]; malformed scope arrays throw [LtiException].
  LtiAgsEndpoints.fromJson(Map<String, Object?> json)
    : scopes = Set.unmodifiable(stringList(json['scope'])),
      lineItems = json['lineitems'] == null || json['lineitems'] == ''
          ? null
          : serviceUri(json['lineitems']),
      lineItem = json['lineitem'] == null || json['lineitem'] == ''
          ? null
          : serviceUri(json['lineitem']);

  /// Immutable advertised scope set; operations still require a granted token.
  final Set<String> scopes;

  /// Optional HTTPS gradebook-column collection endpoint.
  final Uri? lineItems;

  /// Optional HTTPS endpoint for the column associated with this resource.
  final Uri? lineItem;
}

/// Membership endpoint and service versions from a verified launch.
final class LtiNrpsEndpoint {
  /// Parses an HTTPS membership URL and service-version array.
  ///
  /// Throws [FormatException] for invalid URLs or [LtiException] for malformed
  /// version arrays. Version support is checked by the NRPS client on use.
  LtiNrpsEndpoint.fromJson(Map<String, Object?> json)
    : memberships = serviceUri(json['context_memberships_url']),
      versions = List.unmodifiable(stringList(json['service_versions']));

  /// HTTPS endpoint for this context membership collection.
  final Uri memberships;

  /// Immutable advertised versions; the client requires `2.0`.
  final List<String> versions;
}

Map<String, Object?> _extensions(Map<String, Object?> values) {
  if (values.keys.any((k) {
    final uri = Uri.tryParse(k);
    return uri == null || !uri.hasScheme || uri.host.isEmpty;
  })) {
    throw ArgumentError('Extension names must be fully qualified URLs.');
  }
  // Reject non-JSON values and non-finite numbers before sending.
  jsonEncode(values);
  return freezeJson(values) as Map<String, Object?>;
}

/// Requires a string-keyed service object, or throws [FormatException].
Map<String, Object?> serviceObject(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Expected service object.');
  }
  return value;
}

/// Requires a nonempty service string, or throws [FormatException].
String serviceString(Map<String, Object?> data, String key) {
  final value = data[key];
  if (value is! String || value.isEmpty) {
    throw const FormatException('Missing service string.');
  }
  return value;
}

void _optionalStrings(Map<String, Object?> data, List<String> keys) {
  for (final key in keys) {
    if (data[key] != null && data[key] is! String) {
      throw const FormatException('Invalid service string.');
    }
  }
}

num? _number(Object? value, {bool positive = false, bool nonnegative = true}) {
  if (value == null) return null;
  if (value is! num ||
      !value.isFinite ||
      (nonnegative && value < 0) ||
      (positive && value == 0)) {
    throw const FormatException('Invalid service number.');
  }
  return value;
}

/// Parses a zoned service timestamp; absent/null/empty values return null.
/// Malformed nonempty values throw [FormatException].
DateTime? serviceDate(Object? value) {
  if (value == null || value == '') return null;
  if (value is! String || !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(value)) {
    throw const FormatException('Expected timestamp with time zone.');
  }
  final date = DateTime.tryParse(value);
  if (date == null) throw const FormatException('Invalid timestamp.');
  return date;
}

/// Immutable AGS gradebook-column definition, retaining extension fields.
final class LtiLineItem {
  /// Builds a gradebook-column definition without making a service request.
  ///
  /// [label] must be nonblank and [scoreMaximum] positive and finite. Leave
  /// [id] null for creation. Optional dates serialize in UTC. [extensions]
  /// requires fully qualified URL keys and JSON values. Invalid data throws
  /// [FormatException], [ArgumentError], or a JSON encoding error.
  factory LtiLineItem({
    required String label,
    required num scoreMaximum,
    Uri? id,
    String? resourceId,
    String? resourceLinkId,
    String? tag,
    DateTime? startDateTime,
    DateTime? endDateTime,
    bool? gradesReleased,
    Map<String, Object?> extensions = const {},
  }) => LtiLineItem.fromJson({
    ..._extensions(extensions),
    'label': label,
    'scoreMaximum': scoreMaximum,
    'id': ?id?.toString(),
    'resourceId': ?resourceId,
    'resourceLinkId': ?resourceLinkId,
    'tag': ?tag,
    'startDateTime': ?startDateTime?.toUtc().toIso8601String(),
    'endDateTime': ?endDateTime?.toUtc().toIso8601String(),
    'gradesReleased': ?gradesReleased,
  });

  /// Validates and snapshots a wire line item, retaining unknown fields.
  ///
  /// Throws [FormatException] for malformed fields. The JSON map must contain
  /// a nonblank label and positive finite maximum. This does not establish
  /// endpoint trust; the service client checks destinations before requests.
  LtiLineItem.fromJson(Map<String, Object?> data)
    : json = freezeJson(data) as Map<String, Object?> {
    if (serviceString(json, 'label').trim().isEmpty ||
        _number(json['scoreMaximum'], positive: true) == null) {
      throw const FormatException('Invalid line item.');
    }
    if (json['id'] != null) serviceUri(json['id']);
    _optionalStrings(json, ['resourceId', 'resourceLinkId', 'tag']);
    serviceDate(json['startDateTime']);
    serviceDate(json['endDateTime']);
    if (json['gradesReleased'] != null && json['gradesReleased'] is! bool) {
      throw const FormatException('Invalid gradesReleased.');
    }
  }

  /// Deeply immutable platform representation, including extension fields.
  final Map<String, Object?> json;

  /// HTTPS item endpoint assigned by the platform; null before creation.
  Uri? get id => json['id'] == null ? null : serviceUri(json['id']);

  /// Display label for the gradebook column.
  String get label => json['label']! as String;

  /// Positive finite maximum points for this gradebook column.
  num get scoreMaximum => json['scoreMaximum']! as num;

  /// Optional tool-defined resource identifier shared across related columns.
  String? get resourceId => json['resourceId'] as String?;

  /// Optional platform resource-link ID associated with this column.
  String? get resourceLinkId => json['resourceLinkId'] as String?;

  /// Optional tool-defined category or lookup tag for this column.
  String? get tag => json['tag'] as String?;

  /// Optional hint indicating whether grades are released to learners.
  bool? get gradesReleased => json['gradesReleased'] as bool?;

  /// Optional availability start; null for absent, null or empty wire values.
  DateTime? get startDateTime => serviceDate(json['startDateTime']);

  /// Optional availability end; null for absent, null or empty wire values.
  DateTime? get endDateTime => serviceDate(json['endDateTime']);

  /// Returns the unmodifiable wire representation for this line item.
  Map<String, Object?> toJson() => json;
}

/// Learner activity state, independently of grading state.
enum LtiActivityProgress {
  /// The activity has been initialized but the learner has not started.
  initialized,

  /// The learner has started the activity.
  started,

  /// The learner is still working on the activity.
  inProgress,

  /// The learner has submitted work for the activity.
  submitted,

  /// The learner has completed the activity.
  completed,
}

/// Grading state sent with an AGS score update.
enum LtiGradingProgress {
  /// Grading is complete and the reported score is final for this update.
  fullyGraded,

  /// Automated or other grading is still pending.
  pending,

  /// Manual grading is required before a final result is available.
  pendingManual,

  /// Grading failed and no completed grade is available.
  failed,

  /// The work is not yet ready to be graded.
  notReady,
}

String _wire(String name) => name[0].toUpperCase() + name.substring(1);

/// One AGS score update for a learner and line item.
///
/// A null score explicitly clears a prior score. The host must durably order
/// updates by timestamp per learner/item, including across process restarts.
final class LtiScore {
  /// Creates a score update, including explicit clearing when [scoreGiven] is null.
  ///
  /// [userId] must be nonempty. A supplied score requires a positive finite
  /// [scoreMaximum]; scores must be finite and nonnegative, but may exceed the
  /// maximum for extra credit. [submittedAt] cannot precede [startedAt].
  /// [extensions] requires URL keys and JSON values. Invalid arguments throw
  /// [ArgumentError], [FormatException], or a JSON encoding error.
  LtiScore({
    required this.userId,
    required this.timestamp,
    required this.activityProgress,
    required this.gradingProgress,
    this.scoreGiven,
    this.scoreMaximum,
    this.comment,
    this.scoringUserId,
    this.startedAt,
    this.submittedAt,
    Map<String, Object?> extensions = const {},
  }) : extensions = _extensions(extensions) {
    if (userId.isEmpty ||
        (scoringUserId != null && scoringUserId!.isEmpty) ||
        (scoreGiven != null && scoreMaximum == null) ||
        (startedAt != null &&
            submittedAt != null &&
            submittedAt!.isBefore(startedAt!))) {
      throw ArgumentError('Invalid score fields.');
    }
    _number(scoreGiven);
    _number(scoreMaximum, positive: true);
  }

  /// Platform learner subject ID; use the verified launch/NRPS identity.
  final String userId;

  /// Update time; must increase per learner/item and serializes in UTC.
  final DateTime timestamp;

  /// Current learner activity state, independent of grading completion.
  final LtiActivityProgress activityProgress;

  /// Current grading state for this update.
  final LtiGradingProgress gradingProgress;

  /// Finite nonnegative earned points; null explicitly clears a previous score.
  final num? scoreGiven;

  /// Positive finite scoring scale, required when [scoreGiven] is supplied.
  final num? scoreMaximum;

  /// Optional feedback; serializes as null when omitted.
  final String? comment;

  /// Optional platform subject of the grader, not the learner.
  final String? scoringUserId;

  /// Optional activity start time, serialized in UTC.
  final DateTime? startedAt;

  /// Optional submission time; cannot precede [startedAt].
  final DateTime? submittedAt;

  /// Immutable additional JSON fields keyed by fully qualified URLs.
  final Map<String, Object?> extensions;

  /// Builds the AGS wire payload, including explicit null score/comment values.
  /// Timestamps use UTC with subsecond precision.
  Map<String, Object?> toJson() => {
    ...extensions,
    'userId': userId, 'timestamp': timestamp.toUtc().toIso8601String(),
    'activityProgress': _wire(activityProgress.name),
    'gradingProgress': _wire(gradingProgress.name),
    // Explicit null clears an earlier score.
    'scoreGiven': scoreGiven, 'scoreMaximum': ?scoreMaximum,
    'comment': comment, 'scoringUserId': ?scoringUserId,
    if (startedAt != null || submittedAt != null)
      'submission': {
        'startedAt': ?startedAt?.toUtc().toIso8601String(),
        'submittedAt': ?submittedAt?.toUtc().toIso8601String(),
      },
  };
}

/// Immutable platform result; it may differ from a previously submitted score.
final class LtiResult {
  /// Parses a result with HTTPS `id`/`scoreOf` URLs and a user identifier.
  ///
  /// Throws [FormatException] on invalid fields. Unknown properties are retained.
  /// A missing maximum defaults to one; a score may be absent or negative when
  /// the platform applies an override.
  LtiResult.fromJson(Map<String, Object?> data)
    : json = freezeJson(data) as Map<String, Object?> {
    serviceUri(json['id']);
    serviceUri(json['scoreOf']);
    serviceString(json, 'userId');
    _number(json['resultScore'], nonnegative: false);
    _number(json['resultMaximum'], positive: true);
    _optionalStrings(json, ['comment', 'scoringUserId']);
  }

  /// Deeply immutable result payload, including unknown platform fields.
  final Map<String, Object?> json;

  /// Platform HTTPS identifier for this result.
  Uri get id => serviceUri(json['id']);

  /// HTTPS line-item endpoint to which this result belongs.
  Uri get scoreOf => serviceUri(json['scoreOf']);

  /// Platform subject identifier of the learner whose result is reported.
  String get userId => json['userId']! as String;

  /// Platform-computed score, or null when no score is available.
  num? get resultScore => json['resultScore'] as num?;

  /// Result scale, defaulting to one when absent or null in the response.
  num get resultMaximum => (json['resultMaximum'] as num?) ?? 1;

  /// Optional platform feedback for this result.
  String? get comment => json['comment'] as String?;

  /// Optional platform subject identifier of the grader.
  String? get scoringUserId => json['scoringUserId'] as String?;
}

/// Membership lifecycle state; deleted entries occur only in differences feeds.
enum LtiMembershipStatus {
  /// Current active membership; also the default when status is omitted.
  active,

  /// Membership exists but is inactive.
  inactive,

  /// Membership removed since a changes-feed cursor; not valid on full lists.
  deleted,
}

/// Fixed field names for redacted membership validation diagnostics.
enum LtiMemberField {
  /// The `user_id` field failed validation; no rejected value is exposed.
  userId,

  /// The `roles` field failed validation; no rejected value is exposed.
  roles,

  /// The `status` field failed validation; no rejected value is exposed.
  status,

  /// The `name` field failed validation; no rejected value is exposed.
  name,

  /// The `given_name` field failed validation; no rejected value is exposed.
  givenName,

  /// The `family_name` field failed validation; no rejected value is exposed.
  familyName,

  /// The `middle_name` field failed validation; no rejected value is exposed.
  middleName,

  /// The `email` field failed validation; no rejected value is exposed.
  email,

  /// The `picture` field failed validation; no rejected value is exposed.
  picture,

  /// The `lis_person_sourcedid` field failed validation; no rejected value is exposed.
  personSourcedId,

  /// The `message` field failed validation; no rejected value is exposed.
  messages,
}

// Internal exception: field metadata only, never the rejected value.
/// Internal field-only format error used to redact membership diagnostics.
final class MemberFormatException extends FormatException {
  /// Creates a membership error containing only a fixed field category.
  const MemberFormatException(this.field) : super('Invalid membership field.');

  /// Rejected field category; never contains the rejected value.
  final LtiMemberField field;
}

/// Immutable NRPS member, with optional profile data governed by platform privacy.
///
/// Identity uses the platform subject, not email. Known short context role
/// names are normalized in [roles], while [json] retains original values.
final class LtiMember {
  /// Validates and snapshots a membership response entry.
  ///
  /// Requires a nonempty `user_id` and a string role array. Roles must be URI
  /// values or recognized short context roles. Missing status defaults to active.
  /// Malformed fields throw [FormatException] without including personal values.
  LtiMember.fromJson(Map<String, Object?> data)
    : json = freezeJson(data) as Map<String, Object?> {
    void validate(LtiMemberField field, void Function() check) {
      try {
        check();
      } on FormatException {
        throw MemberFormatException(field);
      } on LtiException {
        throw MemberFormatException(field);
      }
    }

    validate(LtiMemberField.userId, () {
      serviceString(json, 'user_id');
    });
    validate(LtiMemberField.roles, () {
      final roles = this.roles;
      if (roles.any((r) => !(Uri.tryParse(r)?.hasScheme ?? false))) {
        throw const FormatException();
      }
    });
    validate(LtiMemberField.status, () {
      if (json['status'] != null &&
          !['Active', 'Inactive', 'Deleted'].contains(json['status'])) {
        throw const FormatException();
      }
    });
    for (final entry in {
      'name': LtiMemberField.name,
      'given_name': LtiMemberField.givenName,
      'family_name': LtiMemberField.familyName,
      'middle_name': LtiMemberField.middleName,
      'email': LtiMemberField.email,
      'picture': LtiMemberField.picture,
      'lis_person_sourcedid': LtiMemberField.personSourcedId,
    }.entries) {
      validate(entry.value, () => _optionalStrings(json, [entry.key]));
    }
    validate(LtiMemberField.messages, () {
      if (json['message'] != null &&
          (json['message'] is! List ||
              (json['message']! as List).any(
                (m) => m is! Map<String, Object?>,
              ))) {
        throw const FormatException();
      }
    });
  }

  /// Deeply immutable raw membership data, including unknown fields.
  final Map<String, Object?> json;

  /// Platform subject identifier, corresponding to a resource launch's `sub`.
  String get userId => json['user_id']! as String;

  /// Canonical context role URIs; the original values remain in [json].
  List<String> get roles => List.unmodifiable(
    stringList(json['roles']).map(LtiRoles.normalizeContextRole),
  );

  /// Membership state; defaults to active when absent or null.
  LtiMembershipStatus get status => switch (json['status']) {
    'Inactive' => LtiMembershipStatus.inactive,
    'Deleted' => LtiMembershipStatus.deleted,
    _ => LtiMembershipStatus.active,
  };

  /// Display name, or null when the platform does not share it.
  String? get name => json['name'] as String?;

  /// Email address, or null when withheld; never use this as an account key.
  String? get email => json['email'] as String?;

  /// Given name, or null when not shared.
  String? get givenName => json['given_name'] as String?;

  /// Family name, or null when not shared.
  String? get familyName => json['family_name'] as String?;

  /// Optional middle name; null when not shared.
  String? get middleName => json['middle_name'] as String?;

  /// Optional profile image URL string; no download is performed.
  String? get picture => json['picture'] as String?;

  /// Optional learner identifier in the platform's source information system.
  String? get personSourcedId => json['lis_person_sourcedid'] as String?;

  /// Immutable resource-specific launch message fragments; empty when absent.
  /// These fragments are metadata, not independently authenticated launches.
  List<Map<String, Object?>> get messages => List.unmodifiable(
    (json['message'] as List? ?? const []).map(serviceObject),
  );
}

/// One immutable service page with optional pagination and membership metadata.
final class LtiServicePage<T> {
  /// Copies [items] and snapshots optional [context] metadata.
  ///
  /// Continuation links are not fetched here. Use the originating service client
  /// so its destination checks remain in effect when following links.
  LtiServicePage({
    required Iterable<T> items,
    this.next,
    this.differences,
    Map<String, Object?>? context,
  }) : items = List.unmodifiable(items),
       context = context == null
           ? null
           : freezeJson(context) as Map<String, Object?>;

  /// Immutable items returned on this page; may be empty even with a next page.
  final List<T> items;

  /// Opaque next-page URL, or null when no continuation was advertised.
  final Uri? next;

  /// Opaque NRPS changes-feed URL, or null when not advertised.
  final Uri? differences;

  /// Immutable NRPS context metadata; null for pages without context metadata.
  final Map<String, Object?>? context;
}
