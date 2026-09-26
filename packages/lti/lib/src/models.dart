import 'errors.dart';

/// Standard claim names. Unknown claims are retained on a verified launch.
abstract final class LtiClaims {
  static const prefix = 'https://purl.imsglobal.org/spec/lti/claim/';
  static const messageType = '${prefix}message_type';
  static const version = '${prefix}version';
  static const deploymentId = '${prefix}deployment_id';
  static const targetLinkUri = '${prefix}target_link_uri';
  static const resourceLink = '${prefix}resource_link';
  static const roles = '${prefix}roles';
  static const context = '${prefix}context';
  static const custom = '${prefix}custom';
}

/// Administrator-provisioned trust configuration; never discovered from a JWT.
final class LtiRegistration {
  LtiRegistration({
    required this.issuer,
    required this.clientId,
    required this.authenticationEndpoint,
    required this.jwksUri,
    required this.redirectUri,
    required Set<String> deploymentIds,
    required Set<String> targetLinkUris,
    this.tokenEndpoint,
  }) : deploymentIds = Set.unmodifiable(deploymentIds),
       targetLinkUris = Set.unmodifiable(targetLinkUris) {
    for (final uri in [
      Uri.parse(issuer),
      authenticationEndpoint,
      jwksUri,
      redirectUri,
      ?tokenEndpoint,
      ...targetLinkUris.map(Uri.parse),
    ]) {
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment) {
        throw ArgumentError(
          'LTI URLs must be absolute HTTPS URLs without credentials or fragments.',
        );
      }
    }
    if (clientId.isEmpty ||
        deploymentIds.isEmpty ||
        targetLinkUris.isEmpty ||
        deploymentIds.any((id) => !isLtiIdentifier(id))) {
      throw ArgumentError(
        'A client, deployments and allowed targets are required.',
      );
    }
  }

  /// Exact, case-sensitive platform identifier (not normalized as a URI).
  final String issuer;
  final String clientId;
  final Uri authenticationEndpoint;
  final Uri jwksUri;
  final Uri redirectUri;
  final Uri? tokenEndpoint;
  final Set<String> deploymentIds;

  /// Exact allowed resource URLs. Query parameters are part of the match.
  final Set<String> targetLinkUris;
}

/// Validated shape of an unsigned third-party login initiation.
final class LtiLoginRequest {
  LtiLoginRequest.fromParameters(Map<String, String> parameters)
    : issuer = requiredString(parameters, 'iss'),
      loginHint = requiredString(parameters, 'login_hint'),
      targetLinkUri = requiredString(parameters, 'target_link_uri'),
      clientId = optionalString(parameters, 'client_id'),
      messageHint = optionalString(parameters, 'lti_message_hint'),
      deploymentId = optionalString(parameters, 'lti_deployment_id');

  final String issuer;
  final String loginHint;
  final String targetLinkUri;
  final String? clientId;
  final String? messageHint;
  final String? deploymentId;
}

/// Result of beginning a login. Keep [browserBinding] in this browser only.
final class LtiLoginRedirect {
  const LtiLoginRedirect({
    required this.uri,
    required this.state,
    required this.browserBinding,
    required this.expiresAt,
  });
  final Uri uri;
  final String state;
  final String browserBinding;
  final DateTime expiresAt;
}

/// User identifiers are local to the issuer. Never identify users by email.
final class LtiUser {
  const LtiUser({required this.subject, this.name, this.email});
  final String subject;
  final String? name;
  final String? email;
}

final class LtiResourceLink {
  const LtiResourceLink({required this.id, this.title, this.description});
  final String id;
  final String? title;
  final String? description;
}

final class LtiContext {
  LtiContext({
    required this.id,
    this.label,
    this.title,
    List<String> types = const [],
  }) : types = List.unmodifiable(types);
  final String id;
  final String? label;
  final String? title;
  final List<String> types;
}

// Internal parsing helpers; intentionally not exported from the public library.
bool isLtiIdentifier(String value) =>
    value.isNotEmpty &&
    value.length <= 255 &&
    value.codeUnits.every((c) => c <= 127);

String requiredString(Map<String, Object?> json, String name) {
  final value = json[name];
  if (value is! String || value.isEmpty) {
    throw const LtiException(
      LtiErrorCode.invalidClaims,
      'Missing or invalid string field.',
    );
  }
  return value;
}

String? optionalString(Map<String, Object?> json, String name) {
  if (!json.containsKey(name)) return null;
  final value = json[name];
  if (value is! String) {
    throw const LtiException(
      LtiErrorCode.invalidClaims,
      'Invalid optional string field.',
    );
  }
  return value;
}

Map<String, Object?> jsonObject(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const LtiException(
      LtiErrorCode.invalidClaims,
      'Expected a JSON object.',
    );
  }
  return value;
}

List<String> stringList(Object? value) {
  if (value is! List || value.any((Object? entry) => entry is! String)) {
    throw const LtiException(
      LtiErrorCode.invalidClaims,
      'Expected an array of strings.',
    );
  }
  return List<String>.unmodifiable(value.cast<String>());
}

Object? freezeJson(Object? value) => switch (value) {
  Map<String, Object?> map => Map<String, Object?>.unmodifiable(
    map.map((key, value) => MapEntry(key, freezeJson(value))),
  ),
  List<Object?> list => List<Object?>.unmodifiable(list.map(freezeJson)),
  _ => value,
};
