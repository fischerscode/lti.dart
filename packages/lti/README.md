# lti

Framework-independent, server-side LTI tool library for Dart.

This development version provides manual registrations, OIDC login initiation,
RS256/JWKS verification, replay-protected resource launches and typed launch data.
It is **not yet a complete LTI 1.3 implementation**. Deep Linking, AGS, NRPS,
and dynamic registration are planned. Tool signing, OAuth client assertions and
public-key rotation are available through `LtiJwtSigner`; access-token requests
and message-specific Deep Linking response validation remain pending.

Create `LtiTool` with a registration store, transaction store and
`RemoteJwksVerifier`. Call `beginLogin`, retain the returned browser binding in
protected browser storage, and call `completeResourceLaunch` with that binding
when processing the platform's response. Never accept the binding from the
platform's form body. Use `lti_shelf` for a ready-made HTTP adapter.

Store user identities using issuer plus subject, and scope application permissions
to the deployment/context. `launch.user` is null for anonymous launches. The
in-memory transaction store is for single-isolate development; production needs
an atomic shared implementation of `LtiTransactionStore`.
