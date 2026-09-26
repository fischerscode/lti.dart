## Unreleased

- Add a bounded, browser-bound Deep Linking selection/cancel UI to the HTTPS integration runner.

- Add an optional server-side protocol error observer; keep browser errors generic.

- Dispatch Deep Linking requests and render escaped, CSP-protected POST return forms.
- Expose GET/HEAD public JWKS when a tool signer is configured.
- Return HTTP 401 for invalid launch authentication and consume bound OIDC errors.

## 0.1.0-dev.1

- Add Shelf login and resource launch routes with browser-bound transactions.
- Restrict form input and preserve application cookies on verified launch responses.
