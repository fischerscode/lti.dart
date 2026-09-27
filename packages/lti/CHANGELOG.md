## 0.1.0-dev.1

- Add verified AGS/NRPS capability claims, typed service models and clients with scoped OAuth, explicit destination trust, bounded pagination, grade operations and membership/difference retrieval.

- Add scoped OAuth client-credentials token requests with signed assertions, bounded cache, expiry, coalescing and safe errors.

- Normalize standard legacy context names and URNs for Moodle-compatible launches.

- Identify failing claim checks and field names without exposing claim values.

- Add verified Deep Linking launches, immutable content items and negotiated signed responses.
- Add local/external RS256 signing, OAuth client assertions and staged public-key rotation.
- Add typed optional Core claims, standard role/context vocabularies and mentor validation.
- Require explicit trust for additional JWT audiences and handle bound OIDC errors.

### Initial implementation

- Introduce registrations, atomic login transaction contracts and OIDC initiation.
- Verify resource launches using RS256, configured platform JWKS and bound state.
- Expose immutable typed users, resources, context, roles and custom parameters.
