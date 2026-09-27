import 'dart:convert';
import 'dart:math';

import 'deep_linking.dart';
import 'errors.dart';
import 'jwks.dart';
import 'models.dart';
import 'service_models.dart';
import 'signing.dart';
import 'store.dart';
import 'vocabularies.dart';

/// Orchestrates login and validation without depending on a web framework.
final class LtiTool {
  /// Creates a framework-independent tool using trusted stores and a verifier.
  ///
  /// [signer] is optional for incoming launches but required for Deep Linking
  /// responses. [clock] defaults to the current time. Invalid time limits throw
  /// [ArgumentError]. Use a shared, atomic transaction store for multiple workers.
  LtiTool({
    required this.registrations,
    required this.transactions,
    required this.tokenVerifier,
    this.signer,
    DateTime Function()? clock,
    this.loginLifetime = const Duration(minutes: 5),
    this.clockTolerance = const Duration(seconds: 30),
    this.maxTokenAge = const Duration(minutes: 5),
  }) : _clock = clock ?? DateTime.now {
    if (loginLifetime <= Duration.zero ||
        clockTolerance < Duration.zero ||
        maxTokenAge <= Duration.zero) {
      throw ArgumentError('Invalid protocol time limits.');
    }
  }

  /// Administrator-provisioned registrations used for exact trust lookup.
  final LtiRegistrationStore registrations;

  /// Atomic one-use login transaction storage; must be shared across workers.
  final LtiTransactionStore transactions;

  /// Trusted cryptographic verifier for platform ID tokens.
  final LtiTokenVerifier tokenVerifier;

  /// Tool JWT signer, or null when outbound messages are not configured.
  final LtiJwtSigner? signer;
  final DateTime Function() _clock;

  /// Lifetime of a pending login transaction; defaults to five minutes.
  final Duration loginLifetime;

  /// Allowed skew for token time checks; defaults to 30 seconds.
  final Duration clockTolerance;

  /// Maximum accepted age since token issuance, plus clock tolerance.
  final Duration maxTokenAge;
  final _random = Random.secure();

  String _randomToken() => base64Url
      .encode(List.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  /// Persists one-use state and builds an OIDC authorization redirect.
  ///
  /// Checks [request] against trusted registration, target and deployment data.
  /// Throws [LtiException] for unknown/ambiguous registrations or disallowed
  /// targets/deployments. Storage failures propagate. Bind the returned secret
  /// to the initiating browser before redirecting; no user is authenticated yet.
  Future<LtiLoginRedirect> beginLogin(LtiLoginRequest request) async {
    final registration = await registrations.find(
      request.issuer,
      clientId: request.clientId,
    );
    if (registration == null) {
      throw const LtiException(
        LtiErrorCode.unknownRegistration,
        'Unknown or ambiguous registration.',
      );
    }
    if (!registration.targetLinkUris.contains(request.targetLinkUri) ||
        (request.deploymentId != null &&
            !registration.deploymentIds.contains(request.deploymentId))) {
      throw const LtiException(
        LtiErrorCode.invalidRequest,
        'Unregistered target or deployment.',
      );
    }
    final now = _clock();
    final transaction = LtiLoginTransaction(
      state: _randomToken(),
      nonce: _randomToken(),
      browserBinding: _randomToken(),
      issuer: registration.issuer,
      clientId: registration.clientId,
      targetLinkUri: request.targetLinkUri,
      deploymentId: request.deploymentId,
      createdAt: now,
      expiresAt: now.add(loginLifetime),
    );
    await transactions.save(transaction);
    final uri = registration.authenticationEndpoint.replace(
      queryParameters: {
        ...registration.authenticationEndpoint.queryParameters,
        'scope': 'openid',
        'response_type': 'id_token',
        'response_mode': 'form_post',
        'prompt': 'none',
        'client_id': registration.clientId,
        'redirect_uri': registration.redirectUri.toString(),
        'login_hint': request.loginHint,
        if (request.messageHint != null)
          'lti_message_hint': request.messageHint!,
        'state': transaction.state,
        'nonce': transaction.nonce,
      },
    );
    return LtiLoginRedirect(
      uri: uri,
      state: transaction.state,
      browserBinding: transaction.browserBinding,
      expiresAt: transaction.expiresAt,
    );
  }

  /// Validates a callback and returns a verified resource or Deep Linking launch.
  ///
  /// [state] and [idToken] come from the platform form POST. [browserBinding]
  /// must come from the initiating browser's protected storage, never the form.
  /// Once a matching, unexpired transaction is consumed, it remains consumed
  /// even if token validation fails. A binding mismatch does not consume it.
  ///
  /// Throws [LtiException] for protocol failures; custom store/verifier failures
  /// can propagate. A returned launch still requires application authorization.
  /// Do not reuse the ID token as an application session or log its contents.
  Future<LtiLaunch> completeLaunch({
    required String state,
    required String browserBinding,
    required String idToken,
  }) async {
    final now = _clock();
    final transaction = await transactions.consume(
      state: state,
      browserBinding: browserBinding,
      now: now,
    );
    if (transaction == null) {
      throw const LtiException(
        LtiErrorCode.invalidState,
        'Unknown, expired or unbound login.',
      );
    }
    final registration = await registrations.find(
      transaction.issuer,
      clientId: transaction.clientId,
    );
    if (registration == null) {
      throw const LtiException(
        LtiErrorCode.unknownRegistration,
        'Registration no longer exists.',
      );
    }
    final claims = await tokenVerifier.verify(idToken, registration);
    _validateClaims(claims, registration, transaction, _clock());
    return switch (claims[LtiClaims.messageType]) {
      'LtiResourceLinkRequest' => LtiResourceLaunch._(
        registration,
        claims,
        transaction.targetLinkUri,
      ),
      'LtiDeepLinkingRequest' => LtiDeepLinkingLaunch._(
        registration,
        claims,
        transaction.targetLinkUri,
      ),
      _ => throw const LtiException(
        LtiErrorCode.unsupportedMessage,
        'Unsupported LTI message.',
      ),
    };
  }

  /// Validates a callback that must be a resource-link launch.
  ///
  /// Uses the same state, browser binding and token checks as [completeLaunch].
  /// A different valid message type throws [LtiException] with
  /// [LtiErrorCode.unsupportedMessage] after consuming the matched transaction.
  Future<LtiResourceLaunch> completeResourceLaunch({
    required String state,
    required String browserBinding,
    required String idToken,
  }) async {
    final launch = await completeLaunch(
      state: state,
      browserBinding: browserBinding,
      idToken: idToken,
    );
    if (launch is LtiResourceLaunch) return launch;
    throw const LtiException(
      LtiErrorCode.unsupportedMessage,
      'Expected a resource launch.',
    );
  }

  /// Signs a selection or cancellation from a verified, server-held [launch].
  ///
  /// An empty [items] list cancels selection. The platform's opaque data is
  /// echoed unchanged, including explicit null. Optional [message] and
  /// [errorMessage] are intended for users; [log] and [errorLog] are returned
  /// to the platform and must not disclose secrets.
  ///
  /// Throws [StateError] when no signer exists, [ArgumentError] for selections
  /// incompatible with the request, or [LtiException] if registration is no
  /// longer active. Signing-provider errors may propagate.
  /// The host must authorize selections and protect its session against CSRF.
  ///
  /// ```dart
  /// final response = await tool.createDeepLinkingResponse(
  ///   launch: selectionLaunch,
  ///   items: [LtiContentItem.ltiResourceLink(
  ///     url: Uri.parse('https://tool.example/activity'),
  ///     title: 'Practice activity',
  ///   )],
  /// );
  /// // POST response.formFields from the browser to response.returnUrl.
  /// ```
  Future<LtiDeepLinkingResponse> createDeepLinkingResponse({
    required LtiDeepLinkingLaunch launch,
    List<LtiContentItem> items = const [],
    String? message,
    String? log,
    String? errorMessage,
    String? errorLog,
  }) async {
    final signing = signer;
    if (signing == null) throw StateError('Configure a tool signer.');
    final selected = List<LtiContentItem>.unmodifiable(items);
    launch.settings.validateSelection(selected);
    final registration = await registrations.find(
      launch.registration.issuer,
      clientId: launch.registration.clientId,
    );
    if (registration == null ||
        !registration.deploymentIds.contains(launch.deploymentId) ||
        !registration.targetLinkUris.contains(launch.targetLinkUri)) {
      throw const LtiException(
        LtiErrorCode.unknownRegistration,
        'Launch registration is no longer active.',
      );
    }
    final jwt = await signing.signMessage(
      registration: registration,
      deploymentId: launch.deploymentId,
      messageType: 'LtiDeepLinkingResponse',
      claims: {
        LtiDeepLinkingClaims.contentItems: selected
            .map((item) => item.toJson())
            .toList(),
        if (launch.settings.hasData)
          LtiDeepLinkingClaims.data: launch.settings.data,
        LtiDeepLinkingClaims.message: ?message,
        LtiDeepLinkingClaims.log: ?log,
        LtiDeepLinkingClaims.errorMessage: ?errorMessage,
        LtiDeepLinkingClaims.errorLog: ?errorLog,
      },
    );
    return LtiDeepLinkingResponse(
      returnUrl: launch.settings.returnUrl,
      jwt: jwt,
    );
  }

  /// Terminates a browser-bound OIDC error response. Error descriptions from the
  /// platform are intentionally not reflected or logged by the protocol library.
  ///
  /// Always throws [LtiException]: [LtiErrorCode.authenticationFailed] after
  /// consuming a matching transaction, or [LtiErrorCode.invalidState] when no
  /// matching unexpired transaction exists. [browserBinding] must come from
  /// the initiating browser's protected storage.
  Future<Never> completeLoginError({
    required String state,
    required String browserBinding,
  }) async {
    final transaction = await transactions.consume(
      state: state,
      browserBinding: browserBinding,
      now: _clock(),
    );
    if (transaction == null) {
      throw const LtiException(
        LtiErrorCode.invalidState,
        'Unknown, expired or unbound login.',
      );
    }
    throw const LtiException(
      LtiErrorCode.authenticationFailed,
      'Platform authentication failed.',
    );
  }

  void _validateClaims(
    Map<String, Object?> claims,
    LtiRegistration registration,
    LtiLoginTransaction transaction,
    DateTime now,
  ) {
    Never invalid(String reason) =>
        throw LtiException(LtiErrorCode.invalidClaims, reason);
    if (!transaction.expiresAt.isAfter(now)) {
      invalid('Login transaction expired during verification.');
    }
    if (claims['iss'] != registration.issuer) invalid('Issuer mismatch.');
    if (claims['nonce'] != transaction.nonce) invalid('Nonce mismatch.');
    final audience = claims['aud'];
    final audiences = audience is String
        ? [audience]
        : stringList(audience, field: 'aud');
    if (!audiences.contains(registration.clientId) ||
        audiences.any(
          (audience) =>
              audience != registration.clientId &&
              !registration.additionalTrustedAudiences.contains(audience),
        ) ||
        (audiences.length > 1 && claims['azp'] != registration.clientId) ||
        (claims.containsKey('azp') && claims['azp'] != registration.clientId)) {
      invalid('Audience or authorized party mismatch.');
    }
    num numericDate(String name) {
      final value = claims[name];
      if (value is! num || !value.isFinite) {
        invalid('Invalid numeric date: $name.');
      }
      return value;
    }

    final seconds = now.millisecondsSinceEpoch / 1000;
    final tolerance = clockTolerance.inMilliseconds / 1000;
    final issued = numericDate('iat');
    final expires = numericDate('exp');
    if (expires <= seconds - tolerance) invalid('Token expired.');
    if (issued > seconds + tolerance) invalid('Token issued in the future.');
    if (issued < seconds - maxTokenAge.inMilliseconds / 1000 - tolerance) {
      invalid('Token exceeds maximum age.');
    }
    if (issued <
        transaction.createdAt.millisecondsSinceEpoch / 1000 - tolerance) {
      invalid('Token predates the login transaction.');
    }
    if (expires <= issued) invalid('Token expiry is not after issuance.');
    if (claims.containsKey('nbf') && numericDate('nbf') > seconds + tolerance) {
      invalid('Token is not yet valid.');
    }
    if (claims[LtiClaims.version] != '1.3.0') {
      invalid('Unsupported LTI version.');
    }
    if (!const [
      'LtiResourceLinkRequest',
      'LtiDeepLinkingRequest',
    ].contains(claims[LtiClaims.messageType])) {
      throw const LtiException(
        LtiErrorCode.unsupportedMessage,
        'Unsupported LTI message.',
      );
    }
    final deployment = requiredString(claims, LtiClaims.deploymentId);
    if (!registration.deploymentIds.contains(deployment)) {
      invalid('Deployment is not registered.');
    }
    if (transaction.deploymentId != null &&
        transaction.deploymentId != deployment) {
      invalid('Deployment differs from login hint.');
    }
    if ((claims[LtiClaims.messageType] == 'LtiResourceLinkRequest' ||
            claims.containsKey(LtiClaims.targetLinkUri)) &&
        claims[LtiClaims.targetLinkUri] != transaction.targetLinkUri) {
      invalid('Target link URI differs from login target or is missing.');
    }
    if (!registration.targetLinkUris.contains(transaction.targetLinkUri)) {
      invalid('Login target is no longer registered.');
    }
  }
}

/// A launch that passed signature, transaction and claim validation.
/// Instances can only be created by [LtiTool]. Does not imply app authorization.
sealed class LtiLaunch {
  LtiLaunch._(
    this.registration,
    Map<String, Object?> data,
    this.targetLinkUri, {
    required bool rolesRequired,
  }) : claims = freezeJson(data) as Map<String, Object?> {
    final sub = optionalString(claims, 'sub');
    if (sub != null && !isLtiIdentifier(sub)) {
      throw const LtiException(
        LtiErrorCode.invalidClaims,
        'Invalid subject identifier.',
      );
    }
    user = sub == null
        ? null
        : LtiUser(
            subject: sub,
            name: optionalString(claims, 'name'),
            email: optionalString(claims, 'email'),
            givenName: optionalString(claims, 'given_name'),
            familyName: optionalString(claims, 'family_name'),
            locale: optionalString(claims, 'locale'),
          );
    roles = rolesRequired || claims.containsKey(LtiClaims.roles)
        ? stringList(claims[LtiClaims.roles], field: LtiClaims.roles)
        : const [];
    if (roles.any((role) => !(Uri.tryParse(role)?.hasScheme ?? false)) ||
        (roles.isNotEmpty && !roles.any(LtiRoles.isStandard))) {
      throw const LtiException(
        LtiErrorCode.invalidClaims,
        'Roles must be URIs and include a standard role when nonempty.',
      );
    }
    try {
      final agsData = optionalObject(claims, LtiServiceClaims.ags);
      ags = agsData == null ? null : LtiAgsEndpoints.fromJson(agsData);
      final nrpsData = optionalObject(claims, LtiServiceClaims.nrps);
      nrps = nrpsData == null ? null : LtiNrpsEndpoint.fromJson(nrpsData);
    } on FormatException {
      throw const LtiException(
        LtiErrorCode.invalidClaims,
        'Invalid service capability claim.',
      );
    }
    final contextData = optionalObject(claims, LtiClaims.context);
    context = contextData == null ? null : _context(contextData);
    final platformData = optionalObject(claims, LtiClaims.toolPlatform);
    platform = platformData == null
        ? null
        : LtiPlatformInstance.fromJson(platformData);
    final presentationData = optionalObject(
      claims,
      LtiClaims.launchPresentation,
    );
    presentation = presentationData == null
        ? null
        : LtiLaunchPresentation.fromJson(presentationData);
    final lisData = optionalObject(claims, LtiClaims.lis);
    lis = lisData == null ? null : LtiLis.fromJson(lisData);
    mentorSubjectIds = claims.containsKey(LtiClaims.roleScopeMentor)
        ? stringList(
            claims[LtiClaims.roleScopeMentor],
            field: LtiClaims.roleScopeMentor,
          )
        : const [];
    if (mentorSubjectIds.any((id) => !isLtiIdentifier(id)) ||
        (mentorSubjectIds.isNotEmpty && !roles.contains(LtiRoles.mentor))) {
      throw const LtiException(
        LtiErrorCode.invalidClaims,
        'Mentor subjects require the Mentor role and valid user IDs.',
      );
    }
    final customData = optionalObject(claims, LtiClaims.custom);
    custom = customData == null
        ? const {}
        : Map.unmodifiable(
            jsonObject(customData).map((key, value) {
              if (value is! String) {
                throw const LtiException(
                  LtiErrorCode.invalidClaims,
                  'Custom parameters must be strings.',
                );
              }
              return MapEntry(key, value);
            }),
          );
  }

  /// Trusted registration used to verify this launch.
  final LtiRegistration registration;

  /// Deeply immutable verified claims, including unknown extension claims.
  /// Contains potentially personal data; do not log the entire map.
  final Map<String, Object?> claims;

  /// Validated AGS capabilities, or null when the platform did not advertise AGS.
  late final LtiAgsEndpoints? ags;

  /// Validated NRPS capabilities, or null when membership access was not advertised.
  late final LtiNrpsEndpoint? nrps;

  /// Verified user metadata, or null for a launch without a subject.
  late final LtiUser? user;

  /// Immutable role values from the verified token; apply application authorization
  /// separately.
  late final List<String> roles;

  /// Optional validated course/group metadata; never assume every launch has a course.
  late final LtiContext? context;

  /// Optional platform instance metadata from the verified claim.
  late final LtiPlatformInstance? platform;

  /// Optional launch display hints and platform return navigation.
  late final LtiLaunchPresentation? presentation;

  /// Optional source-system identifiers; these may be omitted for privacy.
  late final LtiLis? lis;

  /// Immutable list of subjects covered by the verified mentor claim.
  late final List<String> mentorSubjectIds;

  /// Immutable custom string parameters; authorization remains the host's
  /// responsibility.
  late final Map<String, String> custom;

  /// Verified deployment ID belonging to [registration].
  String get deploymentId => claims[LtiClaims.deploymentId]! as String;

  /// Exact trusted target URL bound to the consumed login transaction.
  final String targetLinkUri;

  static LtiContext _context(Map<String, Object?> data) {
    final id = requiredString(data, 'id');
    if (!isLtiIdentifier(id)) {
      throw const LtiException(
        LtiErrorCode.invalidClaims,
        'Invalid context identifier.',
      );
    }
    final types = data.containsKey('type')
        ? stringList(
            data['type'],
            field: 'context.type',
          ).map(LtiContextTypes.normalize).toList(growable: false)
        : const <String>[];
    if (data.containsKey('type') &&
        (!types.any(LtiContextTypes.standard.contains) ||
            types.any((type) => !(Uri.tryParse(type)?.hasScheme ?? false)))) {
      throw const LtiException(
        LtiErrorCode.invalidClaims,
        'Context types must include a standard context URI.',
      );
    }
    return LtiContext(
      id: id,
      label: optionalString(data, 'label'),
      title: optionalString(data, 'title'),
      types: types,
    );
  }
}

/// A verified resource-link launch, ready for application authorization.
final class LtiResourceLaunch extends LtiLaunch {
  LtiResourceLaunch._(super.registration, super.data, super.target)
    : super._(rolesRequired: true) {
    final link = jsonObject(
      claims[LtiClaims.resourceLink],
      field: LtiClaims.resourceLink,
    );
    final id = requiredString(link, 'id');
    if (!isLtiIdentifier(id)) {
      throw const LtiException(
        LtiErrorCode.invalidClaims,
        'Invalid resource identifier.',
      );
    }
    resourceLink = LtiResourceLink(
      id: id,
      title: optionalString(link, 'title'),
      description: optionalString(link, 'description'),
    );
  }

  /// Verified placement information for the launched resource.
  late final LtiResourceLink resourceLink;
}

/// A verified selection request. Retain this object in a protected server session.
final class LtiDeepLinkingLaunch extends LtiLaunch {
  LtiDeepLinkingLaunch._(super.registration, super.data, super.target)
    : super._(rolesRequired: false) {
    settings = LtiDeepLinkingSettings.fromJson(
      jsonObject(claims[LtiDeepLinkingClaims.settings]),
    );
  }

  /// Validated selection capabilities and return destination from the platform.
  late final LtiDeepLinkingSettings settings;
}
