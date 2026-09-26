/// Stable categories suitable for application diagnostics without logging tokens.
enum LtiErrorCode {
  invalidRequest,
  unknownRegistration,
  invalidState,
  authenticationFailed,
  invalidToken,
  invalidClaims,
  unsupportedMessage,
  platformUnavailable,
}

/// A protocol failure. Messages deliberately omit tokens and personal data.
final class LtiException implements Exception {
  const LtiException(this.code, this.message);

  final LtiErrorCode code;
  final String message;

  @override
  String toString() => 'LtiException(${code.name}): $message';
}
