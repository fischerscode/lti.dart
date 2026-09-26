import 'dart:convert';
import 'dart:math';

import 'errors.dart';
import 'jwks.dart';
import 'models.dart';
import 'store.dart';
import 'signing.dart';
import 'vocabularies.dart';

/// Orchestrates login and validation without depending on a web framework.
final class LtiTool {
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
  final LtiRegistrationStore registrations;
  final LtiTransactionStore transactions;
  final LtiTokenVerifier tokenVerifier;
  final LtiJwtSigner? signer;
  final DateTime Function() _clock;
  final Duration loginLifetime;
  final Duration clockTolerance;
  final Duration maxTokenAge;
  final _random = Random.secure();

  String _randomToken() => base64Url
      .encode(List.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

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

  /// [browserBinding] must come from the initiating browser's protected storage,
  /// never from the platform's POST body. Every attempt consumes its transaction.
  Future<LtiResourceLaunch> completeResourceLaunch({
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
    return LtiResourceLaunch._(registration, claims);
  }

  /// Terminates a browser-bound OIDC error response. Error descriptions from the
  /// platform are intentionally not reflected or logged by the protocol library.
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
    Never invalid() => throw const LtiException(
      LtiErrorCode.invalidClaims,
      'Launch claims do not match the login.',
    );
    if (!transaction.expiresAt.isAfter(now) ||
        claims['iss'] != registration.issuer ||
        claims['nonce'] != transaction.nonce) {
      invalid();
    }
    final audience = claims['aud'];
    final audiences = audience is String ? [audience] : stringList(audience);
    if (!audiences.contains(registration.clientId) ||
        audiences.any(
          (audience) =>
              audience != registration.clientId &&
              !registration.additionalTrustedAudiences.contains(audience),
        ) ||
        (audiences.length > 1 && claims['azp'] != registration.clientId) ||
        (claims.containsKey('azp') && claims['azp'] != registration.clientId)) {
      invalid();
    }
    num numericDate(String name) {
      final value = claims[name];
      if (value is! num || !value.isFinite) invalid();
      return value;
    }

    final seconds = now.millisecondsSinceEpoch / 1000;
    final tolerance = clockTolerance.inMilliseconds / 1000;
    final issued = numericDate('iat');
    final expires = numericDate('exp');
    if (expires <= seconds - tolerance ||
        issued > seconds + tolerance ||
        issued < seconds - maxTokenAge.inMilliseconds / 1000 - tolerance ||
        issued <
            transaction.createdAt.millisecondsSinceEpoch / 1000 - tolerance ||
        expires <= issued ||
        (claims.containsKey('nbf') &&
            numericDate('nbf') > seconds + tolerance)) {
      invalid();
    }
    if (claims[LtiClaims.version] != '1.3.0') invalid();
    if (claims[LtiClaims.messageType] != 'LtiResourceLinkRequest') {
      throw const LtiException(
        LtiErrorCode.unsupportedMessage,
        'This release supports resource launches only.',
      );
    }
    final deployment = requiredString(claims, LtiClaims.deploymentId);
    if (!registration.deploymentIds.contains(deployment) ||
        (transaction.deploymentId != null &&
            transaction.deploymentId != deployment) ||
        claims[LtiClaims.targetLinkUri] != transaction.targetLinkUri ||
        !registration.targetLinkUris.contains(transaction.targetLinkUri)) {
      invalid();
    }
  }
}

/// A resource launch that passed signature, transaction and claim validation.
/// Instances can only be created by [LtiTool]. Does not imply app authorization.
final class LtiResourceLaunch {
  LtiResourceLaunch._(this.registration, Map<String, Object?> data)
    : claims = freezeJson(data) as Map<String, Object?> {
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
    roles = stringList(claims[LtiClaims.roles]);
    if (roles.any((role) => !(Uri.tryParse(role)?.hasScheme ?? false)) ||
        (roles.isNotEmpty && !roles.any(LtiRoles.isStandard))) {
      throw const LtiException(
        LtiErrorCode.invalidClaims,
        'Roles must be URIs and include a standard role when nonempty.',
      );
    }
    final link = jsonObject(claims[LtiClaims.resourceLink]);
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
        ? stringList(claims[LtiClaims.roleScopeMentor])
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
  final LtiRegistration registration;
  final Map<String, Object?> claims;
  late final LtiUser? user;
  late final List<String> roles;
  late final LtiResourceLink resourceLink;
  late final LtiContext? context;
  late final LtiPlatformInstance? platform;
  late final LtiLaunchPresentation? presentation;
  late final LtiLis? lis;
  late final List<String> mentorSubjectIds;
  late final Map<String, String> custom;
  String get deploymentId => claims[LtiClaims.deploymentId]! as String;
  String get targetLinkUri => claims[LtiClaims.targetLinkUri]! as String;

  static LtiContext _context(Map<String, Object?> data) {
    final id = requiredString(data, 'id');
    if (!isLtiIdentifier(id)) {
      throw const LtiException(
        LtiErrorCode.invalidClaims,
        'Invalid context identifier.',
      );
    }
    final types = data.containsKey('type')
        ? stringList(data['type'])
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
