# lti_shelf

Shelf adapter for the Dart `lti` library. Mount `LtiShelf.handler` at the server
root to handle GET/POST login initiation and POST resource launches. The
`onResourceLaunch` callback only receives a verified `LtiResourceLaunch`.

See `example/server.dart` for configuration. HTTPS is required at the public
origin; localhost may run behind a trusted HTTPS reverse proxy. Register the
exact callback URL with the platform and in `LtiRegistration`.

When `LtiTool.signer` is configured, the adapter exposes GET/HEAD `/lti/jwks` with
public verification keys only. Override `jwksPath` and `jwksCacheLifetime` as
needed. See the repository signing guide for staged key rotation.

The adapter uses a Secure, HttpOnly, SameSite=None cookie for browser binding and
rejects missing cookies. Use top-level launches when third-party cookies are
blocked. Application sessions and authorization remain the application's job.

This is a development release; it does not yet implement the complete LTI 1.3 /
LTI Advantage suite. Only resource launch messages are currently dispatched.
