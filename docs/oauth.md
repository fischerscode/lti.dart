# OAuth service authentication

The token client implements the client-credentials exchange in the
[1EdTech Security Framework](https://www.imsglobal.org/spec/security/v1p0/#using-json-web-tokens-with-oauth-2-0-client-credentials-grant).
AGS and NRPS operations use this client through [LtiServiceClient](services.md).
Live ByCS service tests successfully used this token exchange with the explicit
Moodle content-type compatibility option; see [ByCS testing](bycs-testing.md).

## API

Reuse a client instance and a trusted, immutable registration:

```dart
final oauth = LtiOAuthClient(
  client: httpClient, // Caller owns and closes this transport.
  signer: signer, // Existing LtiJwtSigner and persistent signing key.
);

final token = await oauth.accessToken(
  registration: registration,
  scopes: {'https://purl.imsglobal.org/spec/lti-nrps/scope/contextmembership.readonly'},
  // Optional: only when required by the platform's assertion profile.
  // deploymentId: verifiedLaunch.deploymentId,
);

// token.value is a secret. Only send it to an independently validated
// HTTPS service destination; never expose it in logs, URLs or browser pages.
```

Scopes must come from the application's required operation and the verified
platform capabilities; this client does not infer authorization from a role.
Successful token acquisition does not authorize arbitrary service destinations.

## Exchange and response

The configured registration token endpoint is the only destination. HTTPS,
credential-free URLs and absence of fragments are enforced by LtiRegistration.
Redirects are disabled. Administrators must provision trustworthy endpoints;
HTTPS validation alone is not a DNS/private-network SSRF filter. Network egress
restrictions remain the hosting application's responsibility.

Each exchange signs a fresh assertion with iss/sub equal to client ID and aud
from authorizationServerAudience, falling back to tokenEndpoint. It posts
grant_type, client_assertion_type, client_assertion and canonical scope as a URL
encoded form. There are no automatic retries.

By default, a successful response must have `Content-Type: application/json`.
For an affected, trusted Moodle/ByCS endpoint, construct `LtiOAuthClient` with
`allowMoodleTokenContentType: true`. This also accepts a missing content type,
`text/html` or `text/plain`; the body must still pass all JSON and token checks.
The option applies to every registration using that client, so keep a separate
client for platforms that need it. See the
[ByCS compatibility record](bycs-testing.md#moodle-oauth-content-type-compatibility).

A successful response must be HTTP 200 JSON with a nonempty Bearer credential
and positive integer expires_in (at most 2147483647 seconds). Missing scope means
the requested set; a returned scope must cover all requested scopes. Reduced
grants fail explicitly. Lifetime is measured conservatively from request start;
already-expired responses fail. Tokens too close to expiry may be returned for
immediate use but are not cached.

Requests have a total timeout (including signing and response reading) and a
response size bound. The transport should support package:http AbortableRequest
(as IOClient does); a custom transport must honor its abort trigger to release
network work promptly on timeout. Late completions never populate the cache.

## Cache and errors

Cache entries are isolated by registration object identity, optional deployment
and exact sorted scope set. Reuse registration instances for cache hits; creating
a new registration object intentionally cannot inherit an old entry. Superset
tokens are not reused for a different requested scope set. The in-memory cache
and distinct pending requests are bounded; concurrent identical requests share
one exchange. Default early refresh margin is 30 seconds.

The service client automatically calls `oauth.invalidate(token)` on HTTP 401.
If you implement service requests yourself, call it when a token is rejected.
This removes only the matching cached object, not a newer replacement. The application
decides whether the failed operation is safe to retry. Recreate the client when
immediate invalidation of all credentials is required; the cache is not durable
or shared across isolates.

`LtiOAuthException.code` is one of `rejected`, `unavailable`, `invalidResponse`,
`insufficientScope` or `capacity`. The exception also exposes an optional HTTP
`statusCode` and a fixed `responseIssue` category for validation failures, such
as `contentType` or `expiresIn`.
Assertions, access tokens, response descriptions and transport error text are
never included. Token toString is redacted; accessing value is explicit.
Do not log HTTP request/response bodies in a custom transport.

## Validation

Tests verify real RS256 assertion signatures, audience override, form encoding,
scope canonicalization and grant validation, concurrent fetching, registration/
deployment/scope isolation, early refresh, invalidation, eviction, short and
expired lifetimes, HTTP errors and redirect rejection, response size, timeout
and diagnostic redaction. These automated checks complement the live ByCS
service tests; platform permissions must still be configured for each tool.
