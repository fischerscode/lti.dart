# Implementation and verification matrix

The target is LTI 1.3 Core plus Deep Linking 2.0, AGS 2.0 and NRPS 2.0 on the
**tool side**. This matrix is an implementation plan, not a conformance claim.
See the [Core protocol checklist](core-conformance.md) for requirement mappings,
errata decisions, tested behavior and remaining integration obligations.

| Area | Status | Evidence / remaining work |
| --- | --- | --- |
| FVM / Melos workspace | Implemented | Pinned SDK, shared lockfile, scripts, Conventional Commit check |
| Manual registration | Implemented | Exact issuer/client resolution, HTTPS URLs, deployment and target allowlists |
| OIDC login | Implemented | GET/POST adapter, opaque hints, state/nonce/browser binding |
| JWT signatures | Implemented | RS256, configured JWKS, minimum RSA size, cache and rotation tests |
| Resource launch | Implemented | Required claim checks, anonymous users, immutable typed resource/context |
| Replay protection | Implemented | Atomic consume contract and concurrent-submission tests |
| HTTP adapter | Implemented | POST callback, form limits, duplicate rejection, cookie preservation |
| Core optional claims and vocabularies | Implemented | Typed presentation/LIS/platform/mentor data, standard roles/context types; unknown claims retained |
| Production storage adapters | Pending | Shared SQL/Redis transactions and backend-specific atomicity tests |
| Tool signing and public JWKS | Implemented | Local JWK/PEM and external signer contract, envelopes, public-only route and staged rotation |
| Deep Linking 2.0 | Implemented; ByCS resource selection round trip reported | Verified selection, five content types, negotiation, opaque data echo, signed POST form; see [scope and limitations](deep-linking.md) |
| OAuth service access | Token client implemented | Signed assertions, exact-scope bounded cache, concurrent fetch coalescing, expiry, bounded transport and safe errors; live ByCS token test pending; service origin policy implemented; see [OAuth](oauth.md) |
| AGS 2.0 | Implemented; local tests | Line item CRUD, score submission/clearing, results, scopes, media types, pagination, typed metadata and extensions; [API](services.md) |
| NRPS 2.0 | Implemented; local tests | Membership pages/differences, roles/status, filters, message claims and optional personal fields; [API](services.md) |
| Cookie-restricted iframe flow | Partial | Opt-in partitioned cookies; one ByCS selection iframe flow reported successful; browser/policy coverage pending |
| Dynamic Registration | Separate extension | Decide profile and requirements after manual ByCS integration |
| ByCS interoperability | Resource launch, Deep Linking round trip and cancellation verified | Operator-reported success on 2026-09-27 using a directly configured RSA public key; platform JWKS retrieval, broader role/browser coverage and services pending; see [integration record](bycs-testing.md) |
| Formal certification | Out of initial scope | Separate certification decision and test process |

## Milestones

1. **Launch foundation (implemented):** reproducible workspace, trusted registration,
   browser-bound resource launch, Shelf adapter and cryptographic negative tests.
2. **Core claims and signing (implemented):** normative checklist, optional typed claims,
   role vocabulary checks, signing-key lifecycle and public JWKS endpoint.
3. **Deep Linking (implemented):** verified selection request, response builder
   and form response; local simulator tested and ByCS resource selection round trip
   reported successful with a directly configured RSA public key, including
   cancellation. Other content types remain pending on the live platform.
4. **Services (implemented):** scoped OAuth client, AGS and NRPS with pagination,
   transport policies and negative tests. Live ByCS service checks deferred.
5. **Interoperability:** complete deployment with ByCS, supported embedded-browser
   flows, durable storage reference and conformance regression tests.

## ByCS integration inputs

Obtain exact issuer, client ID, deployment IDs, authorization endpoint, JWKS URL
and token endpoint from the authenticated platform. Register tool login/callback
and later tool JWKS/deep-link URLs. Record which scopes and message types are
actually enabled. Use a test course and synthetic users. Never commit production
credentials, raw personal launch payloads or private keys.


## Meaning of implementation completeness

The library now supplies the tool-side LTI 1.3 Core, Deep Linking 2.0, OAuth,
AGS 2.0 and NRPS 2.0 protocol APIs. This does not claim formal conformance.
Application-owned responsibilities include durable atomic transaction/session
storage, role-based business authorization, ordered score timestamps, secret
lifecycle, trusted network destinations and roster persistence.

Dynamic Registration, Submission Review, Basic Outcomes compatibility, browser
postMessage/storage extensions and Common Cartridge authoring are separately
versioned extensions or adjacent standards; they are not implicitly included in
the Core 1.3/Advantage target. The current cookie-bound flow fails closed when
browser storage is unavailable. ByCS service testing is intentionally deferred
at the user's request; the existing live resource/Deep Linking results remain
limited to the tested browser and direct RSA key configuration.
