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
rejects missing cookies. Set `partitionedCookies: true` to opt into CHIPS for
embedded launches in supporting browsers. This applies to cookie creation and
deletion; browser policy may still prevent cookie access. Use top-level launches
where embedded cookies are unavailable. For iframe embedding, replace Dart
HttpServer's default `X-Frame-Options: SAMEORIGIN` with a CSP `frame-ancestors`
allowlist of trusted platform origins (see the ByCS runner). Application sessions and authorization remain the application's job.

This is a development release; it does not yet implement the complete LTI 1.3 /
LTI Advantage suite. Configure `onDeepLinkingLaunch` to receive verified selection
requests on the same launch route. Use `deepLinkingFormResponse` to return a
response signed by `LtiTool.createDeepLinkingResponse`; it renders an escaped
auto-post form with a manual-submit button. The consuming tool supplies the
selection UI and protected session. See the repository
[Deep Linking guide](../../docs/deep-linking.md).

For the WSL/SSH integration setup, `example/bycs_server.dart` provides HTTPS,
a verified resource result and a browser-bound Deep Linking selection/cancel UI.
See [ByCS testing](../../docs/bycs-testing.md) for configuration and live checks.
