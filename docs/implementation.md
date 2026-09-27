# Implementation and verification matrix

The target is LTI 1.3 Core plus Deep Linking 2.0, AGS 2.0 and NRPS 2.0 on the
**tool side**. This matrix records implementation and verification status,
not certification.
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
| OAuth service access | Token client implemented | Signed assertions, exact-scope bounded cache, concurrent fetch coalescing, expiry, bounded transport and safe errors; live ByCS token exchange reported successful with the explicit Moodle content-type option; service origin policy implemented; see [OAuth](oauth.md) |
| AGS 2.0 | Implemented; local tests and reported ByCS grade workflows | Line item CRUD, score submission/clearing, results, scopes, media types, pagination, typed metadata and extensions; [API](services.md) |
| NRPS 2.0 | Implemented; local tests and reported ByCS membership read | Membership pages/differences, roles/status, filters, message claims and optional personal fields; [API](services.md) |
| Cookie-restricted iframe flow | Partial | Opt-in partitioned cookies; one ByCS selection iframe flow reported successful; browser/policy coverage pending |
| Dynamic Registration | Separate extension | Decide profile and requirements after manual ByCS integration |
| ByCS interoperability | Resource launch, Deep Linking, OAuth, NRPS and AGS workflows reported successful | Tests used a directly configured RSA public key; ByCS retrieval of the tool JWKS and broader role/browser coverage remain unresolved or unverified; see [integration record](bycs-testing.md) |
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
   transport policies and negative tests. Live ByCS membership reads, line item
   CRUD and score submission/readback/clearing were reported successful.
5. **Interoperability:** complete deployment with ByCS, supported embedded-browser
   flows, durable storage reference and conformance regression tests.

## ByCS integration inputs

Obtain exact issuer, client ID, deployment IDs, authorization endpoint, JWKS URL
and token endpoint from trusted platform settings or an administrator. Register
the tool login, callback, activity and content-selection URLs, plus its public
key or JWKS URL. The examples share the activity and content-selection target.
Record which scopes and message types are actually enabled. Use a test course and synthetic users. Never commit production
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
browser storage is unavailable. The reported ByCS results cover the workflows
listed in the [integration record](bycs-testing.md), using the tested browser
and a directly configured RSA public key. They do not establish interoperability
with other platforms or successful ByCS retrieval of the tool JWKS.
