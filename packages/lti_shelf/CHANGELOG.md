## 0.1.0-dev.1

- Preserve application referrer policies and use strict-origin for the selection form to retain the browser POST Origin.

- Add opt-in partitioned browser-binding cookies and trusted iframe embedding in the ByCS runner.

- Add a bounded, browser-bound Deep Linking selection/cancel UI to the HTTPS integration runner.

- Add an optional server-side protocol error observer; keep browser errors generic.

- Dispatch Deep Linking requests and render escaped, CSP-protected POST return forms.
- Expose GET/HEAD public JWKS when a tool signer is configured.
- Return HTTP 401 for invalid launch authentication and consume bound OIDC errors.

### Initial implementation

- Add Shelf login and resource launch routes with browser-bound transactions.
- Restrict form input and preserve application cookies on verified launch responses.
