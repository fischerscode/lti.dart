# lti

Framework-independent, server-side LTI tool library for Dart.

This development version provides manual registrations, OIDC login initiation,
RS256/JWKS verification, replay-protected resource launches and typed launch data.
Deep Linking selection requests and signed responses are also supported.
AGS and NRPS are available through `LtiServiceClient`, bound to a verified launch
and an explicit HTTPS origin allowlist. Dynamic Registration is a separate,
unimplemented extension. Tool signing, OAuth client assertions and public-key
rotation are available through `LtiJwtSigner`. `LtiOAuthClient` requests and caches
scoped client-credentials access tokens using that signer.

Create `LtiTool` with a registration store, transaction store and
`RemoteJwksVerifier`. Call `beginLogin`, retain the returned browser binding in
protected browser storage, and call `completeResourceLaunch` with that binding
when processing the platform's response. Never accept the binding from the
platform's form body. Use `lti_shelf` for a ready-made HTTP adapter.

Store user identities using issuer plus subject, and scope application permissions
to the deployment/context. `launch.user` is null for anonymous launches. The
in-memory transaction store is for single-isolate development; production needs
an atomic shared implementation of `LtiTransactionStore`.

Use `completeLaunch` to dispatch both message types. For a verified
`LtiDeepLinkingLaunch`, call `createDeepLinkingResponse` with immutable
`LtiContentItem` selections (or an empty list to cancel). The repository
[Deep Linking guide](../../docs/deep-linking.md) describes negotiation, application
session responsibilities and current interoperability limitations.


The Core/Advantage protocol surface is implemented and tested locally; it is
not formally certified. Host applications supply durable transactions,
application authorization, browser sessions, trusted endpoints and ordered score
updates. Real service interoperability must still be tested with each platform.
