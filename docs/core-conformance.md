# Core protocol checklist

Reviewed against [LTI Core 1.3](https://www.imsglobal.org/spec/lti/v1p3/), its
[errata](https://www.imsglobal.org/spec/lti/v1p3/errata/) and the
[Security Framework](https://www.imsglobal.org/spec/security/v1p0/).
This is an engineering checklist for the implemented resource-launch profile,
not a certification or a claim that all LTI Advantage services are implemented.

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
| Core 6 / Security 4.1: services | Pending scoped OAuth client, AGS and NRPS; no service access attempted yet |
| Security 5.2 / 6: outgoing signing | Next implementation block: signing provider, public JWKS and rotation |

## Errata decisions

- Platform metadata is optional; its GUID is required only when the claim exists.
- Custom substitutions remain strings, including empty or unresolved values.
- The signed target is checked against the login target.
- TestUser is recognized as a marker role; applications decide how to handle it.
- Upcoming OAuth assertions must use the client ID for both issuer and subject.

## Explicit policies and limits

Only current URI vocabularies are recognized as standard values. Deprecated role
short names and legacy URNs are optional interoperability features and are not
normalized. Unknown extension URIs can accompany recognized vocabulary values.
No role helper automatically grants application permissions.

Malformed present optional objects (including JSON null) are rejected rather than
silently treated as absent. Presentation dimensions must be nonnegative integral
numbers. The endpoint and target allowlists, required browser binding, 2048-bit
minimum RSA size, five-minute default login/token age and required multi-audience
`azp` are deliberate security policies.

The Shelf adapter currently requires cookies; a top-level window is needed when
third-party cookies are blocked. Production transaction storage, actual browser
tests and a real ByCS registration remain integration requirements. Static key
exchange, Common Cartridge file authoring, platform-side substitution and LMS
functionality are not part of this resource-launch adapter.
