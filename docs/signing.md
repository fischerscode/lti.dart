# Tool signing and key rotation

`LtiJwtSigner` builds RS256 tool-message envelopes and OAuth client assertions.
It is independent of HTTP and storage. `LtiTool.signer` optionally connects it to
the Shelf adapter, which then exposes `GET`/`HEAD /lti/jwks`.

```dart
final key = RsaLtiSigningKey.fromPem(privatePem, keyId: 'tool-2026-09');
final keys = MemoryLtiSigningKeyProvider(key);
final signer = LtiJwtSigner(keys: keys);
```

Load a stable RSA private key (at least 2048 bits) from the application's secret
store. Do not generate a new key for each launch or process restart. JWK import
is also available through `RsaLtiSigningKey.fromJwk`. The library verifies the
private/public pair on import and never exports private material. Configuration
errors from local key import do not contain key values.

`LtiPublicKey` stores only key ID, modulus and exponent. Its JWK representation
adds fixed RS256/signature metadata and verification-only key operations.
Unknown fields and RSA private parameters cannot appear through the JWKS route,
even if the input JWK contained them.

## Signing APIs

`signer.signMessage(registration: ..., deploymentId: ..., messageType: ...,
claims: ...)` supplies issuer/client ID, platform audience, issued/expiry times,
nonce, LTI version and deployment. Payloads cannot override those security
fields. The payload is snapshotted before awaiting an external signer.

This generic method validates the envelope only. A signed payload is **not**
automatically a valid Deep Linking response. Use
`LtiTool.createDeepLinkingResponse` for typed, validated selections; see the
[Deep Linking guide](deep-linking.md).

`signer.createClientAssertion(registration: ..., deploymentId: ...)` prepares a
JWT for an OAuth token request. Issuer and subject both contain the client
ID, and every assertion receives a fresh `jti`. The audience is the registration's
explicit `authorizationServerAudience`, or its `tokenEndpoint` if no separate
audience was provisioned. This signer method does not make network requests or
cache access tokens; `LtiOAuthClient` supplies that functionality.

The default lifetime is five minutes, configurable from one second to five
minutes. Tokens which expire while waiting for an external signer are rejected.

## External signing

Implement `LtiSigningKey` to expose a typed public key and sign bytes with
RSASSA-PKCS1-v1_5/SHA-256. This allows private keys to remain inside a KMS/HSM.
`LtiSigningKeyProvider` selects a key for each registration and enumerates the
published public keys. The library verifies the returned signature against that
key before returning the compact JWT. Providers are trusted application code;
they must use matching, published keys and safe diagnostics.

## Rotation sequence

1. Load the new private key with a **new** `kid`.
2. Call `keys.publish(newKey.publicKey)` and let platform JWKS caches refresh.
3. Call `keys.activate(newKey)`. The previous public key remains published.
4. Keep both public keys until old tokens, clock tolerance, in-flight signing
   operations and platform caches no longer need the old key.
5. Call `keys.retire(oldKeyId)` to remove its public key.

Activating an unpublished key, retiring the active key and assigning different
RSA material to a previously seen `kid` are rejected. The memory provider holds
only one active private-key reference. Public key history is process-local, so a
production provider must persist rotation state and coordinate all replicas.

The Shelf endpoint advertises `public, max-age=300` by default, configurable via
`jwksCacheLifetime`. Lowering this does not retroactively invalidate cached keys.
Rotation timing must account for the platform's actual caching behavior.

## Example and validation

The Shelf example accepts optional `LTI_PRIVATE_KEY_FILE` (PEM) and `LTI_KEY_ID`
environment variables. Set both to enable signing. Without `LTI_PRIVATE_KEY_FILE`,
incoming resource launches still work and no JWKS route is exposed. When signing
is enabled, register its HTTPS JWKS URL or direct RSA public key with the LMS,
according to the platform's configuration. ByCS live tests used the direct key;
its retrieval of the tool JWKS remains unresolved.

`signing_test.dart` verifies real signatures, assertion identities, reserved
claims, staged rotation, PEM import and asynchronous signing. `jwks_route_test.dart`
verifies HTTP method/cache behavior, public-only serialization and verification
with keys obtained through the HTTP adapter. Test keys are generated in memory.
