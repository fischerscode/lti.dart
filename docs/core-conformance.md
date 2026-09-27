# Core protocol checklist

Reviewed against [LTI Core 1.3](https://www.imsglobal.org/spec/lti/v1p3/), its
[errata](https://www.imsglobal.org/spec/lti/v1p3/errata/) and the
[Security Framework](https://www.imsglobal.org/spec/security/v1p0/).
This is an engineering checklist for the implemented resource-launch profile,
not a certification. Advantage service implementation is covered separately
in [services.md](services.md).

| Requirement / section | Implementation and evidence |
| --- | --- |
| Core 3.1.3: registration/deployment distinction | Exact issuer/client lookup and deployment allowlist; `launch_test.dart` |
| Core 3.5: secure transport | HTTPS configuration; application/proxy must terminate TLS |
| Core 4.1: optional client and deployment hints | Ambiguous registration rejected, opaque message hint echoed, deployment hint bound to signed launch |
| Core 4.3: forward compatibility | Unknown claims/properties retained immutably and ignored by typed parsing; `core_claims_test.dart` |
| Core 5.3.1–5.3.4: message, version, deployment, target | Exact validation against registration and transaction; `launch_test.dart` |
| Core 5.3.5–5.3.6: resource and subject | Case-sensitive ASCII identifiers, 255-character limit, anonymous launch supported |
| Core 5.3.7 / A.2: roles | Standard system, institution, membership and sub-role URIs recognized; extensions allowed alongside standard roles; empty array accepted |
| Core 5.4.1 / A.1: context | Optional object; required ID; present type array must include a standard type; URI extensions retained |
| Core 5.4.2: platform | Optional typed metadata, required GUID when present, HTTPS homepage |
| Core 5.4.3: mentor scope | Immutable subject list; nonempty list requires the exact principal Mentor role |
| Core 5.4.4: presentation | Typed frame/iframe/window, dimensions, locale and HTTPS return URL; return-message query helper |
| Core 5.4.5: LIS | Typed optional source identifiers; no LIS service implementation implied |
| Core 5.4.6 / B: custom values | Strings preserved verbatim, including empty values and unresolved substitutions; substitution is a platform responsibility |
| Security 5.1: login | OIDC redirect with scope, response type/mode, prompt, state, nonce, client and registered callback |
| Security 5.1.3: token verification | Real RS256 verification, exact issuer and audience, additional audiences explicitly trusted, multi-audience `azp` required |
| Security 5.1.3: time/replay | Expiry, issued-at, optional not-before, configurable clock tolerance and maximum age; atomic browser-bound consumption |
| Security 5.1.3: rejected authentication | Shelf returns 401 for invalid tokens/claims; OIDC errors consume bound transactions without exposing descriptions |
| Security 6.3–6.4: incoming keys | Provisioned JWKS URL, `kid`, bounded cache, overlapping-key rotation supported; `jwks_test.dart` |
| Core 6 / Security 4.1: services | Scoped OAuth, AGS and NRPS clients with verified capabilities and explicit destination policy; local protocol tests |
| Security 5.2 / 6: outgoing signing | RS256 envelopes, typed public JWKS and staged key rotation; `signing_test.dart`, `jwks_route_test.dart` |
| Core 6.2 / Security 4.1.1: client assertions | Client ID as issuer/subject, provisioned audience, bounded timestamps, unique jti and optional deployment; token HTTP client implemented and tested |

## Errata decisions

- Platform metadata is optional; its GUID is required only when the claim exists.
- Custom substitutions remain strings, including empty or unresolved values.
- The signed target is checked against the login target.
- TestUser is recognized as a marker role; applications decide how to handle it.
- OAuth assertions use the client ID for both issuer and subject.

## Explicit policies and limits

Context types accept the four canonical URIs and the eight deprecated short-name/URN
aliases listed in [Core Appendix A.1](https://www.imsglobal.org/spec/lti/v1p3/#context-type-vocabulary).
`launch.context.types` normalizes those exact aliases to canonical URIs, while
`launch.claims` retains the original signed values. This accommodates Moodle
course launches that send `CourseSection` or `Group`. Arbitrary short names and
case variants are still rejected. Launch roles recognize current standard URIs;
deprecated role short names and legacy URNs are not normalized. Unknown extension URIs can accompany recognized
vocabulary values. Separately, NRPS member parsing normalizes eight exact short
context role names; see [NRPS compatibility](bycs-testing.md#nrps-short-context-roles).
No role helper automatically grants application permissions.

Malformed present optional objects (including JSON null) are rejected rather than
silently treated as absent. Presentation dimensions must be nonnegative integral
numbers. The endpoint and target allowlists, required browser binding, 2048-bit
minimum RSA size, five-minute default login/token age and required multi-audience
`azp` are deliberate security policies.

The Shelf adapter requires cookies, with opt-in partitioned cookies. A top-level
window may be needed when embedded storage is unavailable. Production transaction
storage and broader browser/platform coverage remain integration requirements.
Resource launch and Deep Linking selection/cancellation have been tested in ByCS
with a directly configured RSA public key. OAuth, NRPS reads and AGS grade
workflows were also reported successful; see the [live test record](bycs-testing.md).
Static key exchange, Common Cartridge file authoring, platform-side substitution and LMS
functionality are not part of this resource-launch adapter.
