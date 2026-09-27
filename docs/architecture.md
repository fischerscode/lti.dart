# Architecture

## Boundaries

`lti` runs in a trusted backend. It has no Flutter or Shelf dependency. Applications
provide registrations, transaction storage and an HTTP client. The standard
`RemoteJwksVerifier` uses JOSE for cryptography and only trusts configured keys.
`LtiTokenVerifier` is an explicitly trusted extension point for other key systems;
an implementation which only decodes JWTs breaks the security contract.

`lti_shelf` handles HTTP encoding, method restrictions and browser binding, then
calls application code with a verified `LtiResourceLaunch` or
`LtiDeepLinkingLaunch`. The application owns its sessions, authorization, UI,
persistence and business logic. A verified role is contextual data, not an
automatic grant of application permissions.

## Resource launch

1. A platform sends an unsigned login initiation to `/lti/login` using GET or
   form POST. Issuer/client must resolve to one provisioned registration.
2. The tool checks the exact allowed target and optional deployment hint. It
   creates independent random state, nonce and browser-binding secrets.
3. The Shelf adapter stores the binding in a per-transaction `__Host-` cookie and
   redirects to the provisioned authorization endpoint. Hints remain opaque.
4. The platform submits `state` and `id_token` to `/lti/launch` with form POST.
5. The adapter supplies the binding from the browser cookie. The core atomically
   consumes the matching unexpired transaction, then reloads the registration.
6. The verifier checks RS256 using the platform's configured public JWKS. The core
   checks issuer, audience/authorized party, timestamps, nonce, version, message,
   deployment and target. The resource link and roles are required; user identity
   and context are optional but validated when present.
7. The application receives an immutable verified launch, establishes its own
   session and responds. The adapter expires the login cookie and preserves
   application response cookies. Launch tokens must not be passed to the frontend.

The unsigned login target is matched again against the signed claim. Registration
changes can revoke a client, deployment or target while a login is in progress.
Issuer identifiers are strings and are compared exactly. An anonymous launch has
no user; names and email addresses are optional. Application user keys should
include issuer and subject, with tenant isolation applied separately. Resource
and context keys must include their registration/deployment scope.

Additional audiences in a token must be explicitly configured through
`additionalTrustedAudiences`; matching `azp` alone does not establish trust.
Platform, presentation and LIS metadata are typed. Standard roles and context
types are validated without interpreting them as application permissions.
Bound OIDC error responses terminate the transaction; raw platform error text is
not reflected. Invalid tokens/claims, platform authentication errors and unknown
registrations return HTTP 401 from the Shelf callback. State/binding and malformed
request errors return 400; platform key-fetch failures return 502.

## Storage contract

`LtiTransactionStore.save` must reject duplicate state. `consume` must match state,
browser binding and expiry and delete the transaction as one atomic operation.
A wrong browser must not consume another browser's transaction. Concurrent calls
must return the record at most once, including across isolates/server instances.
Persist the entire immutable transaction and use server-side time consistently.

The in-memory implementation prunes expired entries when saving, caps its size
and works in one isolate. Production adapters for SQL/Redis are future work.
Do not replace atomic consumption with a separate read followed by deletion.

## Key retrieval and limits

The HTTP client is caller-owned. JWKS retrieval disables redirects and limits
time, response size and number of keys. The verifier imports only public RSA
material, requires a key ID and at least 2048-bit keys, and restricts algorithms
to RS256. Token-provided JWKS URLs and embedded keys cannot establish trust.

The cache expires after 15 minutes by default. An unknown key ID triggers refresh
after a 30-second cooldown. Concurrent fetches for the same endpoint are shared.
Platforms should overlap old and new keys during rotation. Reusing a key ID for
new material may require cache expiry. No stale-key fallback is used on expiry.

Host applications must protect login endpoints with rate limits and set HTTP
request timeouts. A failed launch consumes its correctly bound transaction;
retry by starting a fresh platform launch. Errors returned to the browser omit
tokens, claims and internal exception details.

## Signing

An optional `LtiTool.signer` owns outgoing JWT construction. Its key provider
exposes signing operations separately from typed public keys. The Shelf JWKS
route serializes only the latter. See [signing and rotation](signing.md).

## Advantage services

Verified launch objects expose typed AGS and NRPS capabilities. LtiServiceClient
binds requests to their registration/deployment and an administrator-provisioned
HTTPS origin allowlist. It validates service, item and pagination destinations
before acquiring/forwarding bearer tokens. Scoped OAuth tokens are cached by
registration identity, deployment and exact scope set; requests and page streams
are bounded. Requests never follow redirects or retry automatically, including
read requests.
See [OAuth](oauth.md) and [service APIs](services.md).

The library supplies protocols, not application persistence. Host applications
own grade event ordering, roster reconciliation, durable sessions and business
authorization. Separate LTI extensions remain outside the Core/Advantage target.

Code generation is currently unnecessary. Core and Advantage remain modules of
one package until a concrete dependency or release boundary justifies a split.
