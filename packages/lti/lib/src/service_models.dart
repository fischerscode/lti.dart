import 'dart:convert';

import 'models.dart';

abstract final class LtiServiceScopes {
  static const lineItem =
      'https://purl.imsglobal.org/spec/lti-ags/scope/lineitem';
  static const lineItemReadonly =
      'https://purl.imsglobal.org/spec/lti-ags/scope/lineitem.readonly';
  static const score = 'https://purl.imsglobal.org/spec/lti-ags/scope/score';
  static const resultReadonly =
      'https://purl.imsglobal.org/spec/lti-ags/scope/result.readonly';
  static const membershipReadonly =
      'https://purl.imsglobal.org/spec/lti-nrps/scope/contextmembership.readonly';
}

abstract final class LtiServiceClaims {
  static const ags = 'https://purl.imsglobal.org/spec/lti-ags/claim/endpoint';
  static const nrps =
      'https://purl.imsglobal.org/spec/lti-nrps/claim/namesroleservice';
}

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

final class LtiAgsEndpoints {
  LtiAgsEndpoints.fromJson(Map<String, Object?> json)
    : scopes = Set.unmodifiable(stringList(json['scope'])),
      lineItems = json['lineitems'] == null || json['lineitems'] == ''
          ? null
          : serviceUri(json['lineitems']),
      lineItem = json['lineitem'] == null || json['lineitem'] == ''
          ? null
          : serviceUri(json['lineitem']);
  final Set<String> scopes;
  final Uri? lineItems;
  final Uri? lineItem;
}

final class LtiNrpsEndpoint {
  LtiNrpsEndpoint.fromJson(Map<String, Object?> json)
    : memberships = serviceUri(json['context_memberships_url']),
      versions = List.unmodifiable(stringList(json['service_versions']));
  final Uri memberships;
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

Map<String, Object?> serviceObject(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Expected service object.');
  }
  return value;
}

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

DateTime? serviceDate(Object? value) {
  if (value == null || value == '') return null;
  if (value is! String || !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(value)) {
    throw const FormatException('Expected timestamp with time zone.');
  }
  final date = DateTime.tryParse(value);
  if (date == null) throw const FormatException('Invalid timestamp.');
  return date;
}

final class LtiLineItem {
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
  final Map<String, Object?> json;
  Uri? get id => json['id'] == null ? null : serviceUri(json['id']);
  String get label => json['label']! as String;
  num get scoreMaximum => json['scoreMaximum']! as num;
  String? get resourceId => json['resourceId'] as String?;
  String? get resourceLinkId => json['resourceLinkId'] as String?;
  String? get tag => json['tag'] as String?;
  bool? get gradesReleased => json['gradesReleased'] as bool?;
  DateTime? get startDateTime => serviceDate(json['startDateTime']);
  DateTime? get endDateTime => serviceDate(json['endDateTime']);
  Map<String, Object?> toJson() => json;
}

enum LtiActivityProgress {
  initialized,
  started,
  inProgress,
  submitted,
  completed,
}

enum LtiGradingProgress {
  fullyGraded,
  pending,
  pendingManual,
  failed,
  notReady,
}

String _wire(String name) => name[0].toUpperCase() + name.substring(1);

final class LtiScore {
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
  final String userId;
  final DateTime timestamp;
  final LtiActivityProgress activityProgress;
  final LtiGradingProgress gradingProgress;
  final num? scoreGiven;
  final num? scoreMaximum;
  final String? comment;
  final String? scoringUserId;
  final DateTime? startedAt;
  final DateTime? submittedAt;
  final Map<String, Object?> extensions;
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

final class LtiResult {
  LtiResult.fromJson(Map<String, Object?> data)
    : json = freezeJson(data) as Map<String, Object?> {
    serviceUri(json['id']);
    serviceUri(json['scoreOf']);
    serviceString(json, 'userId');
    _number(json['resultScore'], nonnegative: false);
    _number(json['resultMaximum'], positive: true);
    _optionalStrings(json, ['comment', 'scoringUserId']);
  }
  final Map<String, Object?> json;
  Uri get id => serviceUri(json['id']);
  Uri get scoreOf => serviceUri(json['scoreOf']);
  String get userId => json['userId']! as String;
  num? get resultScore => json['resultScore'] as num?;
  num get resultMaximum => (json['resultMaximum'] as num?) ?? 1;
  String? get comment => json['comment'] as String?;
  String? get scoringUserId => json['scoringUserId'] as String?;
}

enum LtiMembershipStatus { active, inactive, deleted }

final class LtiMember {
  LtiMember.fromJson(Map<String, Object?> data)
    : json = freezeJson(data) as Map<String, Object?> {
    serviceString(json, 'user_id');
    final roles = stringList(json['roles']);
    if (roles.any((r) => !(Uri.tryParse(r)?.hasScheme ?? false))) {
      throw const FormatException('Invalid membership role.');
    }
    if (json['status'] != null &&
        !['Active', 'Inactive', 'Deleted'].contains(json['status'])) {
      throw const FormatException('Invalid membership status.');
    }
    _optionalStrings(json, [
      'name',
      'given_name',
      'family_name',
      'middle_name',
      'email',
      'picture',
      'lis_person_sourcedid',
    ]);
    if (json['message'] != null &&
        (json['message'] is! List ||
            (json['message']! as List).any(
              (m) => m is! Map<String, Object?>,
            ))) {
      throw const FormatException('Invalid membership messages.');
    }
  }
  final Map<String, Object?> json;
  String get userId => json['user_id']! as String;
  List<String> get roles => stringList(json['roles']);
  LtiMembershipStatus get status => switch (json['status']) {
    'Inactive' => LtiMembershipStatus.inactive,
    'Deleted' => LtiMembershipStatus.deleted,
    _ => LtiMembershipStatus.active,
  };
  String? get name => json['name'] as String?;
  String? get email => json['email'] as String?;
  String? get givenName => json['given_name'] as String?;
  String? get familyName => json['family_name'] as String?;
  String? get middleName => json['middle_name'] as String?;
  String? get picture => json['picture'] as String?;
  String? get personSourcedId => json['lis_person_sourcedid'] as String?;
  List<Map<String, Object?>> get messages => List.unmodifiable(
    (json['message'] as List? ?? const []).map(serviceObject),
  );
}

final class LtiServicePage<T> {
  LtiServicePage({
    required Iterable<T> items,
    this.next,
    this.differences,
    Map<String, Object?>? context,
  }) : items = List.unmodifiable(items),
       context = context == null
           ? null
           : freezeJson(context) as Map<String, Object?>;
  final List<T> items;
  final Uri? next;
  final Uri? differences;
  final Map<String, Object?>? context;
}
