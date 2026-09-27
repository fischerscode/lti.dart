/// Stable categories suitable for application diagnostics without logging tokens.
enum LtiErrorCode {
  /// The initiation or callback request is malformed or disallowed.
  invalidRequest,

  /// No unique trusted registration exists for the supplied issuer/client.
  unknownRegistration,

  /// Login state is missing, expired, consumed, or bound to another browser.
  invalidState,

  /// The platform did not provide the required authentication response.
  authenticationFailed,

  /// The ID token cannot be parsed or cryptographically verified.
  invalidToken,

  /// Verified claims violate the expected identity, time or LTI constraints.
  invalidClaims,

  /// The message type is not supported by the selected handler.
  unsupportedMessage,

  /// Trusted platform keys could not be retrieved or validated.
  platformUnavailable,
}

/// A protocol failure. Messages deliberately omit tokens and personal data.
final class LtiException implements Exception {
  /// Creates a protocol failure; [message] must not include secrets or personal data.
  const LtiException(this.code, this.message);

  /// Stable protocol failure category for application error handling.
  final LtiErrorCode code;

  /// Diagnostic description; custom implementations must keep it free of secrets.
  final String message;

  @override
  String toString() => 'LtiException(${code.name}): $message';
}
