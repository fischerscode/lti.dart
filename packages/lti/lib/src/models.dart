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
  static const toolPlatform = '${prefix}tool_platform';
  static const launchPresentation = '${prefix}launch_presentation';
  static const lis = '${prefix}lis';
  static const roleScopeMentor = '${prefix}role_scope_mentor';
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
    Set<String> additionalTrustedAudiences = const {},
    this.tokenEndpoint,
    this.authorizationServerAudience,
  }) : deploymentIds = Set.unmodifiable(deploymentIds),
       additionalTrustedAudiences = Set.unmodifiable(
         additionalTrustedAudiences,
       ),
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
        authorizationServerAudience == '' ||
        deploymentIds.any((id) => !isLtiIdentifier(id)) ||
        additionalTrustedAudiences.any((id) => id.isEmpty)) {
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

  /// Exact out-of-band assertion audience; defaults to [tokenEndpoint] if absent.
  final String? authorizationServerAudience;
  final Set<String> deploymentIds;

  /// Exact allowed resource URLs. Query parameters are part of the match.
  final Set<String> targetLinkUris;

  /// Other audiences explicitly trusted for tokens issued to this client.
  /// An `azp` matching the client is still required for multi-audience tokens.
  final Set<String> additionalTrustedAudiences;
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
  const LtiUser({
    required this.subject,
    this.name,
    this.email,
    this.givenName,
    this.familyName,
    this.locale,
  });
  final String subject;
  final String? name;
  final String? email;
  final String? givenName;
  final String? familyName;
  final String? locale;
}

/// Platform instance metadata, not a substitute for the registration's issuer.
final class LtiPlatformInstance {
  LtiPlatformInstance.fromJson(Map<String, Object?> json)
    : guid = requiredIdentifier(json, 'guid'),
      contactEmail = optionalString(json, 'contact_email'),
      description = optionalString(json, 'description'),
      name = optionalString(json, 'name'),
      url = optionalHttpsUri(json, 'url'),
      productFamilyCode = optionalString(json, 'product_family_code'),
      version = optionalString(json, 'version');

  final String guid;
  final String? contactEmail;
  final String? description;
  final String? name;
  final Uri? url;
  final String? productFamilyCode;
  final String? version;
}

enum LtiDocumentTarget { frame, iframe, window }

final class LtiLaunchPresentation {
  LtiLaunchPresentation.fromJson(Map<String, Object?> json)
    : documentTarget = _target(json),
      height = _dimension(json, 'height'),
      width = _dimension(json, 'width'),
      returnUrl = optionalHttpsUri(json, 'return_url'),
      locale = optionalString(json, 'locale');

  final LtiDocumentTarget? documentTarget;
  final int? height;
  final int? width;
  final Uri? returnUrl;
  final String? locale;

  static LtiDocumentTarget? _target(Map<String, Object?> json) {
    final value = optionalString(json, 'document_target');
    if (value == null) return null;
    for (final target in LtiDocumentTarget.values) {
      if (target.name == value) return target;
    }
    throw const LtiException(
      LtiErrorCode.invalidClaims,
      'Invalid document target.',
    );
  }

  static int? _dimension(Map<String, Object?> json, String key) {
    if (!json.containsKey(key)) return null;
    final value = json[key];
    if (value is! num ||
        !value.isFinite ||
        value < 0 ||
        value != value.truncateToDouble()) {
      throw const LtiException(
        LtiErrorCode.invalidClaims,
        'Invalid presentation dimension.',
      );
    }
    return value.toInt();
  }

  /// Builds a return URL, retaining unrelated query parameters. Does not redirect.
  /// Only include messages appropriate for disclosure to the platform/browser.
  Uri? returnUri({
    String? message,
    String? errorMessage,
    String? log,
    String? errorLog,
  }) => returnUrl?.replace(
    queryParameters: {
      ...returnUrl!.queryParametersAll,
      'lti_msg': ?message,
      'lti_errormsg': ?errorMessage,
      'lti_log': ?log,
      'lti_errorlog': ?errorLog,
    },
  );
}

final class LtiLis {
  LtiLis.fromJson(Map<String, Object?> json)
    : personSourcedId = optionalString(json, 'person_sourcedid'),
      courseOfferingSourcedId = optionalString(
        json,
        'course_offering_sourcedid',
      ),
      courseSectionSourcedId = optionalString(json, 'course_section_sourcedid');

  final String? personSourcedId;
  final String? courseOfferingSourcedId;
  final String? courseSectionSourcedId;
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
    throw LtiException(
      LtiErrorCode.invalidClaims,
      'Missing or invalid string field: $name.',
    );
  }
  return value;
}

String requiredIdentifier(Map<String, Object?> json, String name) {
  final value = requiredString(json, name);
  if (!isLtiIdentifier(value)) {
    throw LtiException(
      LtiErrorCode.invalidClaims,
      'Invalid LTI identifier: $name.',
    );
  }
  return value;
}

Uri? optionalHttpsUri(Map<String, Object?> json, String name) {
  final value = optionalString(json, name);
  if (value == null) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw LtiException(
      LtiErrorCode.invalidClaims,
      'Expected an absolute HTTPS URL in field: $name.',
    );
  }
  return uri;
}

Map<String, Object?>? optionalObject(Map<String, Object?> json, String name) =>
    json.containsKey(name) ? jsonObject(json[name], field: name) : null;

String? optionalString(Map<String, Object?> json, String name) {
  if (!json.containsKey(name)) return null;
  final value = json[name];
  if (value is! String) {
    throw LtiException(
      LtiErrorCode.invalidClaims,
      'Invalid optional string field: $name.',
    );
  }
  return value;
}

Map<String, Object?> jsonObject(Object? value, {String field = 'object'}) {
  if (value is! Map<String, Object?>) {
    throw LtiException(
      LtiErrorCode.invalidClaims,
      'Expected a JSON object in field: $field.',
    );
  }
  return value;
}

List<String> stringList(Object? value, {String field = 'array'}) {
  if (value is! List || value.any((Object? entry) => entry is! String)) {
    throw LtiException(
      LtiErrorCode.invalidClaims,
      'Expected an array of strings in field: $field.',
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
