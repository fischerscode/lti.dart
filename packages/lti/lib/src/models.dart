import 'errors.dart';

/// Standard claim names. Unknown claims are retained on a verified launch.
abstract final class LtiClaims {
  /// Namespace for LTI Core claim names; not itself a JWT claim.
  static const prefix = 'https://purl.imsglobal.org/spec/lti/claim/';

  /// Claim identifying the LTI message, such as `LtiResourceLinkRequest`.
  static const messageType = '${prefix}message_type';

  /// Claim containing the protocol version `1.3.0`.
  static const version = '${prefix}version';

  /// Claim identifying the platform deployment of this tool.
  static const deploymentId = '${prefix}deployment_id';

  /// Claim containing the exact destination resource URL.
  static const targetLinkUri = '${prefix}target_link_uri';

  /// Claim containing the resource-link identifier and optional metadata.
  static const resourceLink = '${prefix}resource_link';

  /// Claim containing the user's role URI array.
  static const roles = '${prefix}roles';

  /// Claim describing the course or other launch context.
  static const context = '${prefix}context';

  /// Claim containing platform-supplied string custom parameters.
  static const custom = '${prefix}custom';

  /// Claim describing the platform instance.
  static const toolPlatform = '${prefix}tool_platform';

  /// Claim containing display hints and a return URL.
  static const launchPresentation = '${prefix}launch_presentation';

  /// Claim containing optional Learning Information Services identifiers.
  static const lis = '${prefix}lis';

  /// Claim containing the subjects a mentor is permitted to mentor.
  static const roleScopeMentor = '${prefix}role_scope_mentor';
}

/// Administrator-provisioned trust configuration; never discovered from a JWT.
final class LtiRegistration {
  /// Creates trusted configuration provisioned by the application administrator.
  ///
  /// All endpoint/target URLs must use HTTPS without credentials or fragments.
  /// Identifiers and target URLs are matched exactly; collections are copied.
  /// Throws [ArgumentError] for invalid URLs, empty required values or invalid
  /// deployment identifiers. [tokenEndpoint] is required for service access.
  /// Never populate this configuration from an unverified token or login request.
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

  /// OAuth client identifier assigned by the platform, scoped to [issuer].
  final String clientId;

  /// Trusted platform OIDC authorization endpoint for browser redirects.
  final Uri authenticationEndpoint;

  /// Trusted platform public-key endpoint used to verify incoming launch JWTs.
  final Uri jwksUri;

  /// Registered tool callback URL receiving the platform's form POST.
  final Uri redirectUri;

  /// Trusted OAuth token URL, or null when service access is not configured.
  final Uri? tokenEndpoint;

  /// Exact out-of-band assertion audience; defaults to [tokenEndpoint] if absent.
  final String? authorizationServerAudience;

  /// Immutable allowlist of platform deployment IDs accepted for this client.
  final Set<String> deploymentIds;

  /// Exact allowed resource URLs. Query parameters are part of the match.
  final Set<String> targetLinkUris;

  /// Other audiences explicitly trusted for tokens issued to this client.
  /// An `azp` matching the client is still required for multi-audience tokens.
  final Set<String> additionalTrustedAudiences;
}

/// Validated shape of an unsigned third-party login initiation.
final class LtiLoginRequest {
  /// Parses login-initiation fields from decoded query or form [parameters].
  ///
  /// Requires `iss`, `login_hint` and `target_link_uri`; throws [LtiException]
  /// for absent or non-string required values. The web adapter must reject
  /// duplicate fields before constructing this map. This does not authenticate
  /// the request; registration and target checks happen when starting login.
  LtiLoginRequest.fromParameters(Map<String, String> parameters)
    : issuer = requiredString(parameters, 'iss'),
      loginHint = requiredString(parameters, 'login_hint'),
      targetLinkUri = requiredString(parameters, 'target_link_uri'),
      clientId = optionalString(parameters, 'client_id'),
      messageHint = optionalString(parameters, 'lti_message_hint'),
      deploymentId = optionalString(parameters, 'lti_deployment_id');

  /// Untrusted platform issuer hint; must match a configured registration.
  final String issuer;

  /// Opaque platform login hint; forward unchanged and avoid logging it.
  final String loginHint;

  /// Requested resource URL, checked against the registration allowlist.
  final String targetLinkUri;

  /// Optional client hint disambiguating registrations for the same issuer.
  final String? clientId;

  /// Optional opaque platform message hint, forwarded unchanged.
  final String? messageHint;

  /// Optional deployment hint, checked against trusted configuration.
  final String? deploymentId;
}

/// Result of beginning a login. Keep [browserBinding] in this browser only.
final class LtiLoginRedirect {
  /// Describes a newly persisted login transaction and its browser redirect.
  ///
  /// Normally returned by the tool login flow. Store [browserBinding] separately
  /// from the redirect URL, in protected storage bound to the initiating browser.
  const LtiLoginRedirect({
    required this.uri,
    required this.state,
    required this.browserBinding,
    required this.expiresAt,
  });

  /// Complete platform authorization URL to send to the browser.
  final Uri uri;

  /// Opaque one-use correlation value sent to and returned by the platform.
  final String state;

  /// Secret browser-binding value; never accept it from a callback form.
  final String browserBinding;

  /// Deadline after which the stored login transaction cannot be consumed.
  final DateTime expiresAt;
}

/// User identifiers are local to the issuer. Never identify users by email.
final class LtiUser {
  /// Creates user metadata; this value alone is not proof of authentication.
  ///
  /// Identify accounts using [subject] together with the verified issuer.
  /// Optional profile fields depend on platform privacy settings.
  const LtiUser({
    required this.subject,
    this.name,
    this.email,
    this.givenName,
    this.familyName,
    this.locale,
  });

  /// Platform subject identifier; meaningful only together with its issuer.
  final String subject;

  /// Display name, or null when the platform does not share it.
  final String? name;

  /// Email address, or null when withheld; never use this as an account key.
  final String? email;

  /// Given name, or null when not shared.
  final String? givenName;

  /// Family name, or null when not shared.
  final String? familyName;

  /// Optional language/locale hint; not a verified user preference.
  final String? locale;
}

/// Platform instance metadata, not a substitute for the registration's issuer.
final class LtiPlatformInstance {
  /// Parses platform metadata from a verified claim.
  ///
  /// Requires a valid `guid`; optional fields must have their declared types
  /// and `url` must use HTTPS. Throws [LtiException] on invalid claim data.
  LtiPlatformInstance.fromJson(Map<String, Object?> json)
    : guid = requiredIdentifier(json, 'guid'),
      contactEmail = optionalString(json, 'contact_email'),
      description = optionalString(json, 'description'),
      name = optionalString(json, 'name'),
      url = optionalHttpsUri(json, 'url'),
      productFamilyCode = optionalString(json, 'product_family_code'),
      version = optionalString(json, 'version');

  /// Platform instance identifier; does not replace the trusted issuer.
  final String guid;

  /// Optional administrator contact address supplied by the platform.
  final String? contactEmail;

  /// Optional human-readable platform description.
  final String? description;

  /// Optional human-readable platform name.
  final String? name;

  /// Optional HTTPS URL for the platform instance.
  final Uri? url;

  /// Optional platform product-family identifier.
  final String? productFamilyCode;

  /// Optional platform software version string.
  final String? version;
}

/// Browser container in which the platform displays a resource.
enum LtiDocumentTarget {
  /// Displayed in a traditional browser frame.
  frame,

  /// Displayed in an inline frame.
  iframe,

  /// Displayed in a browser window or tab.
  window,
}

/// Display hints and optional return navigation from a verified launch.
final class LtiLaunchPresentation {
  /// Parses optional launch presentation fields.
  ///
  /// Throws [LtiException] for unknown document targets, invalid dimensions,
  /// non-string optional fields or a non-HTTPS return URL.
  LtiLaunchPresentation.fromJson(Map<String, Object?> json)
    : documentTarget = _target(json),
      height = _dimension(json, 'height'),
      width = _dimension(json, 'width'),
      returnUrl = optionalHttpsUri(json, 'return_url'),
      locale = optionalString(json, 'locale');

  /// Requested browser container, or null if unspecified.
  final LtiDocumentTarget? documentTarget;

  /// Suggested display height in pixels, or null if unspecified.
  final int? height;

  /// Suggested display width in pixels, or null if unspecified.
  final int? width;

  /// Optional HTTPS destination for returning control to the platform.
  final Uri? returnUrl;

  /// Optional platform locale hint for this launch.
  final String? locale;

  static LtiDocumentTarget? _target(Map<String, Object?> json) =>
      switch (optionalString(json, 'document_target')) {
        null => null,
        'frame' => LtiDocumentTarget.frame,
        'iframe' => LtiDocumentTarget.iframe,
        'window' => LtiDocumentTarget.window,
        _ => throw const LtiException(
          LtiErrorCode.invalidClaims,
          'Invalid document target.',
        ),
      };

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

/// Optional source-system identifiers supplied through the LIS claim.
final class LtiLis {
  /// Parses optional LIS identifiers; throws [LtiException] for non-strings.
  LtiLis.fromJson(Map<String, Object?> json)
    : personSourcedId = optionalString(json, 'person_sourcedid'),
      courseOfferingSourcedId = optionalString(
        json,
        'course_offering_sourcedid',
      ),
      courseSectionSourcedId = optionalString(json, 'course_section_sourcedid');

  /// Optional user identifier in the platform's source information system.
  final String? personSourcedId;

  /// Optional source-system identifier for a course offering.
  final String? courseOfferingSourcedId;

  /// Optional source-system identifier for a course section.
  final String? courseSectionSourcedId;
}

/// A platform placement of a tool resource; distinct from the tool URL.
final class LtiResourceLink {
  /// Creates resource-link metadata without authenticating its origin.
  const LtiResourceLink({required this.id, this.title, this.description});

  /// Platform resource-link ID; scope it to the verified platform/deployment.
  final String id;

  /// Optional display title chosen for this placement.
  final String? title;

  /// Optional description of the placed resource.
  final String? description;
}

/// Course or group metadata associated with a launch.
final class LtiContext {
  /// Creates context metadata and an immutable copy of [types].
  ///
  /// This constructor does not validate or authenticate caller-supplied values.
  LtiContext({
    required this.id,
    this.label,
    this.title,
    List<String> types = const [],
  }) : types = List.unmodifiable(types);

  /// Platform context identifier; scope it to the verified platform.
  final String id;

  /// Optional short course or group label.
  final String? label;

  /// Optional human-readable context title.
  final String? title;

  /// Immutable context type list; verified launches normalize known aliases.
  final List<String> types;
}

// Internal parsing helpers; intentionally not exported from the public library.
/// Whether [value] is a nonempty ASCII LTI identifier of at most 255 characters.
bool isLtiIdentifier(String value) =>
    value.isNotEmpty &&
    value.length <= 255 &&
    value.codeUnits.every((c) => c <= 127);

/// Reads a nonempty string; throws [LtiException] for missing or invalid values.
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

/// Reads an LTI identifier; throws [LtiException] if invalid.
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

/// Reads an optional HTTPS URI; invalid present values throw [LtiException].
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

/// Reads an optional JSON object; invalid present values throw [LtiException].
Map<String, Object?>? optionalObject(Map<String, Object?> json, String name) =>
    json.containsKey(name) ? jsonObject(json[name], field: name) : null;

/// Reads an optional string; a present non-string throws [LtiException].
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

/// Requires a string-keyed object; throws [LtiException] for other values.
Map<String, Object?> jsonObject(Object? value, {String field = 'object'}) {
  if (value is! Map<String, Object?>) {
    throw LtiException(
      LtiErrorCode.invalidClaims,
      'Expected a JSON object in field: $field.',
    );
  }
  return value;
}

/// Returns an immutable string list; throws [LtiException] for invalid arrays.
List<String> stringList(Object? value, {String field = 'array'}) {
  if (value is! List || value.any((Object? entry) => entry is! String)) {
    throw LtiException(
      LtiErrorCode.invalidClaims,
      'Expected an array of strings in field: $field.',
    );
  }
  return List<String>.unmodifiable(value.cast<String>());
}

/// Recursively copies maps and lists into unmodifiable JSON containers.
Object? freezeJson(Object? value) => switch (value) {
  Map<String, Object?> map => Map<String, Object?>.unmodifiable(
    map.map((key, value) => MapEntry(key, freezeJson(value))),
  ),
  List<Object?> list => List<Object?>.unmodifiable(list.map(freezeJson)),
  _ => value,
};
