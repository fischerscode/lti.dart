# Implementation and verification matrix

The target is LTI 1.3 Core plus Deep Linking 2.0, AGS 2.0 and NRPS 2.0 on the
**tool side**. This matrix is an implementation plan, not a conformance claim.
Before declaring compatibility, expand it into a clause-by-clause normative
checklist against the specifications and their errata.

| Area | Status | Evidence / remaining work |
| --- | --- | --- |
| FVM / Melos workspace | Implemented | Pinned SDK, shared lockfile, scripts, Conventional Commit check |
| Manual registration | Implemented | Exact issuer/client resolution, HTTPS URLs, deployment and target allowlists |
| OIDC login | Implemented | GET/POST adapter, opaque hints, state/nonce/browser binding |
| JWT signatures | Implemented | RS256, configured JWKS, minimum RSA size, cache and rotation tests |
| Resource launch | Initial implementation | Required claim checks, anonymous users, immutable typed resource/context |
| Replay protection | Implemented | Atomic consume contract and concurrent-submission tests |
| HTTP adapter | Implemented | POST callback, form limits, duplicate rejection, cookie preservation |
| Full Core optional claims | Pending | Typed presentation/LIS/platform/mentor data, role vocabulary validation; unknown claims retained |
| Production storage adapters | Pending | Shared SQL/Redis transactions and backend-specific atomicity tests |
| Tool signing and public JWKS | Pending | Signing interface, outgoing signatures and rotation |
| Deep Linking 2.0 | Pending | Request validation, accepted types/targets, content items, data echo, signed form response |
| OAuth service access | Pending | Client assertion signing, scoped token requests, cache, failures and destination policy |
| AGS 2.0 | Pending | Line item CRUD, score submission, results, scopes, media types and pagination |
| NRPS 2.0 | Pending | Membership pages, roles/status, filters and optional personal fields |
| Cookie-restricted iframe flow | Pending | Platform-supported browser storage, integration tests in real browsers |
| Dynamic Registration | Separate extension | Decide profile and requirements after manual ByCS integration |
| ByCS interoperability | Pending | Real registration, launch in course, privacy settings, enabled capabilities |
| Formal certification | Out of initial scope | Separate certification decision and test process |

## Milestones

1. **Launch foundation (current):** reproducible workspace, trusted registration,
   browser-bound resource launch, Shelf adapter and cryptographic negative tests.
2. **Core completion and signing:** normative checklist, optional typed claims,
   role vocabulary checks, signing-key lifecycle and public JWKS endpoint.
3. **Deep Linking:** verified selection request, protocol-complete response builder
   and form response; demonstrate round trip against a reference platform.
4. **Services:** scoped OAuth client, AGS and NRPS with pagination, transport
   policies and tests for insufficient capabilities and token expiry.
5. **Interoperability:** complete deployment with ByCS, supported embedded-browser
   flows, durable storage reference and conformance regression tests.

## ByCS integration inputs

Obtain exact issuer, client ID, deployment IDs, authorization endpoint, JWKS URL
and token endpoint from the authenticated platform. Register tool login/callback
and later tool JWKS/deep-link URLs. Record which scopes and message types are
actually enabled. Use a test course and synthetic users. Never commit production
credentials, raw personal launch payloads or private keys.
